module Client
    ( 
    -- Client process runnable
      runClient
    -- Connection functionality
    , newClientNode
    , dialServer
    -- API functionality
    , publish
    , get
    , ack
    , nack
    -- Debug
    , clog
    -- Error types
    , ClientError
    , PublishError
    , GetError
    , AckError
    , NackError
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
import qualified Data.Map as Map (empty, insert, lookup, delete)

import Network.Transport (EndPointAddress(EndPointAddress))
import Network.Transport.TCP (createTransport, defaultTCPParameters)

import ClientTypes (
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
    , Ack(..)
    , Nack(..)
    , UnrecognizedClientNotification
    -- , EmptyQueueNotification
    , GetErrorNotification(..)
    , ConnectionClosedNotification
    , DeliveryId
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

-- getStateVal is a helper function to read the value of a part of the ClientState
getStateVal :: (ClientState -> a) -> Client a
getStateVal f = do
    mState <- asks cState
    state <- liftIO $ readMVar mState
    return (f state)

-- showStateVal allows one to print state values via a selector function
showStateVal :: Show a => (ClientState -> a) -> Client String
showStateVal f = do
    val <- getStateVal f
    return $ show val

-- debug function to print current state value
printStateVal :: Show a => (ClientState -> a) -> Client ()
printStateVal f = do
    val <- showStateVal f
    clog val

-- debug function to print all current state
printState :: Client ()
printState = do
    mState <- asks cState
    state <- liftIO $ readMVar mState
    clog $ show state

-- grabs all modifiable state
takeState :: Client ClientState
takeState = do
    mState <- asks cState
    state <- liftIO $ takeMVar mState
    return state

-- updates all modifiable state
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

-- increments the deliv id and reutrns the old deliv id
incNextDelivId :: Client ClientDeliveryId
incNextDelivId = do
    (ClientState pub deliv unDelivs) <- takeState
    let deliv' = deliv + 1
    putState $ ClientState pub deliv' unDelivs
    return deliv
    
-- takes a function to update the _unackedDeliveries field, calls it, and updates the state
modifyUnackedDelivs :: (UnackedDeliveries -> UnackedDeliveries) -> Client ()
modifyUnackedDelivs f = do
    (ClientState pub deliv unDelivs) <- takeState
    let unDelivs' = f unDelivs
    putState $ ClientState pub deliv unDelivs'

-- inserts a new delivery into an UnackedDeliveries type
insertDelivery :: ClientDelivery -> ClientDeliveryId -> UnackedDeliveries -> UnackedDeliveries
insertDelivery (ClientDelivery delivId body) nextDelivId = Map.insert nextDelivId delivId

lookupDelivery :: ClientDeliveryId -> Client (Maybe DeliveryId)
lookupDelivery clientDelivId = do
    unDelivs <- getStateVal _unackedDeliveries
    case Map.lookup clientDelivId unDelivs of
        Nothing -> return Nothing
        Just delivId -> return (Just delivId)

deleteDelivery :: ClientDeliveryId -> UnackedDeliveries -> UnackedDeliveries
deleteDelivery clientDelivId = Map.delete clientDelivId


data PublishError = PubTimeout | PubFalseConfirm
    deriving (Show)
data GetError = GetTimeout | GetEmptyQueue
    deriving (Show)
data AckError = AckFalseClientside
    deriving (Show)
data NackError = NackFalseClientside
    deriving (Show)


data ClientError = PublishErr {
    publishErr :: PublishError
} | GetErr {
    getErr :: GetError
}| AckErr {
    ackErr :: AckError
}| NackErr {
    nackErr :: NackError
}| UnrecognizedConn | ConnClosed
    deriving (Show)

data Err = Err
    deriving (Show)

-- publish attempts to send a new ByteString message to the CHMQ server
publish :: ByteString -> Client (Maybe ClientError)
publish body = do
    -- get config data
    (ClientConfig sPid self) <- asks conf
    -- increment pub id
    pubId <- incNextPubId
    -- send a publish message to CHMQ server with body data
    lift $ send sPid $ Publish self pubId body "default"
    -- expect a reply from the CHMQ server in 1 second
    response <- lift $ receiveTimeout (toMicro 1) [
          match $ confirmHandler pubId
        , match $ unrecognizedConnHandler
        ]
    case response of
        -- if a reply is received,
        Just maybeErr -> do
            case maybeErr of
                -- check if it's an error and return it
                Just err -> return (Just err)
                -- otherwise, return nothing
                Nothing -> return Nothing
        -- if a reply is NOT received,
        Nothing -> do
            -- return a timeout error
            let err = PublishErr PubTimeout
            return (Just err)
    where
        -- confirmHandler checks if the message is confirmed as recieved by the CHMQ server
        confirmHandler :: ClientPublishId -> Confirm -> Process (Maybe ClientError)
        confirmHandler pubId (Confirm sPubId) =
            case pubId == sPubId of
                True -> return Nothing
                False -> do
                    let err = PublishErr PubFalseConfirm
                    return (Just err)
        unrecognizedConnHandler :: UnrecognizedClientNotification -> Process (Maybe ClientError)
        unrecognizedConnHandler _ = return (Just UnrecognizedConn)

data GetResponse = GotDelivery {
    delivery :: ClientDelivery
} | GetResponseErr {
    getResponseErr :: ClientError
}

-- get attempts to pull a delivery from the CHMQ server queue
get :: Client (Either ClientError ClientDelivery)
get = do
    -- get config data
    (ClientConfig sPid self) <- asks conf
    -- send a get message
    lift $ send sPid $ Get self "default"
    -- expect a reply from the CHMQ server in 1 second
    maybeResponse <- lift $ receiveTimeout (toMicro 1) [
          match $ deliveryHandler
        , match $ unrecognizedConnHandler
        , match $ emptyQueueHandler
        ]
    case maybeResponse of
        -- if a reply is received,
        Just response ->
            case response of
                -- check if it's a delivery, adding it to the client's unacked 
                -- items and returning it if so
                GotDelivery delivery -> do
                    printState

                    nextDelivId <- incNextDelivId
                    modifyUnackedDelivs $ insertDelivery delivery nextDelivId

                    printState

                    return $ Right delivery
                -- if an error was received, return it
                GetResponseErr err -> return $ Left err
        -- if a reply is NOT received,
        Nothing -> do
            -- return a timeout error
            let err = GetErr GetTimeout
            return $ Left err
    where
        -- deliveryHandler repacks a received delivery into GetResponse
        deliveryHandler :: Delivery -> Process GetResponse
        deliveryHandler (Delivery delivId body) = return $ GotDelivery $ ClientDelivery delivId body
        unrecognizedConnHandler :: UnrecognizedClientNotification -> Process GetResponse
        unrecognizedConnHandler _ = return $ GetResponseErr UnrecognizedConn
        emptyQueueHandler :: GetErrorNotification -> Process GetResponse
        emptyQueueHandler _ = return $ GetResponseErr $ GetErr GetEmptyQueue
    
-- ack attempts to acknowledge a received delivery by it's id
ack :: ClientDeliveryId -> Client (Maybe ClientError)
ack clientDelivId = do
    -- check if the delivery is in the clientside unackedDeliveries first
    maybeDelivId <- lookupDelivery clientDelivId
    case maybeDelivId of
        -- if it isn't, return a clientside false ack error
        Nothing -> do
            let err = AckErr AckFalseClientside
            return (Just err)
        -- if it is,
        Just delivId -> do
            -- get config data
            (ClientConfig sPid self) <- asks conf
            -- send an ack message
            lift $ send sPid $ Ack self delivId
            -- expect a reply from the CHMQ server in 1 second
            maybeResponse <- lift $ receiveTimeout (toMicro 1) [
                  match $ connClosedHandler
                , match $ unrecognizedConnHandler
                ]
            case maybeResponse of
                -- if no reply is received (which means no error),
                Nothing -> do
                    printState

                    -- remove the item from unackedDeliveries
                    modifyUnackedDelivs $ deleteDelivery clientDelivId

                    printState

                    return Nothing
                -- if a reply is received, return the error
                Just err -> return (Just err)
    where
        connClosedHandler :: ConnectionClosedNotification -> Process ClientError
        connClosedHandler _ = return ConnClosed
        unrecognizedConnHandler :: UnrecognizedClientNotification -> Process ClientError
        unrecognizedConnHandler _ = return UnrecognizedConn
    
-- nack attempts to negatively acknowledge a received delivery by it's id
nack :: ClientDeliveryId -> Client (Maybe ClientError)
nack clientDelivId = do
    -- check if the delivery is in the clientside unackedDeliveries first
    maybeDelivId <- lookupDelivery clientDelivId
    case maybeDelivId of
        -- if it isn't, return a clientside false nack error
        Nothing -> do
            let err = NackErr NackFalseClientside
            return (Just err)
        -- if it is,
        Just delivId -> do
            -- get config data
            (ClientConfig sPid self) <- asks conf
            -- send a nack message
            lift $ send sPid $ Nack self delivId
            -- expect a reply from the CHMQ server in 1 second
            maybeResponse <- lift $ receiveTimeout (toMicro 1) [
                  match $ connClosedHandler
                , match $ unrecognizedConnHandler
                ]
            case maybeResponse of
                -- if no reply is received (which means no error),
                Nothing -> do
                    printState

                    -- remove the item from unackedDeliveries
                    modifyUnackedDelivs $ deleteDelivery clientDelivId

                    printState

                    return Nothing
                -- if a reply is received, return the error
                Just err -> return (Just err)
    where
        connClosedHandler :: ConnectionClosedNotification -> Process ClientError
        connClosedHandler _ = return ConnClosed
        unrecognizedConnHandler :: UnrecognizedClientNotification -> Process ClientError
        unrecognizedConnHandler _ = return UnrecognizedConn