module ServerTypes where

import Control.Distributed.Process
import Data.ByteString (ByteString)
import qualified Data.Map as Map

import Messages
import Queue

type ServerName = String

type ClientId = ProcessId
type Clients = Map.Map ClientId MonitorRef

type Item = ByteString

type UnackedItems = Map.Map DeliveryId Item
type ClientItems = Map.Map ClientId UnackedItems

data ServerState = ServerState {
    serverName :: ServerName,
    clients :: Clients,
    clientItems :: ClientItems,
    queue :: Queue Item,
    nextDeliveryId :: DeliveryId
}