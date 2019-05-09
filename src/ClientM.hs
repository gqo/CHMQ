module ClientM 
    ( runClient
    , newClientNode
    , dialServer
    , publish
    , get
    , clog
    )
where

import Control.Concurrent.MVar (newMVar, takeMVar, readMVar, putMVar)

import Control.Distributed.Process ( 
      Process
    , WhereIsReply(..)
    , NodeId(..)
    , whereisRemoteAsync
    , send
    , expectTimeout
    , link
    , liftIO
    , getSelfPid
    , say
    , receiveTimeout
    , match
    )
import Control.Distributed.Process.Node (
      initRemoteTable
    , newLocalNode
    , runProcess
    )

import Control.Exception (IOException)

import Control.Monad.Reader (runReaderT, lift, ask, asks)

import Data.ByteString (ByteString)
import Data.ByteString.Char8 (pack)
import qualified Data.Map as Map (empty)

import Network.Transport (EndPointAddress(EndPointAddress))
import Network.Transport.TCP (createTransport, defaultTCPParameters)

import ClientTypesM (
      ServerAddress
    , ServerName
    , ClientAddress
    , ClientPort
    , ClientNode
    , ClientEnv(..)
    , ClientConfig(..)
    , ClientState(..)
    , ClientPublishId
    , ClientDeliveryId
    , UnackedDeliveries
    , ClientDeliveryId
    , ClientDelivery(..)
    , Client
    )

import Messages (
      ClientConnection(..)
    , ConfirmConnection(..)
    , Publish(..)
    , Get(..)
    , Confirm(..)
    , Delivery(..)
    , UnrecognizedClientNotification
    , EmptyQueueNotification
    )

type Second = Int
type Microsecond = Int

toMicro :: Second -> Microsecond
toMicro = (*) 1000000

-- newClientNode provides the ability for a user to create a new node for the 
-- client to run on via a TCP transport layer that CHMQ relies on
newClientNode :: ClientAddress -> ClientPort -> IO (Either IOException ClientNode)
newClientNode cAddr cPort  = do
    eitherT <- createTransport cAddr cPort defaultTCPParameters
    case eitherT of
        Right t -> do
            clientNode <- newLocalNode t initRemoteTable
            return $ Right clientNode
        Left e ->
            return $ Left e

-- getConfig polls the remote table that the server has registered itself on
-- and, if it gets a correct reply, returns the server's PID and the client's 
-- PID wrapped in the ClientConfig structure
getConfig :: ServerAddress -> ServerName -> Process (Maybe ClientConfig)
getConfig sAddr sName = do
    let sAddr' = sAddr ++ ":0"
        -- construct NodeId from given address
        sNodeId = NodeId $ EndPointAddress $ pack sAddr'
    -- poll remote table
    whereisRemoteAsync sNodeId sName
    -- expect a reply in 5 seconds
    sPidReply <- expectTimeout (toMicro 5) :: Process (Maybe WhereIsReply)
    case sPidReply of
        -- if a reply is received, check if the server is registered
        Just (WhereIsReply _ maybeSPid) -> do
            case maybeSPid of
                -- if the server is registered, return a config with the sPid and clientPid
                Just sPid -> do
                    self <- getSelfPid
                    let config = ClientConfig sPid self
                    return (Just config)
        -- otherwise, return nothing
                Nothing -> return Nothing
        Nothing -> return Nothing

-- dialServer attempts to establish a connection to the CHMQ server by sending
-- a ClientConnection message and waiting for a reply which, if received, the 
-- dialServer function then initializes the starting state for a client and 
-- returns said state
dialServer :: ServerAddress -> ServerName -> Process (Maybe ClientEnv)
dialServer sAddr sName = do
    -- attempt to get configuration data
    maybeConfig <- getConfig sAddr sName
    case maybeConfig of
        -- if configuration data is received,
        Just (ClientConfig sPid self) -> do
            -- send a connection message to the CHMQ server
            send sPid $ ClientConnection self
            -- expect a reply from the CHMQ server in 1 second
            serverConnectionReply <- expectTimeout (toMicro 1) :: Process (Maybe ConfirmConnection)
            case serverConnectionReply of
                -- if a reply is received,
                Just reply -> do
                    -- link the running client process to the server itself
                    -- s.t. the client will die if the server dies
                    link sPid
                    -- initialize new state and return it in an environment 
                    -- wrapper with the config data
                    initialState <- liftIO $ newMVar $ ClientState 0 0 Map.empty
                    let initialEnv = ClientEnv (ClientConfig sPid self) initialState
                    return (Just initialEnv)
        -- otherwise, return nothing
                Nothing -> return Nothing
        Nothing -> return Nothing

