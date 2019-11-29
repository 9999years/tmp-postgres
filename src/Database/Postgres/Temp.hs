{-|
This module provides functions for creating a temporary @postgres@ instance.
By default it will create a temporary data directory and
a temporary directory for a UNIX domain socket for @postgres@ to listen on in addition to
listening on @127.0.0.1@ and @::1@.

Here is an example using the expection safe 'with' function:

 @
 'with' $ \\db -> 'Control.Exception.bracket'
    ('PG.connectPostgreSQL' ('toConnectionString' db))
    'PG.close' $
    \\conn -> 'PG.execute_' conn "CREATE TABLE foo (id int)"
 @

To extend or override the defaults use `withConfig` (or `startConfig`).

@tmp-postgres@ ultimately calls (optionally) @initdb@, @postgres@ and
(optionally) @createdb@.

All of the command line, environment variables and configuration files
that are generated by default for the respective executables can be
extended.

In general @tmp-postgres@ is useful if you want a clean temporary
@postgres@ and do not want to worry about clashing with an existing
postgres instance (or needing to ensure @postgres@ is already running).

Here are some different use cases for @tmp-postgres@ and their respective
configurations:

* The default 'with' and 'start' functions can be used to make a sandboxed
temporary database for testing.
* By disabling @initdb@ one could run a temporary
isolated postgres on a base backup to test a migration.
* By using the 'stopPostgres' and 'withRestart' functions one can test
backup strategies.

WARNING!!
Ubuntu's PostgreSQL installation does not put @initdb@ on the @PATH@. We need to add it manually.
The necessary binaries are in the @\/usr\/lib\/postgresql\/VERSION\/bin\/@ directory, and should be added to the @PATH@

 > echo "export PATH=$PATH:/usr/lib/postgresql/VERSION/bin/" >> /home/ubuntu/.bashrc

-}

module Database.Postgres.Temp
  (
  -- * Start and Stop @postgres@
  -- ** Exception safe interface
    with
  , withConfig
  , withRestart
  -- *** Configuration
  -- *** Defaults
  , defaultConfig
  , defaultConfig_9_3_10
  , defaultPostgresConf
  , verboseConfig
  -- *** Custom Config builder helpers
  , optionsToDefaultConfig
  -- ** Main resource handle
  , DB
  -- *** 'DB' accessors
  , toConnectionString
  , toConnectionOptions
  , toDataDirectory
  , toTemporaryDirectory
  , toPostgresqlConf
  -- *** 'DB' modifiers
  , makeDataDirPermanent
  , reloadConfig
  -- *** 'DB' debugging
  , prettyPrintDB
  -- ** Separate start and stop interface.
  , start
  , startConfig
  , stop
  , restart
  , stopPostgres
  , stopPostgresGracefully
  -- * Making Starting Faster
  -- $makingItFaster
  -- ** @initdb@ Data Directory Caching
  -- *** Exception safe interface
  , withDbCache
  , withDbCacheConfig
  -- *** @initdb@ cache configuration.
  , CacheConfig (..)
  , defaultCacheConfig
  -- *** @initdb@ cache handle.
  , CacheResources
  , cacheResourcesToConfig
  -- *** Separate start and stop interface.
  , setupInitDbCache
  , cleanupInitDbCache
  -- ** Data Directory Snapshots
  -- *** Exception safe interface
  , withSnapshot
  -- *** 'Snapshot' handle
  , Snapshot
  , snapshotConfig
  -- *** Separate start and stop interface.
  , takeSnapshot
  , cleanupSnapshot
  -- * Errors
  , StartError (..)
  -- * Configuration Types
  -- ** 'Config'
  , Config (..)
  , prettyPrintConfig
  -- ** 'ProcessConfig'
  , ProcessConfig (..)
  -- ** 'EnvironmentVariables'
  , EnvironmentVariables (..)
  -- ** 'CommandLineArgs'
  , CommandLineArgs (..)
  -- ** 'DirectoryType'
  , DirectoryType (..)
  -- ** 'CompleteDirectoryType'
  , CompleteDirectoryType (..)
  -- ** 'Accum'
  , Accum (..)
  -- ** 'Logger'
  , Logger
  -- ** Internal events passed to the 'logger' .
  , Event (..)
  ) where
import Database.Postgres.Temp.Internal
import Database.Postgres.Temp.Internal.Core
import Database.Postgres.Temp.Internal.Config

{- $makingItFaster

'with' and related functions are fast by themselves but
by utilizing various forms of caching we can make them
much faster.

The slowest part of starting a new @postgres@ cluster is the @initdb@
call which initializes the database files. However for a given @initdb@ version and configuration parameters the output
is the same.

To take advantage of this idempotent behavior we can cache the output of
@initdb@ and copy the outputted database cluster files instead of recreating
them. This leads to a 4x improvement in startup time.

See `withDbCache` and related functions for more details.

Additionally one can take snapshots of a database cluster and start
new @postgres@ instances using the snapshot as an initial database
cluster.

This is useful if one has tests that require a time consuming migration
process. By taking a snapshot after the migration we can start new
isolated clusters from the point in time after the migration but before any
test data has tainted the database.

See 'withSnapshot' for details.

-}
