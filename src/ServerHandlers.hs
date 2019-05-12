module ServerHandlers where

import Control.Distributed.Process
import qualified Data.Map as Map

import Messages
import ServerTypes
import Queue

-- Handler function for connecting a new client to the server
clientConnHandler :: ServerState -> ClientConnection -> Process ServerState
clientConnHandler 
    (ServerState name clients clientItems queues nextDelivId)
    (ClientConnection newClientId) = do
        say "Received client connection message..."
        case Map.member newClientId clients of
            -- If client is connected already
            True -> do
                say "Client was connected already..."
                -- Reconfirm with client that they're connected
                send newClientId ConfirmConnection
                -- Return state
                return $ ServerState name clients clientItems queues nextDelivId
            -- If client is a new connection
            False -> do
                say "Client was not connected, adding client to map..."
                -- Start monitoring new client
                clientMonitorRef <- monitor newClientId
                -- Add client to clients map and initialize their unacked items map
                let clients' = Map.insert newClientId clientMonitorRef clients
                    clientItems' = Map.insert newClientId Map.empty clientItems
                -- Confirm with client that they're connected
                send newClientId ConfirmConnection
                -- Return modified state
                return $ ServerState name clients' clientItems' queues nextDelivId

-- publish still needs to forward message to next consumer if there is one
-- Handler function for when a client publishes an item to the queue
publishHandler :: ServerState -> Publish -> Process ServerState
publishHandler 
    (ServerState name clients clientItems queues nextDelivId)
    (Publish publisherId itemId itemBody queueName) = do
        say $ "Received publish message from " ++ show publisherId
        case Map.notMember publisherId clients of
            -- If message received from unconnected client
            True -> do
                say "Client was unconnected..."
                -- Tell unconnected client that they're unrecognized by server
                send publisherId UnrecognizedClientNotification
                -- Drop message and return state
                return $ ServerState name clients clientItems queues nextDelivId
            -- If message is received from connected client
            False -> do
                -- Lookup server queue by name
                case Map.lookup queueName queues of
                    -- If queue doesn't exist,
                    Nothing -> do
                        -- Send an unrecognized queue name notification
                        send publisherId UnrecognizedQueueNameNotification
                        -- Return state
                        return $ ServerState name clients clientItems queues nextDelivId
                    -- If queue does exist,
                    Just (ServerQueue queue exFlag consumers) -> do
                        -- Push the new item into the queue and update the ServerQueues map
                        let queue' = push (Item queueName itemBody) queue
                            queues' = Map.insert queueName (ServerQueue queue' exFlag consumers) queues
                        -- Confirm receipt to publisher
                        send publisherId $ Confirm itemId
                        -- Return modified state
                        return $ ServerState name clients clientItems queues' nextDelivId

-- Handler function for when a client requests an item from the queue
getHandler :: ServerState -> Get -> Process ServerState
getHandler
    (ServerState name clients clientItems queues nextDelivId)
    (Get getterId queueName) = do
        say $ "Received get message from " ++ show getterId
        case Map.notMember getterId clients of
            -- If message received from unconnected client
            True -> do
                say "Client was unconnected..."
                -- Tell unconnected client that they're unrecognized by server
                send getterId UnrecognizedClientNotification
                -- Drop message and return state
                return $ ServerState name clients clientItems queues nextDelivId
            -- If message is received from connected client
            False -> do
                case Map.lookup queueName queues of
                    -- If queue doesn't exist,
                    Nothing -> do
                        -- Send an unrecognized queue name notification
                        send getterId UnrecognizedQueueNameNotification
                        -- Return state
                        return $ ServerState name clients clientItems queues nextDelivId
                    -- If queue does exist,
                    Just (ServerQueue queue exFlag consumers) -> do
                        case exFlag of
                            -- If queue is being exclusively consumed,
                            True -> do
                                -- Send a get error notification
                                send getterId ExclusiveConsumerNotification
                                -- Return state
                                return $ ServerState name clients clientItems queues nextDelivId
                            -- If queue is not being exclusively consumed,
                            False -> do
                                -- Pop an item from the queue
                                let (queue', maybeItem) = pop queue
                                case maybeItem of
                                    -- If queue is empty,
                                    Nothing -> do
                                        -- Send empty queue notif to client
                                        send getterId EmptyQueueNotification
                                        -- Return state
                                        return $ ServerState name clients clientItems queues nextDelivId
                                    -- If queue is not empty,
                                    Just (Item source body) -> do
                                        let nextDelivId' = nextDelivId + 1
                                            item = Item source body
                                        -- Get getter's unackedItems map
                                        case Map.lookup getterId clientItems of
                                            -- If getter's unackedItems map doens't exist, create it and insert it
                                            Nothing -> do
                                                let unackedItems' = Map.fromList [(nextDelivId, item)]
                                                    clientItems' = Map.insert getterId unackedItems' clientItems
                                                    queues' = Map.insert queueName (ServerQueue queue' exFlag consumers) queues
                                                -- Send item to getter
                                                send getterId $ Delivery nextDelivId body
                                                -- Return modified state
                                                return $ ServerState name clients clientItems' queues' nextDelivId'
                                            -- If getter's unackedItems map does exist, insert the item
                                            Just unackedItems -> do
                                                let unackedItems' = Map.insert nextDelivId item unackedItems
                                                    clientItems' = Map.insert getterId unackedItems' clientItems
                                                    queues' = Map.insert queueName (ServerQueue queue' exFlag consumers) queues
                                                -- Send item to getter
                                                send getterId $ Delivery nextDelivId body
                                                -- Return modified state
                                                return $ ServerState name clients clientItems' queues' nextDelivId'

