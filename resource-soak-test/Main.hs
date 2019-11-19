module Main where

import Control.Exception
import Control.Concurrent
import Database.Postgres.Temp
import Control.Concurrent.Async
import qualified Database.PostgreSQL.Simple as PG
import System.Exit
import System.IO.Temp
import System.Process
import Control.Monad (unless, forM_, forever, void)
import System.Directory


withConn :: DB -> (PG.Connection -> IO a) -> IO a
withConn db = bracket (PG.connectPostgreSQL $ toConnectionString db ) PG.close

countPostgresProcesses :: IO Int
countPostgresProcesses = do
  -- TODO we should restrict to child process
  (exitCode, xs, _) <-  readProcessWithExitCode "pgrep" ["postgres"] []

  unless (exitCode == ExitSuccess || exitCode == ExitFailure 1) $ throwIO exitCode

  pure $ length $ lines xs

main :: IO ()
main = withTempDirectory "/tmp" "tmp-postgres-spec" $ \directoryPath ->
  forM_ [0, 10 .. 1000000] $ \theDelay -> do
    let theConfig = defaultConfig
          { temporaryDirectory = pure directoryPath
          , plan = (plan defaultConfig)
              { logger = pure print
              }
          }

    initialContents <- listDirectory directoryPath
    initialCount <- countPostgresProcesses

    thread <- async $ withConfig theConfig $ flip withConn $ \conn -> forever $ do
      (_one :: Int) <- fmap (PG.fromOnly . head) $ PG.query_ conn "SELECT 1"
      threadDelay 1000

    threadDelay theDelay
    throwTo (asyncThreadId thread) $ userError "stop already"

    void $ waitCatch thread

    finalContents <- listDirectory directoryPath
    finalCount <- countPostgresProcesses

    unless (initialCount == finalCount) $
      throwIO $ userError $ unlines
        [ "failed to clean up postgres"
        , "had"
        , show initialCount
        , "initially and now have"
        , show finalCount
        ]

    unless (initialContents == finalContents) $ do
      renameDirectory directoryPath $ directoryPath <> "_failed"
      throwIO $ userError $ unlines
        [ "failed to clean up files"
        , "had"
        , unlines initialContents
        , "initially and now have"
        , unlines finalContents
        ]
