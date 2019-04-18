{-# LANGUAGE DeriveGeneric #-}

module Messages where

import GHC.Generics (Generic)
import Data.Binary (Binary)
import Data.Typeable (Typeable)

import Control.Distributed.Process (ProcessId)
import Data.ByteString (ByteString)

type PublishId = Int
type DeliveryId = Int

-- Connection message for when a client wants to connect to the server
data ClientConnection = ClientConnection {
    clientId :: ProcessId
} deriving (Typeable, Generic, Show)

instance Binary ClientConnection

-- Confirm connection message such that a client knows they've succesffuly connected
data ConfirmConnection = ConfirmConnection
    deriving (Typeable, Generic, Show)

instance Binary ConfirmConnection

-- Message for the receipt of a message from an unrecognized client
data UnrecognizedClientNotification = UnrecognizedClientNotification
    deriving (Typeable, Generic, Show)

instance Binary UnrecognizedClientNotification

-- Reasons for the closure of a connection
data ConnCloseReason = FalseAck | FalseNack
    deriving (Typeable, Generic, Show)

instance Binary ConnCloseReason

-- Message for when the server closes a connection due to believed failure
data ConnectionClosedNotification = ConnectionClosedNotification {
    reason :: ConnCloseReason
} deriving (Typeable, Generic, Show)

instance Binary ConnectionClosedNotification

-- Publish message for when client wants to publish one message to the queue
data Publish = Publish {
    publisherId :: ProcessId,
    publishId :: PublishId,
    publishBody :: ByteString
} deriving (Typeable, Generic, Show)

instance Binary Publish

-- Confirm message for a server confirming the receipt of a published item
data Confirm = Confirm {
    confirmId :: PublishId
} deriving (Typeable, Generic, Show)

instance Binary Confirm

-- Get message for when client wants one message from the queue
data Get = Get {
    getterId :: ProcessId
} deriving (Typeable, Generic, Show)

instance Binary Get

-- Notification for when a client "gets" from an empty queue
data EmptyQueueNotification = EmptyQueueNotification
    deriving (Typeable, Generic, Show)

instance Binary EmptyQueueNotification

-- Delivery message for the server sending a item in the queue to a client
data Delivery = Delivery {
    deliveryId :: DeliveryId,
    deliveryBody :: ByteString
} deriving (Typeable, Generic, Show)

instance Binary Delivery

-- Ack message for a client acknowledging a delivery
data Ack = Ack {
    ackerId :: ProcessId,
    ackId :: DeliveryId
} deriving (Typeable, Generic, Show)

instance Binary Ack

-- Nack message for client negatively acknowledging a delivery
data Nack = Nack {
    nackerId :: ProcessId,
    nackId :: DeliveryId
} deriving (Typeable, Generic, Show)

instance Binary Nack