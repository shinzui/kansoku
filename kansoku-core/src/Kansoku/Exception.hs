-- | Catch application faults without swallowing thread cancellation.
module Kansoku.Exception (catchSynchronous, trySynchronous) where

import Control.Exception (SomeAsyncException, SomeException, catch, fromException, throwIO)

catchSynchronous :: IO a -> (SomeException -> IO a) -> IO a
catchSynchronous action handle =
  action `catch` \err ->
    case fromException err :: Maybe SomeAsyncException of
      Just _ -> throwIO err
      Nothing -> handle err

trySynchronous :: IO a -> IO (Either SomeException a)
trySynchronous action = catchSynchronous (Right <$> action) (pure . Left)
