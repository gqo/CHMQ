module ServerHandlers where

import Control.Distributed.Process
import qualified Data.Map as Map

import Messages
import ServerTypes
import Queue

-- Handler function for connecting a new client to the server
clientConnHandler :: ServerState -> ClientConnection -> Process ServerState
clientConnHandler 
    (ServerState name clients clientItems queue nextDelivId)
    (ClientConnection newClientId) = do
        case Map.member newClientId clients of
            -- If client is connected already
            True -> do
                -- Reconfirm with client that they're connected
                send newClientId ConfirmConnection
                -- Return state
                return $ ServerState name clients clientItems queue nextDelivId
            -- If client is a new connection
            False -> do
                -- Start monitoring new client
                clientMonitorRef <- monitor newClientId
                -- Add client to clients map and initialize there unacked items map
                let clients' = Map.insert newClientId clientMonitorRef clients
                    clientItems' = Map.insert newClientId Map.empty clientItems
                -- Confirm with client that they're connected
                send newClientId ConfirmConnection
                -- Return modified state
                return $ ServerState name clients' clientItems' queue nextDelivId

-- Handler function for when a client publishes an item to the queue
publishHandler :: ServerState -> Publish -> Process ServerState
publishHandler 
    (ServerState name clients clientItems queue nextDelivId)
    (Publish publisherId itemId itemBody) = do
        case Map.notMember publisherId clients of
            -- If message received from unconnected client
            True -> do
                -- Tell unconnected client that they're unrecognized by server
                send publisherId UnrecognizedClientNotification
                -- Drop message and return state
                return $ ServerState name clients clientItems queue nextDelivId
            -- If message is received from connected client
            False -> do
                -- Add item to queue
                let queue' = push itemBody queue
                -- Confirm receipt to publisher
                send publisherId $ Confirm itemId
                -- Return modified state
                return $ ServerState name clients clientItems queue' nextDelivId

