module Main where

import Control.Distributed.Process
import Control.Distributed.Process.Node (initRemoteTable, runProcess, newLocalNode)
import Network.Transport.TCP (createTransport, defaultTCPParameters)

import System.Environment (getArgs)

import ServerTypes
import Server

type Address = String
type Port = String

callLaunchServer :: Address -> Port -> ServerName -> IO ()
callLaunchServer address port name = do
    -- Create a new tcp transport layer with the given args
    eitherT <- createTransport address port defaultTCPParameters
    case eitherT of
        -- If creation is successful
        Right t -> do
            -- Create new local node on the transport layer
            serverNode <- newLocalNode t initRemoteTable
            -- Run that node as a CHMQ server
            runProcess serverNode $ do
                launchServer name
        -- If creation is unsuccessful, print the error
        Left error -> print error


main :: IO ()
main = do
    -- Get server address, port, and name: default to localhost:10501 and CHMQ-Server-0
    args <- getArgs
    case args of
        [] -> callLaunchServer "127.0.0.1" "10501" "CHMQ-Server-0"
        [address] -> callLaunchServer address "10501" "CHMQ-Server-0"
        [address,port] -> callLaunchServer address port "CHMQ-Server-0"
        [address,port,name] -> callLaunchServer address port name
        _ -> print "Too many arguments passed. Please give arguments in the form: address port name"