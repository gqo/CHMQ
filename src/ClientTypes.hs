module ClientTypes
    ( -- Configuration value types
      ServerAddress
    , ServerName
    , ClientAddress
    , ClientPort
    -- Types for initializing connection
    , ClientNode
    , ClientEnv(..)
    , ClientConfig(..)
    , ClientState(..)
    -- State data types
    , ClientPublishId
    , ClientDeliveryId
    , UnackedDeliveries
    -- Delivery data types
    , ClientDeliveryId
    , ClientDelivery(..)
    -- Client monad type
    , Client
    )
where

import Control.Distributed.Process (ProcessId, Process)
import Control.Distributed.Process.Node (LocalNode)

import Data.Map (Map)
import Data.ByteString (ByteString)

import Control.Monad.Reader (ReaderT)

import Control.Concurrent.MVar (MVar)

import Messages (PublishId, DeliveryId)

type ServerAddress = String
type ServerName = String
type ClientAddress = String
type ClientPort = String

type ClientId = ProcessId
type ServerId = ProcessId
type ClientPublishId = PublishId
type ClientDeliveryId = DeliveryId
type UnackedDeliveries = Map ClientDeliveryId DeliveryId

type ClientNode = LocalNode

data ClientDelivery = ClientDelivery {
    id :: ClientDeliveryId,
    body :: ByteString
} deriving (Show)

data ClientConfig = ClientConfig {
    serverId :: !ServerId,
    selfId :: !ClientId
} deriving (Show)

data ClientState = ClientState {
    _nextPublishId :: !ClientPublishId,
    _nextDeliveryId :: !ClientDeliveryId,
    _unackedDeliveries :: !(UnackedDeliveries)
} deriving (Show)

data ClientEnv = ClientEnv {
    conf :: !ClientConfig,
    cState :: !(MVar ClientState)
}

-- data ClientEnv = 
--       ClientEnvValid {-# UNPACK #-} !ValidClientEnv
--     | ClientEnvClosed

type Client = ReaderT ClientEnv Process