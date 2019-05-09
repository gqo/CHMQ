module ServerTypes where

import Control.Distributed.Process (ProcessId, MonitorRef)
import Data.ByteString (ByteString)
import Data.Map (Map)

import Messages (DeliveryId)
import Queue (Queue)

type ServerName = String

type ClientId = ProcessId
type Clients = Map ClientId MonitorRef

type Item = ByteString

type UnackedItems = Map DeliveryId Item
type ClientItems = Map ClientId UnackedItems

data ServerState = ServerState {
    serverName :: ServerName,
    clients :: Clients,
    clientItems :: ClientItems,
    queue :: Queue Item,
    nextDeliveryId :: DeliveryId
}