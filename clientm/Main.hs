module Main where

import Control.Distributed.Process (liftIO)
import Control.Concurrent (threadDelay)

import ClientM

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
                publish
                publish
                liftIO $ threadDelay 9000000000
        Left error -> print error