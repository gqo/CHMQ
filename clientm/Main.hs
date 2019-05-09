module Main where

import Control.Distributed.Process (liftIO)
import Control.Concurrent (threadDelay)
import Data.ByteString.Char8 (pack)
import Control.Lens.Internal.ByteString (unpackStrict8)

import ClientM
import ClientTypesM

main :: IO ()
main = do
    let clientAddr = "127.0.0.1"
        clientPort = "10502"
        serverAddr = "127.0.0.1:10501"
        serverName = "CHMQ-Server-0"
    eitherCNode <- newClientNode clientAddr clientPort
    case eitherCNode of
        Right cNode -> do
            runClient cNode serverAddr serverName $ do
                maybeErr <- publish (pack "Hello world!")
                case maybeErr of
                    Just err -> do
                        clog $ "Publish error."
                    Nothing -> do
                        clog $ "Publish successful."
                eitherDeliv <- get
                case eitherDeliv of
                    Left err -> do
                        clog $ "Get error: " ++ show err
                    Right (ClientDelivery delivId body) -> do
                        let message = unpackStrict8 body
                        clog $ "Get successful: {Id: " ++ show delivId ++ ", Body: " ++ message ++ "}"
                liftIO $ threadDelay 9000000000
        Left error -> print error