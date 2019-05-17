module Main where

import Control.Distributed.Process (liftIO)
import Control.Concurrent (threadDelay)
import Data.ByteString.Char8 (pack)
import Control.Lens.Internal.ByteString (unpackStrict8)

import Client
import ClientTypes

errorHandler :: Client (Maybe ClientError) -> Client ()
errorHandler proc = do
    err <- proc
    case err of
        Nothing -> clog $ "Action successful."
        Just err -> clog $ "Received err: " ++ show err

deliveryHandler :: Bool -> Client (Either ClientError ClientDelivery) -> Client ()
deliveryHandler isAck proc = do
    eitherDeliv <- proc
    case eitherDeliv of
        Left err -> clog $ "Get error: " ++ show err
        Right (ClientDelivery delivId body) -> do
            let message = unpackStrict8 body
            clog $ "Get successful: {Id: " ++ show delivId ++ ", Body: " ++ message ++ "}"
            case isAck of
                True -> do
                    errorHandler $ ack delivId
                False -> do
                    errorHandler $ nack delivId

consumeHandler :: ClientDelivery -> Client (Maybe String)
consumeHandler (ClientDelivery delivId body) = do
    let message = unpackStrict8 body
    case (message == "stop") of
        True -> do
            errorHandler $ ack delivId
            return (Just "Received stop message")
        False -> do
            clog $ "Consumed message: {Id: " ++ show delivId ++ ", Body: " ++ message ++ "}"
            errorHandler $ ack delivId
            return Nothing

main :: IO ()
main = do
    let clientAddr = "127.0.0.1"
        clientPort = "10503"
        serverAddr = "127.0.0.1:10501"
        serverName = "CHMQ-Server-0"
    eitherCNode <- newClientNode clientAddr clientPort
    case eitherCNode of
        Right cNode -> do
            runClient cNode serverAddr serverName $ do
                errorHandler $ declareQueue "default"
                -- eitherReturnData <- consume "default" False consumeHandler
                -- case eitherReturnData of
                --     Left err -> clog $ show err
                --     Right returnData -> clog returnData
                -- errorHandler $ declareQueue "test"
                errorHandler $ publish "default" (pack "Hi there!")
                errorHandler $ publish "default" (pack "stop")
                -- errorHandler $ publish "default" (pack "Hi again!")
                -- errorHandler $ publish "test" (pack "Test message")
                -- deliveryHandler True $ get "default"
                -- deliveryHandler False $ get "test"
                liftIO $ threadDelay 9000000000
        Left error -> print error