-- Handler function for when a client requests an item from the queue
getHandler :: ServerState -> Get -> Process ServerState
getHandler
    (ServerState name clients clientItems queue nextDelivId)
    (Get getterId) = do
        case Map.notMember getterId clients of
            -- If message received from unconnected client
            True -> do
                -- Tell unconnected client that they're unrecognized by server
                send getterId UnrecognizedClientNotification
                -- Drop message and return state
                return $ ServerState name clients clientItems queue nextDelivId
            -- If message is received from connected client
            False -> do
                -- Pop an item from the queue
                let (queue', maybeItem) = pop queue
                case maybeItem of
                    -- If queue is emtpy
                    Nothing -> do
                        -- Send empty queue notif to client
                        send getterId EmptyQueueNotification
                        -- Return modified state
                        return $ ServerState name clients clientItems queue' nextDelivId
                    -- If queue is not empty
                    Just item -> do
                        -- Increment deliveryId counter
                        let nextDelivId' = nextDelivId + 1
                        -- Get getter's unackedItems map                      
                        case Map.lookup getterId clientItems of
                            -- If getter's unackedItems map doesn't exist, create it and insert it
                            Nothing -> do
                                let unackedItems' = Map.fromList [(nextDelivId, item)]
                                    clientItems' = Map.insert getterId unackedItems' clientItems
                                -- Send item to getter
                                send getterId $ Delivery nextDelivId item
                                -- Return modified state
                                return $ ServerState name clients clientItems' queue' nextDelivId'
                            -- If getter's unackedItems map exists, insert unacked item
                            Just unackedItems -> do
                                let unackedItems' = Map.insert nextDelivId item unackedItems
                                    clientItems' = Map.insert getterId unackedItems' clientItems
                                -- Send item to getter
                                send getterId $ Delivery nextDelivId item
                                -- Return modified state
                                return $ ServerState name clients clientItems' queue' nextDelivId'

pushUnacked :: UnackedItems -> Queue Item -> Queue Item
pushUnacked unackedItems queue =
    pushList queue unackedItemsList
    where
        unackedItemsList = map snd $ Map.toList unackedItems
        pushList :: Queue Item -> [Item] -> Queue Item
        pushList queue [] = queue
        pushList queue (item:items) =
            pushList queue' items
            where
                queue' = push item queue

-- Handler function for when a client acknowledges the receival of an item
ackHandler :: ServerState -> Ack -> Process ServerState
ackHandler
    (ServerState name clients clientItems queue nextDelivId)
    (Ack ackerId delivId) = do
        case Map.lookup ackerId clients of
            -- If message received from unconnected client
            Nothing -> do
                -- Tell unconnected client that they're unrecognized by server
                send ackerId UnrecognizedClientNotification
                -- Drop message and return state
                return $ ServerState name clients clientItems queue nextDelivId
            -- If message is received from connected client
            Just clientRef -> do
                -- Get acker's unackedItems map 
                case Map.lookup ackerId clientItems of
                    -- If acker's unackedItems map doesn't exist, close connection
                    Nothing -> do
                        -- Delete client entry
                        let clients' = Map.delete ackerId clients
                        -- Unmonitor client
                        unmonitor clientRef
                        -- Return modified state
                        return $ ServerState name clients' clientItems queue nextDelivId
                    -- If acker's unackedItems map exists, remove acked item
                    Just unackedItems -> do
                        case Map.notMember delivId unackedItems of
                            -- If the ack is false, close the client's connection
                            True -> do
                                -- Send client connection closed message
                                send ackerId $ ConnectionClosedNotification FalseAck
                                -- Add all unacked items of that client back into the queue
                                let queue' = pushUnacked unackedItems queue
                                    -- Delete clientItems entry
                                    clientItems' = Map.delete ackerId clientItems
                                    -- Delete client entry
                                    clients' = Map.delete ackerId clients
                                -- Unmonitor client
                                unmonitor clientRef
                                -- Return modified state
                                return $ ServerState name clients' clientItems' queue' nextDelivId
                            False -> do
                                let unackedItems' = Map.delete delivId unackedItems
                                    clientItems' = Map.insert ackerId unackedItems' clientItems
                                -- Return modified state
                                return $ ServerState name clients clientItems' queue nextDelivId
                        
-- Handler function for when a client negatively acknowledges the receival of an item
nackHandler :: ServerState -> Nack -> Process ServerState
nackHandler 
    (ServerState name clients clientItems queue nextDelivId)
    (Nack nackerId delivId) = do
        case Map.lookup nackerId clients of
            -- If message receive from unconnected client
            Nothing -> do
                -- Tell unconnected client that they're unrecognized by server
                send nackerId UnrecognizedClientNotification
                -- Drop message and return state
                return $ ServerState name clients clientItems queue nextDelivId
            -- If message is received from connected client
            Just clientRef -> do
                -- Get acker's unackedItems map 
                case Map.lookup nackerId clientItems of
                    -- If acker's unackedItems map doesn't exist, close connection
                    Nothing -> do
                        -- Delete client entry
                        let clients' = Map.delete nackerId clients
                        -- Unmonitor client
                        unmonitor clientRef
                        -- Return modified state
                        return $ ServerState name clients' clientItems queue nextDelivId
                    -- If nacker's unackedItems map exists, remove nacked item and push it to queue
                    Just unackedItems -> do
                        case Map.lookup delivId unackedItems of
                            -- If the nack is false, close the client's connection
                            Nothing -> do
                                -- Send client connection closed message
                                send nackerId $ ConnectionClosedNotification FalseAck
                                -- Add all unacked items of that client back into the queue
                                let queue' = pushUnacked unackedItems queue
                                    -- Delete clientItems entry
                                    clientItems' = Map.delete nackerId clientItems
                                    -- Delete client entry
                                    clients' = Map.delete nackerId clients
                                -- Unmonitor client
                                unmonitor clientRef
                                -- Return modified state
                                return $ ServerState name clients' clientItems' queue' nextDelivId
                            Just item -> do
                                let unackedItems' = Map.delete delivId unackedItems
                                    clientItems' = Map.insert nackerId unackedItems' clientItems
                                    queue' = push item queue
                                -- Return modified state
                                return $ ServerState name clients clientItems' queue' nextDelivId

-- Handler function for client disconnects
disconnectHandler :: ServerState -> ProcessMonitorNotification -> Process ServerState
disconnectHandler
    (ServerState name clients clientItems queue nextDelivId)
    (ProcessMonitorNotification disconnectRef disconnectId _) = do
        case Map.notMember disconnectId clients of
            -- If disconnect message is not for a client
            True -> do
                -- Unmonitor this non-client
                unmonitor disconnectRef
                -- Return modified state
                return $ ServerState name clients clientItems queue nextDelivId
            -- If disconnect message is for a client
            False -> do
                case Map.lookup disconnectId clientItems of
                    -- If disconnecter does not an unackedItems entry
                    Nothing -> do
                        -- Delete client entry
                        let clients' = Map.delete disconnectId clients
                        -- Unmonitor client
                        unmonitor disconnectRef
                        -- Return modified state
                        return $ ServerState name clients' clientItems queue nextDelivId
                    -- If disconnect does have an unackedItems entry
                    Just unackedItems -> do
                        -- Add all unacked items of that client back into the queue
                        let queue' = pushUnacked unackedItems queue
                            -- Delete clientItems entry
                            clientItems' = Map.delete disconnectId clientItems
                            -- Delete client entry
                            clients' = Map.delete disconnectId clients
                        -- Unmonitor client
                        unmonitor disconnectRef
                        -- Return modifified state
                        return $ ServerState name clients' clientItems' queue' nextDelivId