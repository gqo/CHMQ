module Main where

import Control.Distributed.Process (liftIO)
import Control.Distributed.Process.Node (initRemoteTable, newLocalNode)
import Network.Transport.TCP (createTransport, defaultTCPParameters)

import Data.ByteString (ByteString)
import Data.ByteString.Char8 (pack)
import Control.Lens.Internal.ByteString (unpackStrict8)

import Control.Concurrent (threadDelay)

import Client
import ClientTypes

main :: IO ()
main = do
    let clientAddr = "127.0.0.1"
        clientPort = "10502"
        serverAddr = "127.0.0.1:10501"
        serverName = "CHMQ-Server-0"
    putStrLn $ "Creating client transport layer..."
    -- Create new tcp transport layer with default args
    eitherT <- createTransport clientAddr clientPort defaultTCPParameters
    case eitherT of
        -- If creation is sucessful
        Right t -> do
            -- Create new local client node on the transport layer
            clientNode <- newLocalNode t initRemoteTable
            -- Run a client
            runClient clientNode $ do
                maybeState <- dialServer serverAddr serverName
                case maybeState of
                    Nothing -> do
                        clientLog "Dial server failure"
                        return ()
                    Just state -> do
                        clientLog "Publishing hello world message!"
                        eitherState' <- publish state (pack "Hello world!")
                        case eitherState' of
                            Right error -> do
                                clientLog $ "Received error: " ++ show error
                                return ()
                            Left state' -> do
                                clientLog "Getting message from queue!"
                                eitherState'' <- get state'
                                case eitherState'' of
                                    Right error -> do
                                        clientLog $ "Received error: " ++ show error
                                        return ()
                                    Left ((ClientDelivery delivId body), state'') -> do
                                        let message = unpackStrict8 body
                                        clientLog $ "Got message with id " ++ show delivId ++ " and body: " ++ message
                                        clientLog "Getting message from queue!"
                                        eitherState3 <- get state''
                                        case eitherState3 of
                                            Right error -> do
                                                clientLog $ "Received error: " ++ show error
                                                return ()
                                            Left ((ClientDelivery delivId' body'), state3) -> do
                                                let message' = unpackStrict8 body'
                                                clientLog $ "Got message with id " ++ show delivId' ++ " and body: " ++ message'
                                                clientLog $ "Acking message: " ++ show delivId
                                                eitherState4 <- ack state3 delivId
                                                case eitherState4 of
                                                    Right error -> do
                                                        clientLog $ "Received error: " ++ show error
                                                    Left state4 -> do
                                                        clientLog "Successfully acked the message."
                                                        return ()
            liftIO $ threadDelay 90000000
        -- If creation is unsuccessful
        Left error -> print error
