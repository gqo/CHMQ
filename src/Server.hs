module Server where

import Control.Distributed.Process
import qualified Data.Map as Map

import ServerTypes
import ServerHandlers

-- runServer acts as the main "loop" of the server with receiveWait blocking 
-- until a message is received
runServer :: ServerState -> Process ()
runServer state = do
    state' <- receiveWait [
          match $ clientConnHandler state
        , match $ publishHandler state
        , match $ getHandler state
        , match $ ackHandler state
        , match $ nackHandler state
        , match $ disconnectHandler state
        , match $ queueDeclareHandler state
        , match $ consumeHandler state
        ]
    runServer state'

-- launchServer initializes the server with the address and name passed to it
launchServer :: ServerName -> Process ()
launchServer name = do
    say $ "Launcing CHMQ server with name: " ++ name
    -- get the server's ProcessId
    selfProcId <- getSelfPid
    -- get the server's NodeId
    selfNodeId <- getSelfNode
    say $ "NodeId: " ++ show selfNodeId
    -- register the server on a remotely accessible table
    registerRemoteAsync selfNodeId name selfProcId
    -- run the server
    runServer $ ServerState name Map.empty Map.empty Map.empty 0