-- runClientInternal is a wrapper around runReaderT with flipped argument order
runClientInternal :: ClientEnv -> Client () -> Process ()
runClientInternal env proc = runReaderT proc env

-- runClient wraps both runProcess and runClientInternal such that it attempts 
-- to first dial the server in the runProcess function and then, if successful, 
-- allows a user to pass a Client () to runClientInternal via do syntax s.t. 
-- they can call the API functions
runClient :: ClientNode -> ServerAddress -> ServerName -> Client() -> IO ()
runClient node sAddr sName proc = runProcess node $ do
    maybeEnv <- dialServer sAddr sName
    case maybeEnv of
        Just env -> do
            runClientInternal env proc
        Nothing -> do
            say $ "Could not make connection to CHMQ server " ++ sName ++ "@(" ++ sAddr ++ ")"
            return ()

-- clog allows users to clog a string to stderr via a lifted say
clog :: String -> Client ()
clog msg = lift $ say msg

-- showStateVal allows one to print state values via a selector function
showStateVal :: Show a => (ClientState -> a) -> Client String
showStateVal f = do
    val <- getStateVal f
    return $ show val

-- getStateVal is a helper function to read the value of a part of the ClientState
getStateVal :: (ClientState -> a) -> Client a
getStateVal f = do
    mState <- asks cState
    state <- liftIO $ readMVar mState
    return (f state)

takeState :: Client ClientState
takeState = do
    mState <- asks cState
    state <- liftIO $ takeMVar mState
    return state

putState :: ClientState -> Client ()
putState state' = do
    mState <- asks cState
    liftIO $ putMVar mState state'

-- increments the pub id and returns the old pub id
incNextPubId :: Client ClientPublishId
incNextPubId = do
    (ClientState pub deliv unDelivs) <- takeState
    let pub' = pub + 1
    putState $ ClientState pub' deliv unDelivs
    return pub

incNextDelivId :: Client ()
incNextDelivId = do
    (ClientState pub deliv unDelivs) <- takeState
    let deliv' = deliv + 1
    putState $ ClientState pub deliv' unDelivs
    
modifyUnackedDelivs :: (UnackedDeliveries -> UnackedDeliveries) -> Client ()
modifyUnackedDelivs f = do
    (ClientState pub deliv unDelivs) <- takeState
    let unDelivs' = f unDelivs
    putState $ ClientState pub deliv unDelivs'

data Err = Err
    deriving (Show)

publish :: ByteString -> Client (Maybe Err)
publish body = do
    (ClientConfig sPid self) <- asks conf
    pubId <- incNextPubId
    lift $ send sPid $ Publish self pubId body
    response <- lift $ receiveTimeout (toMicro 1) [
          match $ confirmHandler pubId
        , match $ unrecognizedConnHandler
        ]
    case response of
        Just maybeErr -> do
            case maybeErr of
                Just err -> return (Just err)
                Nothing -> return Nothing
        Nothing ->
            return Nothing
    where
        confirmHandler :: ClientPublishId -> Confirm -> Process (Maybe Err)
        confirmHandler pubId (Confirm sPubId) =
            case pubId == sPubId of
                True -> return Nothing
                False -> return (Just Err)
        unrecognizedConnHandler :: UnrecognizedClientNotification -> Process (Maybe Err)
        unrecognizedConnHandler _ = return (Just Err)

data GetResponse = GotDelivery {
    body :: ClientDelivery
} | EmptyQueue | UnrecognizedConn

get :: Client (Either Err ClientDelivery)
get = do
    (ClientConfig sPid self) <- asks conf
    lift $ send sPid $ Get self
    maybeResponse <- lift $ receiveTimeout (toMicro 1) [
          match $ deliveryHandler
        , match $ unrecognizedConnHandler
        , match $ emptyQueueHandler
        ]
    case maybeResponse of
        Just response ->
            case response of
                GotDelivery body -> return $ Right body
                EmptyQueue -> return $ Left Err
                UnrecognizedConn -> return $ Left Err
        Nothing -> return $ Left Err
    where
        deliveryHandler :: Delivery -> Process GetResponse
        deliveryHandler (Delivery delivId body) = return $ GotDelivery $ ClientDelivery delivId body
        unrecognizedConnHandler :: UnrecognizedClientNotification -> Process GetResponse
        unrecognizedConnHandler _ = return $ UnrecognizedConn
        emptyQueueHandler :: EmptyQueueNotification -> Process GetResponse
        emptyQueueHandler _ = return $ EmptyQueue
        
    