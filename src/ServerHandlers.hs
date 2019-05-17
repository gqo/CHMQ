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

-- unsafe on empty queue
nextConsumer :: Queue ClientId -> (ClientId, Queue ClientId)
nextConsumer queue
    | isEmpty queue = error "nextConsumer call on empty queue"
    | otherwise =
        (consumer, queue'')
        where
            (queue', consumer) = unsafePop queue
            queue'' = push consumer queue'

-- pushes new item onto given server queue or forwards it to the next consumer 
-- for that queue
pushOrForward :: ServerState -> Item -> ServerQueue -> Process ServerState
pushOrForward
    (ServerState name clients clientItems queues nextDelivId)
    (Item source body)
    (ServerQueue queue exFlag consumers) = do
        -- Check if there are registered consumers
        case isEmpty consumers of
            -- If there aren't any registered,
            True -> do
                -- Push the new item into the queue and update the ServerQueues map
                let queue' = push (Item source body) queue
                    queues' = Map.insert source (ServerQueue queue' exFlag consumers) queues
                -- Return modified state
                return $ ServerState name clients clientItems queues' nextDelivId
            -- If there are some registered,
            False -> do
                -- Get the next consumer and update the ServerQueues map
                let (consumer, consumers') = nextConsumer consumers
                    queues' = Map.insert source (ServerQueue queue exFlag consumers') queues
                    nextDelivId' = nextDelivId + 1
                    item = Item source body
                -- Get consumers unackedItems map
                case Map.lookup consumer clientItems of
                    -- If consumers map doesn't exist, create it and insert the item
                    Nothing -> do
                        let unackedItems' = Map.fromList [(nextDelivId, item)]
                            clientItems' = Map.insert consumer unackedItems' clientItems
                        -- Send item to consumer
                        send consumer $ Delivery nextDelivId body
                        -- Return modified state
                        return $ ServerState name clients clientItems' queues' nextDelivId'
                    -- If consumers map does exist, just insert the item
                    Just unackedItems -> do
                        let unackedItems' = Map.insert nextDelivId item unackedItems
                            clientItems' = Map.insert consumer unackedItems' clientItems
                        -- Send item to consumer
                        send consumer $ Delivery nextDelivId body
                        -- Return modified state
                        return $ ServerState name clients clientItems' queues' nextDelivId'

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
                say "Looking up server queue..."
                -- Lookup server queue by name
                case Map.lookup queueName queues of
                    -- If queue doesn't exist,
                    Nothing -> do
                        say "Queue not found. Sending error back to client..."
                        -- Send an unrecognized queue name notification
                        send publisherId UnrecognizedQueueNameNotification
                        -- Return state
                        return $ ServerState name clients clientItems queues nextDelivId
                    -- If queue does exist,
                    Just sQueue -> do
                        say "Queue found. Push/forwarding message and confirming with client..."
                        let state = ServerState name clients clientItems queues nextDelivId
                            item = Item queueName itemBody
                        state' <- pushOrForward state item sQueue
                        -- Confirm receipt to publisher
                        send publisherId $ Confirm itemId
                        return state'

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
                say "Looking up server queue..."
                case Map.lookup queueName queues of
                    -- If queue doesn't exist,
                    Nothing -> do
                        say "Queue not found. Responding with error..."
                        -- Send an unrecognized queue name notification
                        send getterId UnrecognizedQueueNameNotification
                        -- Return state
                        return $ ServerState name clients clientItems queues nextDelivId
                    -- If queue does exist,
                    Just (ServerQueue queue exFlag consumers) -> do
                        say "Server found. Checking exclusivitiy..."
                        case exFlag of
                            -- If queue is being exclusively consumed,
                            True -> do
                                say "Queue marked exclusive. Responding with error..."
                                -- Send a get error notification
                                send getterId ExclusiveConsumerNotification
                                -- Return state
                                return $ ServerState name clients clientItems queues nextDelivId
                            -- If queue is not being exclusively consumed,
                            False -> do
                                say "Queue not exclusive. Attempting to pop item from queue..."
                                -- Pop an item from the queue
                                let (queue', maybeItem) = pop queue
                                case maybeItem of
                                    -- If queue is empty,
                                    Nothing -> do
                                        say "Queue empty. Responding with empty queue notification..."
                                        -- Send empty queue notif to client
                                        send getterId EmptyQueueNotification
                                        -- Return state
                                        return $ ServerState name clients clientItems queues nextDelivId
                                    -- If queue is not empty,
                                    Just (Item source body) -> do
                                        say "Item popped. Sending delivery to client..."
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

-- Pushes all given unackedItems back into appropriate queues or to appropriate consumers
handledUnacked :: ServerState -> UnackedItems -> Process ServerState
handledUnacked state unackedItems = do
    let itemsList = map snd $ Map.toList unackedItems
    state' <- pushOrForwardItems state itemsList
    return state'
    where
        pushOrForwardItems :: ServerState -> [Item] -> Process ServerState
        pushOrForwardItems state [] = return state
        pushOrForwardItems 
            (ServerState name clients clientItems queues nextDelivId)
            ((Item source body):items) = do
                let state = ServerState name clients clientItems queues nextDelivId
                case Map.lookup source queues of
                    Nothing -> do
                        state' <- pushOrForwardItems state items
                        return state'
                    Just sQueue -> do
                        let item = Item source body
                        state' <- pushOrForward state item sQueue
                        state'' <- pushOrForwardItems state' items
                        return state''

-- Removes client as consumer from server queue
removeConsumption :: ClientId -> ServerQueue -> ServerQueue
removeConsumption clientId (ServerQueue queue exFlag consumers)
    | isElem clientId consumers = removeConsumer clientId (ServerQueue queue exFlag consumers)
    | otherwise = (ServerQueue queue exFlag consumers)
        where
            removeConsumer :: ClientId -> ServerQueue -> ServerQueue
            removeConsumer clientId (ServerQueue queue exFlag consumers)
                | exFlag = ServerQueue queue False emptyQueue
                | otherwise = ServerQueue queue exFlag consumers'
                    where consumers' = removeQueueElem clientId consumers

-- Removes client as a consumer from all server queues
handleConsumptions :: ServerState -> ClientId -> Process ServerState
handleConsumptions 
    (ServerState name clients clientItems queues nextDelivId)
    clientId = do
        let queues' = Map.map (removeConsumption clientId) queues
        return $ ServerState name clients clientItems queues' nextDelivId

-- Removes client as a consumer from all queues, handles their unacked items, and unmonitors them
handleClose :: ServerState -> ClientId -> UnackedItems -> MonitorRef -> Process ServerState
handleClose state clientId unackedItems clientRef = do
    state' <- handledUnacked state unackedItems
    (ServerState name clients clientItems' queues' nextDelivId') <- handleConsumptions state' clientId
    let clients' = Map.delete clientId clients
        clientItems'' = Map.delete clientId clientItems'
    unmonitor clientRef
    return $ ServerState name clients' clientItems'' queues' nextDelivId'

-- Handler function for when a client acknowledges the receival of an item
ackHandler :: ServerState -> Ack -> Process ServerState
ackHandler
    (ServerState name clients clientItems queues nextDelivId)
    (Ack ackerId delivId) = do
        say $ "Received ack message from " ++ show ackerId
        case Map.lookup ackerId clients of
            -- If message received from unconnected client
            Nothing -> do
                say "Client was unconnected..."
                -- Tell unconnected client that they're unrecognized by server
                send ackerId UnrecognizedClientNotification
                -- Drop message and return state
                return $ ServerState name clients clientItems queues nextDelivId
            -- If message is received from connected client
            Just clientRef -> do
                say "Client was connected, attempting to pull unacked items map..."
                let state = ServerState name clients clientItems queues nextDelivId
                -- Get acker's unackedItems map 
                case Map.lookup ackerId clientItems of
                    -- If acker's unackedItems map doesn't exist, close connection
                    Nothing -> do
                        say "No unacked items. Removing consumptions and unmonitoring this client..."
                        (ServerState name' clients' clientItems' queues' nextDelivId') <- handleConsumptions state ackerId
                        -- Delete client entry
                        let clients'' = Map.delete ackerId clients'
                        -- Unmonitor client
                        unmonitor clientRef
                        -- Send client connection closed message
                        send ackerId $ ConnectionClosedNotification FalseAck
                        -- Return modified state
                        return $ ServerState name' clients'' clientItems' queues' nextDelivId'
                    -- If acker's unackedItems map exists, remove acked item
                    Just unackedItems -> do
                        say "Client had a map, finding message to be acked in their items..."
                        case Map.notMember delivId unackedItems of
                            -- If the ack is false, close the client's connection
                            True -> do
                                say "Item not found. Closing false connection..."
                                -- Send client connection closed message
                                send ackerId $ ConnectionClosedNotification FalseAck
                                -- Remove client from server data gracefully
                                state' <- handleClose state ackerId unackedItems clientRef
                                return state'
                            False -> do
                                say "Item found. Removing item from their unacked items..."
                                let unackedItems' = Map.delete delivId unackedItems
                                    clientItems' = Map.insert ackerId unackedItems' clientItems
                                -- Return modified state
                                return $ ServerState name clients clientItems' queues nextDelivId
                        
-- Handler function for when a client negatively acknowledges the receival of an item
nackHandler :: ServerState -> Nack -> Process ServerState
nackHandler 
    (ServerState name clients clientItems queues nextDelivId)
    (Nack nackerId delivId) = do
        say $ "Received nack message from " ++ show nackerId
        case Map.lookup nackerId clients of
            -- If message receive from unconnected client
            Nothing -> do
                say "Client was unconnected..."
                -- Tell unconnected client that they're unrecognized by server
                send nackerId UnrecognizedClientNotification
                -- Drop message and return state
                return $ ServerState name clients clientItems queues nextDelivId
            -- If message is received from connected client
            Just clientRef -> do
                say "Client was connected, attempting to pull unacked items map..."
                let state = ServerState name clients clientItems queues nextDelivId
                -- Get acker's unackedItems map 
                case Map.lookup nackerId clientItems of
                    -- If acker's unackedItems map doesn't exist, close connection
                    Nothing -> do
                        say "No unacked items. Removing consumptions and unmonitoring this client..."
                        (ServerState name' clients' clientItems' queues' nextDelivId') <- handleConsumptions state nackerId
                        -- Delete client entry
                        let clients'' = Map.delete nackerId clients'
                        -- Unmonitor client
                        unmonitor clientRef
                        -- Send client connection closed message
                        send nackerId $ ConnectionClosedNotification FalseNack
                        -- Return modified state
                        return $ ServerState name' clients'' clientItems' queues' nextDelivId'
                    -- If nacker's unackedItems map exists, remove nacked item and push it to queue
                    Just unackedItems -> do
                        say "Client had a map, finding message to be acked in their items..."
                        case Map.lookup delivId unackedItems of
                            -- If the nack is false, close the client's connection
                            Nothing -> do
                                say "Item not found. Closing false connection..."
                                -- Send client connection closed message
                                send nackerId $ ConnectionClosedNotification FalseNack
                                -- Remove client from server data gracefully
                                state' <- handleClose state nackerId unackedItems clientRef
                                -- Return modified state
                                return state'
                            Just item -> do
                                say "Item found. Removing item from their unacked items..."
                                let unackedItems' = Map.delete delivId unackedItems
                                    clientItems' = Map.insert nackerId unackedItems' clientItems
                                -- Return modified state
                                return $ ServerState name clients clientItems' queues nextDelivId

-- Handler function for client disconnects
disconnectHandler :: ServerState -> ProcessMonitorNotification -> Process ServerState
disconnectHandler
    (ServerState name clients clientItems queues nextDelivId)
    (ProcessMonitorNotification disconnectRef disconnectId _) = do
        say "Received a disconnect notification..."
        case Map.notMember disconnectId clients of
            -- If disconnect message is not for a client
            True -> do
                say "Received notification for unconnected client. Unmonitor this false client..."
                -- Unmonitor this non-client
                unmonitor disconnectRef
                -- Return modified state
                return $ ServerState name clients clientItems queues nextDelivId
            -- If disconnect message is for a client
            False -> do
                say "Received notification for connected client. Checking for unacked items..."
                let state = ServerState name clients clientItems queues nextDelivId
                case Map.lookup disconnectId clientItems of
                    -- If disconnecter does not an unackedItems entry
                    Nothing -> do
                        say "No unacked items. Removing consumptions and unmonitoring this client..."
                        (ServerState name' clients' clientItems' queues' nextDelivId') <- handleConsumptions state disconnectId
                        -- Delete client entry
                        let clients'' = Map.delete disconnectId clients'
                        -- Unmonitor client
                        unmonitor disconnectRef
                        -- Return modified state
                        return $ ServerState name' clients'' clientItems' queues' nextDelivId'
                    -- If disconnect does have an unackedItems entry
                    Just unackedItems -> do
                        say "Found unacked items. Pushing them back onto the queue and unmonitoring client..."
                        -- Remove client from server data gracefully
                        state' <- handleClose state disconnectId unackedItems disconnectRef
                        return state'
                        

-- Handler function for queue declaration messages
queueDeclareHandler :: ServerState -> QueueDeclare -> Process ServerState
queueDeclareHandler
    (ServerState name clients clientItems queues nextDelivId)
    (QueueDeclare declarerId queueName) = do
        say $ "Received queue declare message from " ++ show declarerId
        case Map.notMember declarerId clients of
            -- If message received from unconnected client
            True -> do
                say "Client was unconnected..."
                -- Tell unconnected client that they're unrecognized by server
                send declarerId UnrecognizedClientNotification
                -- Drop message and return state
                return $ ServerState name clients clientItems queues nextDelivId
            -- If message is received from connected client
            False -> do
                case Map.lookup queueName queues of
                    -- If queue exists,
                    Just sQueue -> do 
                        -- Queue declaration is idempotent, just return unmodified state
                        return (ServerState name clients clientItems queues nextDelivId)
                    -- If queue doesn't exist,
                    Nothing -> do
                        -- Construct a new queue and insert it into ServerQueues
                        let sQueue = ServerQueue emptyQueue False emptyQueue
                            queues' = Map.insert queueName sQueue queues
                        -- Return modified state
                        return $ ServerState name clients clientItems queues' nextDelivId
                    
-- Handler function for consume messages
consumeHandler :: ServerState -> Consume -> Process ServerState
consumeHandler
    (ServerState name clients clientItems queues nextDelivId)
    (Consume consumerId queueName exclusive) = do
        say $ "Received consume message from " ++ show consumerId
        let state = ServerState name clients clientItems queues nextDelivId
        case Map.notMember consumerId clients of
            -- If message received from unconnected client
            True -> do
                say "Client was unconnected..."
                -- Tell unconnected client that they're unrecognized by server
                send consumerId UnrecognizedClientNotification
                -- Drop message and return state
                return state
            -- If message is received from connected client
            False -> do
                say "Looking up server queue..."
                case Map.lookup queueName queues of
                    -- If queue doesn't exist,
                    Nothing -> do
                        say "Queue was not found. Responding with error..."
                        -- Send unrecognized queue notification
                        send consumerId UnrecognizedQueueNameNotification
                        -- Drop message and return state
                        return state
                    -- If queue does exist,
                    Just (ServerQueue queue exFlag consumers) -> do
                        say "Checking if queue is exclusive..."
                        case exFlag of
                            True -> do
                                say "Queue is marked exclusive. Responding with error..."
                                -- Send error for when a queue is marked exclusive
                                send consumerId RegisteredExclusiveConsumer
                                -- Drop message and return state
                                return state
                            False -> do
                                say "Queue is not marked exclusive. Checking valid consumption..."
                                case (exclusive && (not (isEmpty consumers))) of
                                    True -> do
                                        say "Attempting exclusive consumption of queue with consumers. Responding with error..."
                                        send consumerId RegisteredConsumersOnExclusive
                                        -- Drop message and return state
                                        return state
                                    False -> do
                                        say "Queue consumption is valid. Adding to server queue consumers..."
                                        let consumers' = push consumerId consumers
                                        case exclusive of
                                            -- Register consumer as exclusive consumer of queue
                                            True -> do
                                                let sQueue = ServerQueue queue True consumers'
                                                    queues' = Map.insert queueName sQueue queues
                                                return $ ServerState name clients clientItems queues' nextDelivId
                                            -- Register consumer as non-exclsuive consumer of queue
                                            False -> do
                                                let sQueue = ServerQueue queue exFlag consumers'
                                                    queues' = Map.insert queueName sQueue queues
                                                return $ ServerState name clients clientItems queues' nextDelivId

-- Handler function for stop consume messages
stopConsumeHandler :: ServerState -> StopConsume -> Process ServerState
stopConsumeHandler
    (ServerState name clients clientItems queues nextDelivId)
    (StopConsume stopperId queueName) = do
        say $ "Received stop consume message from" ++ show stopperId
        let state = ServerState name clients clientItems queues nextDelivId
        case Map.notMember stopperId clients of
            -- If message received from unconnected client
            True -> do
                say "Client was unconnected. Dropping message..."
                -- Drop message and return state
                return state
            -- If message received from connected client
            False -> do
                say "Looking up server queue..."
                case Map.lookup queueName queues of
                    -- If queue doesn't exist,
                    Nothing -> do
                        say "Queue was not found. Dropping message..."
                        -- Drop message and return state
                        return state
                    -- If queue does exist,
                    Just sQueue -> do
                        say "Queue found. Removing consumer..."
                        let sQueue' = removeConsumption stopperId sQueue
                            queues' = Map.insert queueName sQueue' queues
                        return $ ServerState name clients clientItems queues' nextDelivId
                                            
-- publishHandler :: ServerState -> Publish -> Process ServerState
-- publishHandler state _ = return state

-- getHandler :: ServerState -> Get -> Process ServerState
-- getHandler state _ = return state

-- ackHandler :: ServerState -> Ack -> Process ServerState
-- ackHandler state _ = return state

-- nackHandler :: ServerState -> Nack -> Process ServerState
-- nackHandler state _ = return state

-- disconnectHandler :: ServerState -> ProcessMonitorNotification -> Process ServerState
-- disconnectHandler state _ = return state

-- queueDeclareHandler :: ServerState -> QueueDeclare -> Process ServerState
-- queueDeclareHandler state _ = return state

-- consumeHandler :: ServerState -> Consume -> Process ServerState
-- consumeHandler state _ = return state