-- pushUnacked :: UnackedItems -> Queue Item -> Queue Item
-- pushUnacked unackedItems queue =
--     pushList queue unackedItemsList
--     where
--         unackedItemsList = map snd $ Map.toList unackedItems
--         pushList :: Queue Item -> [Item] -> Queue Item
--         pushList queue [] = queue
--         pushList queue (item:items) =
--             pushList queue' items
--             where
--                 queue' = push item queue

-- -- Handler function for when a client acknowledges the receival of an item
-- ackHandler :: ServerState -> Ack -> Process ServerState
-- ackHandler
--     (ServerState name clients clientItems queue nextDelivId)
--     (Ack ackerId delivId) = do
--         say $ "Received ack message from " ++ show ackerId
--         case Map.lookup ackerId clients of
--             -- If message received from unconnected client
--             Nothing -> do
--                 say "Client was unconnected..."
--                 -- Tell unconnected client that they're unrecognized by server
--                 send ackerId UnrecognizedClientNotification
--                 -- Drop message and return state
--                 return $ ServerState name clients clientItems queue nextDelivId
--             -- If message is received from connected client
--             Just clientRef -> do
--                 say "Client was connected, attempting to pull unacked items map..."
--                 -- Get acker's unackedItems map 
--                 case Map.lookup ackerId clientItems of
--                     -- If acker's unackedItems map doesn't exist, close connection
--                     Nothing -> do
--                         say "Client had no map. Closing false connection..."
--                         -- Delete client entry
--                         let clients' = Map.delete ackerId clients
--                         -- Unmonitor client
--                         unmonitor clientRef
--                         -- Return modified state
--                         return $ ServerState name clients' clientItems queue nextDelivId
--                     -- If acker's unackedItems map exists, remove acked item
--                     Just unackedItems -> do
--                         say "Client had a map, finding message to be acked in their items..."
--                         case Map.notMember delivId unackedItems of
--                             -- If the ack is false, close the client's connection
--                             True -> do
--                                 say "Item not found. Closing false connection..."
--                                 -- Send client connection closed message
--                                 send ackerId $ ConnectionClosedNotification FalseAck
--                                 -- Add all unacked items of that client back into the queue
--                                 let queue' = pushUnacked unackedItems queue
--                                     -- Delete clientItems entry
--                                     clientItems' = Map.delete ackerId clientItems
--                                     -- Delete client entry
--                                     clients' = Map.delete ackerId clients
--                                 -- Unmonitor client
--                                 unmonitor clientRef
--                                 -- Return modified state
--                                 return $ ServerState name clients' clientItems' queue' nextDelivId
--                             False -> do
--                                 say "Item found. Removing item from their unacked items..."
--                                 let unackedItems' = Map.delete delivId unackedItems
--                                     clientItems' = Map.insert ackerId unackedItems' clientItems
--                                 -- Return modified state
--                                 return $ ServerState name clients clientItems' queue nextDelivId
                        
