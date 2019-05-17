module ServerTypes where

import Control.Distributed.Process (ProcessId, MonitorRef)
import Control.Lens.Internal.ByteString (unpackStrict8)
import Data.ByteString (ByteString)
import Data.Map (Map)

import Messages (DeliveryId, QueueName)
import Queue (Queue)

type ServerName = String

type ClientId = ProcessId
type Clients = Map ClientId MonitorRef

-- type Item = ByteString

data Item = Item {
    source :: QueueName,
    body :: ByteString
} deriving (Eq)

instance Show Item where
    show (Item src body) =
         "Item: { Src: " ++ src ++
         "; Body: " ++ unpackStrict8 body ++
         " }"

type UnackedItems = Map DeliveryId Item
type ClientItems = Map ClientId UnackedItems

data ServerQueue = ServerQueue {
    queue :: Queue Item,
    exclusiveConsumer :: Bool,
    consumers :: Queue ClientId
    -- can use find to check for consumers (ClientId -> Bool) -> Queue ClientId -> Maybe ClientId
}

type ServerQueues = Map QueueName ServerQueue

data ServerState = ServerState {
    serverName :: ServerName,
    clients :: Clients,
    clientItems :: ClientItems,
    queues :: ServerQueues,
    nextDeliveryId :: DeliveryId
}