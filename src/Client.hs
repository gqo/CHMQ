module Client 
    ( runClient
    , dialServer
    , publish
    , get
    , ack
    , nack
    , clientLog
    , PublishError
    , GetError
    , AckError
    , NackError
    )
where

import Control.Distributed.Process
import Control.Distributed.Process.Node (runProcess, LocalNode)

import Network.Transport (EndPointAddress(EndPointAddress))
import Data.ByteString.Char8 (pack)
import Data.ByteString (ByteString)

import qualified Data.Map as Map (empty, insert, lookup, delete)

import Control.Monad.Reader (ask)

import ClientTypes
import Messages

data PublishError = PublishTimeout | PublishUnrecognized | PublishFalseConfirm
    deriving (Show)
data GetError = GetTimeout | GetEmptyQueue | GetUnrecognized
    deriving (Show)
data AckError = AckClientsideFalse | AckServersideFalse | AckUnrecognized
    deriving (Show)
data NackError = NackClientsideFalse | NackServersideFalse | NackUnrecognized
    deriving (Show)

type ClientProcessWrapper = Process

type Second = Int
type Microsecond = Int

toMicro :: Second -> Microsecond
toMicro = (*) 1000000

class (Monad m) => MonadProcess m where
    liftProc :: Process a -> m a

instance MonadProcess Process where
    liftProc = id

-- publishM :: ByteString -> ClientProc ()
-- publishM msg = do
--     clProc <- ask
--     let nextPubId = nextPublishId clProc
--         selfNode  = clientNode clProc
--         serverPid = serverId clProc
--     liftProc $ runProcess selfNode do
--         self <- getSelfPid
--         send serverPid $ Publish self nextPubId msg
--         response <- receiveTimeout (toMicro 1) [
--               match $ confirmHandler nextPubId
--             , match $ unrecognizedConnHandler
--             ]
--         --- can i return this response?
--         return ()
    
--     where
--         unrecognizedConnHandler :: UnrecognizedClientNotification -> Process (Maybe PublishError)
--         unrecognizedConnHandler _ =
--             return (Just PublishUnrecognized)
--         confirmHandler :: ClientPublishId -> Confirm -> Process (Maybe PublishError)
--         confirmHandler publishId (Confirm serverPublishId) =
--             case publishId == serverPublishId of
--                 True ->
--                     return Nothing
--                 False ->
--                     return (Just PublishFalseConfirm)




-- runClient acts as a runProcess wrapper to prevent the need of importing Control.Distributed.Process
runClient :: LocalNode -> ClientProcessWrapper () -> IO ()
runClient node proc = runProcess node proc

clientLog :: String -> ClientProcessWrapper ()
clientLog = say

-- dialServer initializes the connection to the CHMQ server specified
dialServer :: ServerAddress -> ServerName -> ClientProcessWrapper (Maybe ClientState)
dialServer serverAddr serverName = do
    -- construct server's nodeId
    let serverAddr' = serverAddr ++ ":0"
    say $ "Dialing server at the address: " ++ serverAddr'
    let serverNodeId = NodeId $ EndPointAddress $ pack serverAddr'
    say $ "Constructed serverNodeId: " ++ show serverNodeId
    say $ "Server name: " ++ serverName
    say $ "Calling whereisRemoteAsync..."
    -- ask the remote table for the server's pid
    whereisRemoteAsync serverNodeId serverName
    -- expect a respond (timeout 1 second)
    say $ "Expecting reply with timeout (microseconds): " ++ show (toMicro 5)
    serverPidReply <- expectTimeout (toMicro 5) :: Process (Maybe WhereIsReply)
    case serverPidReply of
        -- if there's response
        Just (WhereIsReply _ maybeServerPid) -> do
            say "Received a WhereIsReply..."
            case maybeServerPid of
                -- if the server is in the remote table
                Just serverPid -> do
                    say "ServerPid returned in maybe..."
                    -- get clientPid
                    self <- getSelfPid
                    say "Sending ClientConnection message..."
                    -- send server a connection request message
                    send serverPid $ ClientConnection self
                    -- expect a confirmation of the connection
                    say "Expecting reply..."
                    serverConnectionReply <- expectTimeout (toMicro 1) :: Process (Maybe ConfirmConnection)
                    case serverConnectionReply of
                        -- if the server accepted the connection, link and return new state
                        Just reply -> do
                            say "Reply received, linking to server and returning state..."
                            -- establish a link to the server (client proc will close if server closes)
                            link serverPid
                            let state = ClientState serverPid 0 0 Map.empty
                            return (Just state)
                        -- if the server did not respond,
                        Nothing -> do
                            say "Server did not respond to client connection..."
                            return Nothing
                Nothing -> do
                    say "ServerPid was not found in remote table..."
                    return Nothing
        Nothing -> do
            say "Did not receive WhereIsReply..."
            return Nothing

publish :: ClientState -> ByteString -> ClientProcessWrapper (Either ClientState PublishError)
publish (ClientState serverPid nextPubId nextDelivId unackedDeliveries) messageBody = do
    -- Get self ProcessId
    self <- getSelfPid
    -- Increment nextPubId
    let nextPubId' = nextPubId + 1
    -- Send server publish message
    send serverPid $ Publish self nextPubId messageBody
    -- Wait for confirmation or error message
    response <- receiveTimeout (toMicro 1) [
          match $ confirmHandler nextPubId
        , match $ unrecognizedConnHandler
        ]
    case response of
        -- If response is received...
        Just maybeError -> do
            case maybeError of
                -- If response was an error, return error
                Just error ->
                    return $ Right error
                -- Otherwise, return new state
                Nothing -> do
                    let state' = Left $ ClientState serverPid nextPubId' nextDelivId unackedDeliveries
                    return state'
        -- If no response is received, return error
        Nothing ->
            return $ Right PublishTimeout
    where
        unrecognizedConnHandler :: UnrecognizedClientNotification -> ClientProcessWrapper (Maybe PublishError)
        unrecognizedConnHandler _ =
            return (Just PublishUnrecognized)
        confirmHandler :: ClientPublishId -> Confirm -> ClientProcessWrapper (Maybe PublishError)
        confirmHandler publishId (Confirm serverPublishId) =
            case publishId == serverPublishId of
                True ->
                    return Nothing
                False ->
                    return (Just PublishFalseConfirm)