-- -- Handler function for when a client negatively acknowledges the receival of an item
-- nackHandler :: ServerState -> Nack -> Process ServerState
-- nackHandler 
--     (ServerState name clients clientItems queue nextDelivId)
--     (Nack nackerId delivId) = do
--         say $ "Received nack message from " ++ show nackerId
--         case Map.lookup nackerId clients of
--             -- If message receive from unconnected client
--             Nothing -> do
--                 say "Client was unconnected..."
--                 -- Tell unconnected client that they're unrecognized by server
--                 send nackerId UnrecognizedClientNotification
--                 -- Drop message and return state
--                 return $ ServerState name clients clientItems queue nextDelivId
--             -- If message is received from connected client
--             Just clientRef -> do
--                 say "Client was connected, attempting to pull unacked items map..."
--                 -- Get acker's unackedItems map 
--                 case Map.lookup nackerId clientItems of
--                     -- If acker's unackedItems map doesn't exist, close connection
--                     Nothing -> do
--                         say "Client had no map. Closing false connection..."
--                         -- Delete client entry
--                         let clients' = Map.delete nackerId clients
--                         -- Unmonitor client
--                         unmonitor clientRef
--                         -- Return modified state
--                         return $ ServerState name clients' clientItems queue nextDelivId
--                     -- If nacker's unackedItems map exists, remove nacked item and push it to queue
--                     Just unackedItems -> do
--                         say "Client had a map, finding message to be acked in their items..."
--                         case Map.lookup delivId unackedItems of
--                             -- If the nack is false, close the client's connection
--                             Nothing -> do
--                                 say "Item not found. Closing false connection..."
--                                 -- Send client connection closed message
--                                 send nackerId $ ConnectionClosedNotification FalseAck
--                                 -- Add all unacked items of that client back into the queue
--                                 let queue' = pushUnacked unackedItems queue
--                                     -- Delete clientItems entry
--                                     clientItems' = Map.delete nackerId clientItems
--                                     -- Delete client entry
--                                     clients' = Map.delete nackerId clients
--                                 -- Unmonitor client
--                                 unmonitor clientRef
--                                 -- Return modified state
--                                 return $ ServerState name clients' clientItems' queue' nextDelivId
--                             Just item -> do
--                                 say "Item found. Removing item from their unacked items..."
--                                 let unackedItems' = Map.delete delivId unackedItems
--                                     clientItems' = Map.insert nackerId unackedItems' clientItems
--                                     queue' = push item queue
--                                 -- Return modified state
--                                 return $ ServerState name clients clientItems' queue' nextDelivId

-- -- Handler function for client disconnects
-- disconnectHandler :: ServerState -> ProcessMonitorNotification -> Process ServerState
-- disconnectHandler
--     (ServerState name clients clientItems queue nextDelivId)
--     (ProcessMonitorNotification disconnectRef disconnectId _) = do
--         say "Received a disconnect notification..."
--         case Map.notMember disconnectId clients of
--             -- If disconnect message is not for a client
--             True -> do
--                 say "Received notification for unconnected client. Unmonitor this false client..."
--                 -- Unmonitor this non-client
--                 unmonitor disconnectRef
--                 -- Return modified state
--                 return $ ServerState name clients clientItems queue nextDelivId
--             -- If disconnect message is for a client
--             False -> do
--                 say "Received notification for connected client. Checking for unacked items..."
--                 case Map.lookup disconnectId clientItems of
--                     -- If disconnecter does not an unackedItems entry
--                     Nothing -> do
--                         say "No unacked items. Unmonitoring this client..."
--                         -- Delete client entry
--                         let clients' = Map.delete disconnectId clients
--                         -- Unmonitor client
--                         unmonitor disconnectRef
--                         -- Return modified state
--                         return $ ServerState name clients' clientItems queue nextDelivId
--                     -- If disconnect does have an unackedItems entry
--                     Just unackedItems -> do
--                         say "Found unacked items. Pushing them back onto the queue and unmonitoring client..."
--                         -- Add all unacked items of that client back into the queue
--                         let queue' = pushUnacked unackedItems queue
--                             -- Delete clientItems entry
--                             clientItems' = Map.delete disconnectId clientItems
--                             -- Delete client entry
--                             clients' = Map.delete disconnectId clients
--                         -- Unmonitor client
--                         unmonitor disconnectRef
--                         -- Return modifified state
--                         return $ ServerState name clients' clientItems' queue' nextDelivId

-- publishHandler :: ServerState -> Publish -> Process ServerState
-- publishHandler state _ = return state

-- getHandler :: ServerState -> Get -> Process ServerState
-- getHandler state _ = return state

ackHandler :: ServerState -> Ack -> Process ServerState
ackHandler state _ = return state

nackHandler :: ServerState -> Nack -> Process ServerState
nackHandler state _ = return state

disconnectHandler :: ServerState -> ProcessMonitorNotification -> Process ServerState
disconnectHandler state _ = return state

queueDeclareHandler :: ServerState -> QueueDeclare -> Process ServerState
queueDeclareHandler state _ = return state

consumeHandler :: ServerState -> Consume -> Process ServerState
consumeHandler state _ = return state