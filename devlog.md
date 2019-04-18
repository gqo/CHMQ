# April 15th 2019

1. Set up project folder with stack using correct yaml files
2. Build folder and test both executable files (client and server)
3. Start thinking about messages system will need
4. Missing dependency messages (easy version): https://i.imgur.com/fttxjxA.png
   * Add these to the package.yaml file underneath dependencies
5. Separate message types version combined message type
6. Data field names can't be the same as others
7. Start writing the server - start at the state data element
8. Beginning to think that the specification is wrong in terms of the first part regarding restricted getting/publishing/consuming - should move to second part
9. Data structures regarding storage of un-acked messages might be hard. They should be stored until acknowledged in a data structure that allows the search of said messages based on a client process Id such that when a client disconnects, the data structure can be searched and all un-acked messages under that client get re-entered into the queue.
   * Maybe Map.Map ClientId Map.Map DeliveryId ByteString

# April 17th 2019

1. Think about data structure for queue, decide on list for easy (albeit non-efficient) implementation
2. Finish first run of ServerState, begin writing handlers for specific messages in receiveWait loop
   * Make sure to catch monitor reference failure soon
3. Realized clients are gonna need to be monitored and monitorRefs need to be tracked, change Clients type to Map ClientId MonitorRef
4. Whoops! Looks like the queue data structure is unwieldy, a more customer data structure would be better
5. Created Queue file with push/pop functions wrapping a Data.Sequence
6. Realized Get functions would need to sometimes return an empty queue notification, created said message
7. Change PublishId and DeliveryId to Int types as I believe a monotonically increasing int could be used for them instead of a randomized string - attempting this logic now
8. Add ProcessId fields to Ack and Nack messages such that the sender can be looked up in the clients map
9. Add UnrecognizedClientNotification message to notify unconnected senders
10. Add ConnectionClosedNotification message to notify connected clients when the server closes their connection due to erroneous behavior
11. I was going to simply allow false acks but due to the need for handling false nacks, I mirrored the behavior
12. Additionally, changed when the unackedItems list is not found for a connected client to close the connection
13. Next step: add disconnect handler (similar to close connection behavior), begin work on client package
14. Handle disconnections and write launchServer function to register server given a name