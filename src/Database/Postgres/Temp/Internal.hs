{-# LANGUAGE RecordWildCards, LambdaCase, ScopedTypeVariables, DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric, OverloadedStrings #-}
module Database.Postgres.Temp.Internal where
import System.IO.Temp
import System.Process
import System.Process.Internals
import Control.Concurrent
import System.IO
import System.Exit
import System.Directory
import qualified Network.Socket as N
import Control.Exception
import Data.Typeable
import GHC.Generics
import System.Posix.Signals
import qualified Database.PostgreSQL.Simple as PG
import qualified Data.ByteString.Char8 as BSC
import Control.Monad (void, forever)
import Network.Socket.Free (openFreePort)
import Data.Foldable
import Control.Concurrent.Async(race_)
import Data.IORef

getFreePort :: IO Int
getFreePort = do
  (port, socket) <- openFreePort
  N.close socket
  pure port

waitForDB :: String -> IO ()
waitForDB connStr = do
  eresult <- try $ bracket (PG.connectPostgreSQL (BSC.pack connStr)) PG.close $ \_ -> return ()
  case eresult of
    Left (_ :: IOError) -> threadDelay 10000 >> waitForDB connStr
    Right _ -> return ()

-- A helper for dealing with locks
withLock :: MVar a -> IO b -> IO b
withLock m f = withMVar m (const f)

data DB = DB
  { mainDir :: FilePath
  -- ^ Temporary directory where the unix socket, logs and data directory live.
  , connectionString :: String
  -- ^ PostgreSQL connection string.
  , extraOptions :: [(String, String)]
  -- ^ Additionally options passed to the postgres command line
  , stdErr :: Handle
  -- ^ The 'Handle' used to standard error
  , stdOut :: Handle
  -- ^ The 'Handle' used to standard output
  , pidLock :: MVar ()
  -- ^ A lock used internally to makes sure access to 'pid' is serialized
  , port :: Int
  -- ^ The port postgres is listening on
  , socketClass :: SocketClass
  -- ^ The 'SocketClass' used for starting postgres
  , pid :: IORef (Maybe ProcessHandle)
  -- ^ The process handle for the @postgres@ process.
  }

data SocketClass = Localhost | Unix
  deriving (Show, Eq, Read, Ord, Enum, Bounded, Generic, Typeable)

-- | start postgres and use the current processes stdout and stderr
start :: [(String, String)]
      -- ^ Extra options which override the defaults
      -> IO (Either StartError DB)
start options = startWithHandles Unix options stdout stderr

-- | start postgres and use the current processes stdout and stderr
-- but use TCP on localhost instead of a unix socket.
startLocalhost ::  [(String, String)]
               -- ^ Extra options which override the defaults
               -> IO (Either StartError DB)
startLocalhost options = startWithHandles Localhost options stdout stderr

fourth :: (a, b, c, d) -> d
fourth (_, _, _, x) = x

procWith :: Handle -> Handle -> String -> [String] -> CreateProcess
procWith stdOut stdErr cmd args =
  (proc cmd args)
    { std_err = UseHandle stdErr
    , std_out = UseHandle stdOut
    }

config :: Maybe FilePath -> String
config mMainDir = unlines $
  [ "shared_buffers = 12MB"
  , "fsync = off"
  , "synchronous_commit = off"
  , "full_page_writes = off"
  , "log_min_duration_statement = 0"
  , "log_connections = on"
  , "log_disconnections = on"
  , "client_min_messages = ERROR"
  ] ++ maybe ["listen_addresses = '127.0.0.1'"] (\x -> ["unix_socket_directories = '" ++ x ++ "'", "listen_addresses = ''"]) mMainDir

data StartError
  = InitDBFailed   ExitCode
  | CreateDBFailed [String] ExitCode
  | StartPostgresFailed [String] ExitCode
  | StartPostgresDisappeared [String]
  deriving (Show, Eq, Typeable)

instance Exception StartError

throwIfError :: (ExitCode -> StartError) -> ExitCode -> IO ()
throwIfError f e = case e of
  ExitSuccess -> return ()
  _       -> throwIO $ f e

pidString :: ProcessHandle -> IO String
pidString phandle = withProcessHandle phandle (\case
        OpenHandle p   -> return $ show p
        OpenExtHandle _ _ _ -> return "" -- TODO log windows is not supported
        ClosedHandle _ -> return ""
        )

runProcessWith :: Handle -> Handle -> String -> String -> [String] -> IO ExitCode
runProcessWith stdOut stdErr name cmd args
  =   createProcess_ name (procWith stdOut stdErr cmd args)
  >>= waitForProcess . fourth

-- | Start postgres and pass in handles for stdout and stderr
startWithHandles :: SocketClass
                 -> [(String, String)]
                 -- ^ Extra options which override the defaults
                 -> Handle
                 -- ^ @stdout@
                 -> Handle
                 -- ^ @stderr@
                 -> IO (Either StartError DB)
startWithHandles socketClass options stdOut stdErr = do
  mainDir <- createTempDirectory "/tmp" "tmp-postgres"
  startWithHandlesAndDir socketClass options mainDir stdOut stdErr

startWithHandlesAndDir :: SocketClass
                       -> [(String, String)]
                       -> FilePath
                       -> Handle
                       -> Handle
                       -> IO (Either StartError DB)
startWithHandlesAndDir = startWithLogger $ \_ -> return ()

-- | This error is thrown is 'startPostgres' is called twice without calling
--  'stopPostgres' first.
data AnotherPostgresProcessActive = AnotherPostgresProcessActive
  deriving (Show, Eq, Typeable)

instance Exception AnotherPostgresProcessActive

-- A helper that attempts to blocks until a connection can be made, throws
-- 'StartPostgresFailed' if the postgres process fails or throws
-- 'StartPostgresDisappeared' if the 'pid' somehow becomes 'Nothinng'.
waitOnPostgres :: DB -> IO ()
waitOnPostgres DB {..} = do
  let postgresOptions = makePostgresOptions extraOptions (mainDir ++ "/data") port
      checkForCrash = readIORef pid >>= \case
        Nothing -> throwIO $ StartPostgresDisappeared postgresOptions
        Just thePid -> do
          mExitCode <- getProcessExitCode thePid
          for_ mExitCode (throwIO . StartPostgresFailed postgresOptions)
      host = case socketClass of
            Localhost -> "127.0.0.1"
            Unix -> mainDir
      makeConnectionString dbName = "postgresql:///"
          ++ dbName ++ "?host=" ++ host ++ "&port=" ++ show port

  waitForDB (makeConnectionString "template1") `race_`
    forever (checkForCrash >> threadDelay 100000)

-- | Send the SIGHUP signal to the postgres process to start a config reload
reloadConfig :: DB -> IO ()
reloadConfig DB {..} = do
  mHandle <- readIORef pid
  for_ mHandle $ \theHandle -> do
    mPid <- getPid theHandle
    for_ mPid $ signalProcess sigHUP

-- | This throws 'AnotherPostgresProcessActive' if the postgres
--  has not been stopped using 'stopPostgres'.
--  This function attempts to the 'pidLock' before running.
--  If postgres process fails this throws 'StartPostgresFailed'.
--  If the postgres process becomes 'Nothing' while starting
--  this function throws 'StartPostgresDisappeared'.
startPostgres :: DB -> IO ()
startPostgres db@DB {..} = withLock pidLock $ do
  readIORef pid >>= \case
    Just _ -> throwIO AnotherPostgresProcessActive
    Nothing -> do
      let postgresOptions = makePostgresOptions extraOptions (mainDir ++ "/data") port
      bracketOnError
        (runPostgres stdErr stdOut postgresOptions)
        (const $ stopPostgres db)
        $ \thePid -> do
          writeIORef pid $ Just thePid
          waitOnPostgres db

-- | Stop the postgres process. This function attempts to the 'pidLock' before running.
--   'stopPostgres' will terminate all connections before shutting down postgres.
--   'stopPostgres' is useful for testing backup strategies.
stopPostgres :: DB -> IO (Maybe ExitCode)
stopPostgres db@DB {..} = withLock pidLock $ readIORef pid >>= \case
  Nothing -> pure Nothing
  Just pHandle -> do
    withProcessHandle pHandle (\case
          OpenHandle p   -> do
            -- try to terminate the connects first. If we can't terminate still
            -- keep shutting down
            terminateConnections db

            signalProcess sigINT p
          OpenExtHandle _ _ _ -> pure () -- TODO log windows is not supported
          ClosedHandle _ -> return ()
          )

    exitCode <- waitForProcess pHandle
    writeIORef pid Nothing
    pure $ Just exitCode

makePostgresOptions :: [(String, String)]
                    -> FilePath
                    -> Int
                    -> [String]
makePostgresOptions options dataDir port =
  let extraOptions = map (\(key, value) -> "--" ++ key ++ "=" ++ value) options
  in ["-D", dataDir, "-p", show port] ++ extraOptions

runPostgres :: Handle
            -> Handle
            -> [String]
            -> IO ProcessHandle
runPostgres theStdOut theStdErr postgresOptions = do
  fmap fourth $ createProcess_ "postgres" $
    procWith theStdOut theStdErr "postgres" postgresOptions

data Event
  = InitDB
  | WriteConfig
  | FreePort
  | StartPostgres
  | WaitForDB
  | CreateDB
  | Finished
  deriving (Show, Eq, Enum, Bounded, Ord)

rmDirIgnoreErrors :: FilePath -> IO ()
rmDirIgnoreErrors mainDir =
  removeDirectoryRecursive mainDir `catch` (\(_ :: IOException) -> return ())

startWithLogger :: (Event -> IO ())
                -> SocketClass
                -> [(String, String)]
                -> FilePath
                -> Handle
                -> Handle
                -> IO (Either StartError DB)
startWithLogger logger socketClass options mainDir stdOut stdErr = try $ flip onException (rmDirIgnoreErrors mainDir) $ do
  let dataDir = mainDir ++ "/data"

  logger InitDB
  initDBExitCode <- runProcessWith stdOut stdErr "initdb"
      "initdb" ["-E", "UNICODE", "-A", "trust", "--nosync", "-D", dataDir]
  throwIfError InitDBFailed initDBExitCode

  logger WriteConfig
  writeFile (dataDir ++ "/postgresql.conf") $ config $ if socketClass == Unix then Just mainDir else Nothing

  logger FreePort
  port <- getFreePort
  -- slight race here, the port might not be free anymore!
  let host = case socketClass of
        Localhost -> "127.0.0.1"
        Unix -> mainDir
  let makeConnectionString dbName = "postgresql:///"
        ++ dbName ++ "?host=" ++ host ++ "&port=" ++ show port
      connectionString = makeConnectionString "test"
  logger StartPostgres
  pidLock <- newMVar ()

  let postgresOptions = makePostgresOptions options dataDir port
      createDBResult = do
        thePid <- runPostgres stdOut stdErr postgresOptions
        pid <- newIORef $ Just thePid
        pure $ DB mainDir connectionString options stdErr stdOut pidLock port socketClass pid

  bracketOnError createDBResult stop $ \result -> do
    let checkForCrash = readIORef (pid result) >>= \case
          Nothing -> throwIO $ StartPostgresDisappeared postgresOptions
          Just thePid -> do
            mExitCode <- getProcessExitCode thePid
            for_ mExitCode (throwIO . StartPostgresFailed postgresOptions)

    logger WaitForDB
    waitForDB (makeConnectionString "template1") `race_`
      forever (checkForCrash >> threadDelay 100000)

    logger CreateDB
    let createDBHostArgs = case socketClass of
          Unix -> ["-h", mainDir]
          Localhost -> ["-h", "127.0.0.1"]

    let createDBArgs = createDBHostArgs ++ ["-p", show port, "test"]
    throwIfError (CreateDBFailed createDBArgs) =<<
      runProcessWith stdOut stdErr "createDB" "createdb" createDBArgs

    logger Finished
    return result

-- | Start postgres and log it's all stdout to {'mainDir'}\/output.txt and {'mainDir'}\/error.txt
startAndLogToTmp :: [(String, String)]
                 -- ^ Extra options which override the defaults
                 -> IO (Either StartError DB)
startAndLogToTmp options = do
  mainDir <- createTempDirectory "/tmp" "tmp-postgres"

  stdOutFile <- openFile (mainDir ++ "/" ++ "output.txt") WriteMode
  stdErrFile <- openFile (mainDir ++ "/" ++ "error.txt") WriteMode

  startWithHandlesAndDir Unix options mainDir stdOutFile stdErrFile

-- | Force all connections to the database to close. Can be useful in some testing situations.
--   Called during shutdown as well.
terminateConnections :: DB -> IO ()
terminateConnections DB {..} = do
  e <- try $ bracket (PG.connectPostgreSQL $ BSC.pack connectionString)
          PG.close
          $ \conn -> do
            void $ PG.execute_ conn "select pg_terminate_backend(pid) from pg_stat_activity where datname='test';"
  case e of
    Left (_ :: IOError) -> pure () -- expected
    Right _ -> pure () -- Surprising ... but I do not know yet if this is a failure of termination or not.

-- | Stop postgres and clean up the temporary database folder.
stop :: DB -> IO (Maybe ExitCode)
stop db@DB {..} = do
  result <- stopPostgres db
  removeDirectoryRecursive mainDir
  return result
