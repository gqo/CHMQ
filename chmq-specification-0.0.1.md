# CHMQ Specification - Version 0.0.1

_Cloud Haskell Message Queue_

The purpose of this specification is: to specify the intended functionality of the system; to specify the goals (in terms of reliability and durability) of the CHMQ system; and to enumerate the steps towards implementing said functionality while maintaining those goals.

## Intended Functionality

The intended functionality of CHMQ is to best mimic the functionality of RabbitMQ within a 5 week time frame.

## Goals

Goals are listed in order of precedence. Goals listed first are to be given higher priority and accomplished before or, at the very least, in conjunction with goals listed below them.

1. CHMQ is intended to provide a **at-least-once** guarantee for the receipt of messages sent within its system.

2. CHMQ is intended to provide **clustering** to allow for higher availability in the case of a CHMQ node failure.

These will be referred to in the future by G and then the goal number. For example, goal one will be referred to as G1.

## Implementation

The following section will dictate a progression of the implementation of the system with regards to the intended functionality and goals described above.

In addition, the networking layer assumed for said implementation has the same guarantees as TCP such that a packet is ensured to be received or retransmitted until it is.

### Terminology

**Server**: A CHMQ instance that manages queues, connections, messages, etc.

**Consumer**: A node that is pulling messages from a queue

**Producer**: A node that is sending messages to a queue

### Part One

The focus of this part is to implement the most basic CHMQ system wherein there exists a client and a server package. A server package should accept an address and port to identify itself on in configuration. The client package should be importable into any other Haskell package. With these packages, a user should be guaranteed the reliable sending and receipt of messages along a single queue.

Assuming that a CHMQ server is running at address X, a user that has imported the client package into their code should be able to use it to open a connection to the server at address X. While connecting, the user should be able to specify whether they are a producer or a consumer.

The CHMQ server will allow for one producer and one consumer to connect to the server (both using the client package).

The producer connected to the CHMQ server should be able to publish messages (via a Publish function) to the server queue while the connected consumer should be able to consume messages (via a Get function) from the server queue. Both the Publish and Get functions should send and pull messages respectively one at a time, taking the connection as a parameter.

Reliability as it pertains to G1 will be implemented via the use of acknowledgements only in this part. These acknowledgements will fall into two categories - confirmations and acknowledgements.

Replication (G2) will not be implemented within this part.

#### Confirmations - Server to Producer

A confirmation is issued from the server to the producer when a message, sent by the producer, is received on the server correctly. At this point, responsibility for the successful _delivery_ of said message is transferred from the producer to the server.

CHMQ will issue these in an semi-implicit fashion such that it will allow the user to send a message on the queue but with the possibility that sending a message may result in an error if no confirmation is received from the server. If an error is received on send, the responsibility of handling that error and re-sending the unconfirmed message lands on the user. 

#### Acknowledgements - Consumer to Server

An acknowledgement is issued from the consumer to the server when the consumer has determined that they have successfully received the message. At this point, responsibility for the successful _processing_ of said message is transferred from the server to the consumer.

CHMQ will allow the client to issue acknowledgements explicitly on a per message basis. This should be provided in the form of a function capable taking a message identifier (to be discussed next). A client should be able to acknowledge a message both positively and negatively (through respective Ack and Nack functions). A positive acknowledgement will mark the message as successfully processed by the consumer and take it out of the queue. A negative acknowledgement will mark the message as received but unsuccessfully processed by the consumer and to return said message to the back of the queue.

#### Identifying Messages

On the client side, there should be a monotonically increasing message identification value (message tag) within the connection state. Given that a consumer may pull more than one message at a time, CHMQ should be able to determine which message is being acknowledged by the consumer based on the message tag passed to the acknowledgement function. An attempt to acknowledge a non-existent message tag should result in the closure of a connection of the consumer. This should be tied to a generated unique value that the server can identify given an acknowledgement message.

### Part Two

The focus of this part will be to expand the single queue, single consumer/producer pair system of the first part, allowing users to create multiple queues on the server while maintaining the reliability of each.

Within this part, the server package will be updated to allow for the management of multiple named queues (with the names used as a queue identifier). 

A user should be able to declare any number of queues (through a DeclareQueue function that takes a connection and a string, for the name, as a parameter) from their application in an idempotent fashion. For example, a user declaring the named queue "X" should be able to redeclare the named queue "X" without fault.

The previously defined Publish and Get functions should now take a queue name as a parameter. 

Additionally, a Consume function should be added to allow for the continuous consumption of messages from a queue on the client side in a receiveWait fashion. The Consume function will not only take a queue name and connection but will also take an exclusivity flag. If Consume is called with the exclusivity flag, the server should not allow any other node to pull messages from said queue until the Consume caller node has disconnected. This should be the only limitation on the amount of nodes consuming and publishing from any queue. In other words, all queues should accept multiple producers and all queues except those with an active exclusive Consume should accept multiple consumers.

To assure fair dispatch when there exist multiple consumers on one queue, messages should be dispatched in a round robin fashion.

#### Identifying Messages

The client side identification of messages should continue to be on a per connection basis NOT a per queue basis.

### Part Three

The focus of this part will be on optional durability of queues.

A user should now, when declaring a queue, be able to pass an additional parameter specifying the durability of the queue. The declaration of a durable queue means that, upon node restart, the queue will be re-declared by the server.

Additionally, a user should be able to specify a message as persistent. A persistent message sent on a durable queue will be written to memory and, like a durable queue, should survive node restart. Persistent messages passed on non-durable queues and non-persistent messages passed on durable queues should not display this behavior.

Due to these constraints, the server must be modified to write information regarding durable queues and persistent messages to file which allows, upon recovery, for the server to read said files and recover correctly.

### Part Four

The focus of this part will be on providing mirroring of queues, and messages within those queues, amongst a cluster of nodes. This will satisfy G2.

A user running the server package should be able to optionally provide a config file as a command line argument listing the following:

* Node Name - Formatted as "Name"
* Node Neighbor 1 - Formatted as Address:Port
* Node Neighbor 2 - Formatted as Address:Port

The inclusion of this file will be used as a flag to determine if the server is running in a cluster or not. The cluster size will be locked at 3. A cluster will be split into master and two mirrors. The master will be determined by the oldest node - defined as the node with the most uptime. A server node should be expected to record the time it comes online such that this can be determined.

A user should now, when declaring a queue, be able to pass an additional parameter specifying the availability of the queue. The declaration of a queue as highly available should be mirrored across the server cluster. The master will hold the master queue which the user should transparently be able to access (Publish, Get, and Consume) no matter the node address it has connected to (hereby referred to as the connected node). The master queue, and all messages within it, should be mirrored onto the mirror nodes.

If a mirrored node fails, no special action should be taken by the system. If a master node fails, the new oldest node will be promoted to master. The new master will assume that all unacknowledged messages have not been received and immediately requeue them. 

A consuming process on a highly available queue should be notified when the queue fails over to another node such that that process can begin consumption again if it so chooses. 

A producer process that is publishing to a highly available queue should behave transparently as a normal queue with the messages sent being replicated automatically, including confirmations being sent after a fail over.

Queues not declared as highly available should be declared on the connected node and non-replicated. If a connected node fails, that queue should be lost (unless declared durable and recovered on restart of said node). 