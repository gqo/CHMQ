module ClientM 
    ( runClient
    , newClientNode
    , dialServer
    , publish
    )
where

import Control.Concurrent.MVar (newMVar, takeMVar, readMVar, putMVar)

import Control.Distributed.Process ( Process
                                   , WhereIsReply(..)
                                   , NodeId(..)
                                   , whereisRemoteAsync
                                   , send
                                   , expectTimeout
                                   , link
                                   , liftIO
                                   , getSelfPid
                                   , say
                                   )
import Control.Distributed.Process.Node ( initRemoteTable
                                        , newLocalNode
                                        , runProcess
                                        )

import Control.Exception (IOException)

import Control.Monad.Reader (runReaderT, lift, ask)

import Data.ByteString.Char8 (pack)
import qualified Data.Map as Map (empty)

import Network.Transport (EndPointAddress(EndPointAddress))
import Network.Transport.TCP (createTransport, defaultTCPParameters)

import ClientTypesM ( ServerAddress
                    , ServerName
                    , ClientAddress
                    , ClientPort
                    , ClientNode
                    , ClientEnv(..)
                    , ClientConfig(..)
                    , ClientState(..)
                    , ClientDeliveryId
                    , ClientDelivery
                    , Client
                    )

import Messages ( ClientConnection(..)
                , ConfirmConnection(..)
                )

type Second = Int
type Microsecond = Int

toMicro :: Second -> Microsecond
toMicro = (*) 1000000

newClientNode :: ClientAddress -> ClientPort -> IO (Either IOException ClientNode)
newClientNode cAddr cPort  = do
    eitherT <- createTransport cAddr cPort defaultTCPParameters
    case eitherT of
        Right t -> do
            clientNode <- newLocalNode t initRemoteTable
            return $ Right clientNode
        Left e ->
            return $ Left e

getConfig :: ServerAddress -> ServerName -> Process (Maybe ClientConfig)
getConfig sAddr sName = do
    let sAddr' = sAddr ++ ":0"
        sNodeId = NodeId $ EndPointAddress $ pack sAddr'
    whereisRemoteAsync sNodeId sName
    sPidReply <- expectTimeout (toMicro 5) :: Process (Maybe WhereIsReply)
    case sPidReply of
        Just (WhereIsReply _ maybeSPid) -> do
            case maybeSPid of
                Just sPid -> do
                    self <- getSelfPid
                    let config = ClientConfig sPid self
                    return (Just config)
                Nothing -> return Nothing
        Nothing -> return Nothing

dialServer :: ServerAddress -> ServerName -> Process (Maybe ClientEnv)
dialServer sAddr sName = do
    maybeConfig <- getConfig sAddr sName
    case maybeConfig of
        Just (ClientConfig sPid self) -> do
            send sPid $ ClientConnection self
            serverConnectionReply <- expectTimeout (toMicro 1) :: Process (Maybe ConfirmConnection)
            case serverConnectionReply of
                Just reply -> do
                    link sPid
                    initialState <- liftIO $ newMVar $ ClientState 0 0 Map.empty
                    let initialEnv = ClientEnv (ClientConfig sPid self) initialState
                    return (Just initialEnv)
                Nothing -> return Nothing
        Nothing -> return Nothing

runClientInternal :: ClientEnv -> Client () -> Process ()
runClientInternal env proc = runReaderT proc env

runClient :: ClientNode -> ServerAddress -> ServerName -> Client() -> IO ()
runClient node sAddr sName proc = runProcess node $ do
    maybeEnv <- dialServer sAddr sName
    case maybeEnv of
        Just env -> do
            runClientInternal env proc
        Nothing -> do
            say $ "Could not make connection to CHMQ server " ++ sName ++ "@(" ++ sAddr ++ ")"
            return ()

cSay :: String -> Client ()
cSay msg = do
    lift $ say msg

incPubCount :: Client ()
incPubCount = do
    env <- ask
    let mState = cState env
    pc <- showPubCount
    state <- liftIO $ takeMVar mState
    let pubCount' = (_nextPublishId state) + 1
        delivCount = (_nextDeliveryId state)
        unackedDeliveries = (_unackedDeliveries state)
    liftIO $ putMVar mState (ClientState pubCount' delivCount unackedDeliveries)

showPubCount :: Client String
showPubCount = do
    env <- ask
    let mState = cState env
    state <- liftIO $ readMVar mState
    return (show $ _nextPublishId state)

publish :: Client ()
publish = do
    env <- ask
    pc <- showPubCount
    lift $ say $ "Before inc: " ++ pc
    incPubCount
    pc <- showPubCount
    lift $ say $ "After inc: " ++ pc
    return ()