get :: ClientState -> ClientProcessWrapper (Either (ClientDelivery, ClientState) GetError)
get (ClientState serverPid nextPubId nextDelivId unackedDeliveries) = do
    -- Get self ProcessId
    self <- getSelfPid
    -- Send server get message
    send serverPid $ Get self
    -- Wait for delivery or error message
    response <- receiveTimeout (toMicro 1) [
          match $ deliveryHandler
        , match $ unrecognizedConnHandler
        , match $ emptyQueueHandler
        ]
    case response of
        -- If response is received
        Just eitherDeliv -> do
            case eitherDeliv of
                -- If there's an error, return it
                Right error ->
                    return $ Right error
                Left (Delivery deliveryId body) -> do
                    -- return delivery and new client state
                    let delivery = ClientDelivery nextDelivId body
                        unackedDeliveries' = Map.insert nextDelivId deliveryId unackedDeliveries
                        nextDelivId' = nextDelivId + 1
                        state' = ClientState serverPid nextPubId nextDelivId' unackedDeliveries'
                    return $ Left (delivery, state')
        -- If no response is received, return error
        Nothing ->
            return $ Right GetTimeout
    where
        deliveryHandler :: Delivery -> ClientProcessWrapper (Either Delivery GetError)
        deliveryHandler (Delivery deliveryId body) =
            return $ Left $ Delivery deliveryId body
        unrecognizedConnHandler :: UnrecognizedClientNotification -> ClientProcessWrapper (Either Delivery GetError)
        unrecognizedConnHandler _ =
            return $ Right GetUnrecognized
        emptyQueueHandler :: EmptyQueueNotification -> ClientProcessWrapper (Either Delivery GetError)
        emptyQueueHandler _ =
            return $ Right GetEmptyQueue

ack :: ClientState -> ClientDeliveryId -> ClientProcessWrapper (Either ClientState AckError)
ack (ClientState serverPid nextPubId nextDelivId unackedDeliveries) clientDelivId = do
    case Map.lookup clientDelivId unackedDeliveries of
        -- If there isn't an unackedDelivery with that clientDeliveryId
        Nothing -> do
            -- Return a clientside error
            return $ Right AckClientsideFalse
        -- If it there is a unackedDelivery entry
        Just deliveryId -> do
            -- Get self ProcessId
            self <- getSelfPid
            -- Send server ack message
            send serverPid $ Ack self deliveryId
            -- Wait for possible error response
            response <- receiveTimeout (toMicro 1) [
                  match $ connClosedHandler
                , match $ unrecognizedConnHandler
                ]
            case response of
                -- If no error response is received
                Nothing -> do
                    let unackedDeliveries' = Map.delete clientDelivId unackedDeliveries
                        state' = ClientState serverPid nextPubId nextDelivId unackedDeliveries'
                    -- Return modified client state
                    return $ Left state'
                Just error -> do
                    case error of
                        AckServersideFalse -> do
                            -- AckServersideFalse requires reconnection, unlink process
                            unlink serverPid
                            -- Return error
                            return $ Right AckServersideFalse
                        AckUnrecognized ->
                            return $ Right AckUnrecognized
    where
        connClosedHandler :: ConnectionClosedNotification -> ClientProcessWrapper AckError
        connClosedHandler _ =
            return AckServersideFalse
        unrecognizedConnHandler :: UnrecognizedClientNotification -> ClientProcessWrapper AckError
        unrecognizedConnHandler _ =
            return AckUnrecognized 

nack :: ClientState -> ClientDeliveryId -> ClientProcessWrapper (Either ClientState NackError)
nack (ClientState serverPid nextPubId nextDelivId unackedDeliveries) clientDelivId = do
    case Map.lookup clientDelivId unackedDeliveries of
        -- If there isn't an unackedDelivery with that clientDeliveryId
        Nothing -> do
            -- Return a clientside error
            return $ Right NackClientsideFalse
        -- If it there is a unackedDelivery entry
        Just deliveryId -> do
            -- Get self ProcessId
            self <- getSelfPid
            -- Send server nack message
            send serverPid $ Nack self deliveryId
            -- Wait for possible error response
            response <- receiveTimeout (toMicro 1) [
                  match $ connClosedHandler
                , match $ unrecognizedConnHandler
                ]
            case response of
                -- If no error response is received
                Nothing -> do
                    let unackedDeliveries' = Map.delete clientDelivId unackedDeliveries
                        state' = ClientState serverPid nextPubId nextDelivId unackedDeliveries'
                    -- Return modified client state
                    return $ Left state'
                Just error -> do
                    case error of
                        NackServersideFalse -> do
                            -- NackServersideFalse requires reconnection, unlink process
                            unlink serverPid
                            -- Return error
                            return $ Right NackServersideFalse
                        NackUnrecognized ->
                            return $ Right NackUnrecognized
    where
        connClosedHandler :: ConnectionClosedNotification -> ClientProcessWrapper NackError
        connClosedHandler _ =
            return NackServersideFalse
        unrecognizedConnHandler :: UnrecognizedClientNotification -> ClientProcessWrapper NackError
        unrecognizedConnHandler _ =
            return NackUnrecognized 