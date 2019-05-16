module Queue where

import qualified Data.Sequence as Seq

type Queue = Seq.Seq

-- Append an element to the right side of the queue
push :: a -> Queue a -> Queue a
push elem queue =
    queue Seq.|> elem

-- Pop an element from the left side of the queue
pop :: Queue a -> (Queue a, Maybe a)
pop queue =
    case Seq.null queue of
        True ->
            (queue, Nothing)
        False ->
            (queue', Just elem)
            where
                elem = Seq.index queue 0
                queue' = Seq.drop 1 queue

-- Pop an element from the left side of the queue with no regards to safety
unsafePop :: Queue a -> (Queue a, a)
unsafePop queue
    | isEmpty queue = error "unsafePop call on empty queue"
    | otherwise = 
        (queue', elem)
        where
            elem = Seq.index queue 0
            queue' = Seq.drop 1 queue

isEmpty :: Queue a -> Bool
isEmpty = Seq.null

isElem :: (Eq a) => a -> Queue a -> Bool
isElem = elem

emptyQueue :: Queue a
emptyQueue = Seq.empty

removeQueueElem :: (Eq a) => a -> Queue a -> Queue a
removeQueueElem elem queue = Seq.filter ((==) elem) queue