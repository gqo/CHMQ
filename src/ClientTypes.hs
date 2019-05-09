{-# LANGUAGE GeneralizedNewtypeDeriving  #-}
-- {-# LANGUAGE DeriveAnyClass #-}
-- {-# LANGUAGE DeriveFunctor #-}
module ClientTypes where

import Control.Distributed.Process (ProcessId, Process)
import Control.Distributed.Process.Node (LocalNode)
import Data.Map (Map)
import qualified Data.Map as Map (empty)
import Data.ByteString (ByteString)

import Messages (PublishId, DeliveryId)

type ServerAddress = String
type ServerName = String

type ClientId = ProcessId
type ServerId = ProcessId
type ClientPublishId = PublishId
type ClientDeliveryId = DeliveryId

data ClientDelivery = ClientDelivery {
    clientDeliveryId :: ClientDeliveryId,
    clientDeliveryBody :: ByteString
}

data ClientState = ClientState {
    serverId :: !ServerId,
    nextPublishId :: !ClientPublishId,
    nextDeliveryId :: !ClientDeliveryId,
    unackedDeliveries :: !(Map ClientDeliveryId DeliveryId)
    -- clientNode :: !LocalNode
}