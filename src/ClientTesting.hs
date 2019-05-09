{-# LANGUAGE GeneralizedNewtypeDeriving #-} -- Allows deriving Monad
{-# LANGUAGE TemplateHaskell #-} -- Allows deriving Lenses for State (makeLenses)
module ClientTesting 
()
where

import Control.Distributed.Process

import Control.Distributed.Process.Node (LocalNode)
import Control.Distributed.Process.Node (initRemoteTable, newLocalNode, runProcess)

import Network.Transport.TCP (createTransport, defaultTCPParameters)

import Data.Map (Map)
import qualified Data.Map as Map (empty)

import Data.ByteString (ByteString)

import Control.Exception (IOException)

import Messages

import Control.Lens (makeLenses)
import Control.Monad.RWS.Strict ( RWS
                                , MonadReader
                                , MonadWriter
                                , MonadState
                                )

import Network.Transport (EndPointAddress(EndPointAddress))
import Data.ByteString.Char8 (pack)

import Control.Concurrent.MVar

-- Monadic experimentation stuff
import Control.Applicative
import Control.Monad.Fix (MonadFix)
import Control.Monad.Reader (MonadReader(..), ReaderT, lift, runReaderT, void)
import Control.Monad.IO.Class (MonadIO(..))
import Data.Typeable (Typeable)
---

type ServerAddress = String
type ServerName = String
type ClientAddress = String
type ClientPort = String

type ClientNode = LocalNode

type ClientId = ProcessId
type ServerId = ProcessId
type ClientPublishId = PublishId
type ClientDeliveryId = DeliveryId

type Log = String

type Second = Int
type Microsecond = Int

data CHMQConfig = CHMQConfig {
    serverId :: ServerId,
    selfId :: ClientId
} deriving (Show)

data ClientState = ClientState {
    _nextPublishId :: !ClientPublishId,
    _nextDeliveryId :: !ClientDeliveryId,
    _unackedDeliveries :: !(Map ClientDeliveryId DeliveryId)
} deriving (Show)
makeLenses ''ClientState

newtype ClientProcess a = ClientProcess {
    runClientProcess :: RWS CHMQConfig [Log] ClientState a
} deriving ( Functor
           , Applicative
           , Monad
           , MonadState ClientState
           , MonadWriter [Log]
           , MonadReader CHMQConfig)

newClientNode :: ClientAddress -> ClientPort -> IO (Either IOException ClientNode)
newClientNode cAddr cPort  = do
    eitherT <- createTransport cAddr cPort defaultTCPParameters
    case eitherT of
        Right t -> do
            clientNode <- newLocalNode t initRemoteTable
            return $ Right clientNode
        Left e ->
            return $ Left e

runClient :: ClientNode -> ServerAddress -> ServerName -> Process () -> IO ()
runClient node servAddr servName proc =
    runProcess node proc

clientSay :: String -> Process ()
clientSay = say

toMicro :: Second -> Microsecond
toMicro = (*) 1000000

getConfig :: ServerAddress -> ServerName -> Process (Maybe CHMQConfig)
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
                    let config = CHMQConfig sPid self
                    return (Just config)
                Nothing -> return Nothing
        Nothing -> return Nothing

class (Monad m) => MonadProcess m where
    liftProc :: Process a -> m a

instance MonadProcess Process where
    liftProc = id

-- instance MonadProcess ReaderT

data CState = CState {
    pubCount :: !Int
} deriving (Show)

data Env = Env {
    conf :: !CHMQConfig,
    cState :: !(MVar CState)
}

instance Show Env where
    show (Env conf _)
        = "Conf: " ++ show conf ++
          "\nState: " ++ "this is where the state would go"


dialServer :: CHMQConfig -> Process (Maybe Env)
dialServer (CHMQConfig sPid self) = do
    send sPid $ ClientConnection self
    serverConnectionReply <- expectTimeout (toMicro 1) :: Process (Maybe ConfirmConnection)
    case serverConnectionReply of
        Just reply -> do
            link sPid
            let initialState = CState 0
            initStateM <- liftIO $ newMVar initialState
            let initEnv = Env (CHMQConfig sPid self) initStateM
            return (Just initEnv)
        Nothing -> return Nothing

type ClientReader = ReaderT Env Process

runClientReader :: Env -> ClientReader () -> Process ()
runClientReader env proc = runReaderT proc env 

cSay :: String -> ClientReader ()
cSay msg = do
    lift $ say msg

incPubCount :: ClientReader ()
incPubCount = do
    env <- ask
    let mState = cState env
    pc <- showPubCount
    state <- liftIO $ takeMVar mState
    let pubCount' = (pubCount state) + 1
    liftIO $ putMVar mState (CState pubCount')

showPubCount :: ClientReader String
showPubCount = do
    env <- ask
    let mState = cState env
    state <- liftIO $ readMVar mState
    return (show $ pubCount state)

publish :: ClientReader ()
publish = do
    env <- ask
    pc <- showPubCount
    lift $ say $ "Before inc: " ++ pc
    incPubCount
    pc <- showPubCount
    lift $ say $ "After inc: " ++ pc
    return ()