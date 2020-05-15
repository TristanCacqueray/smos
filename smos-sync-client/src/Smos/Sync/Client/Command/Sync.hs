{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeOperators #-}

module Smos.Sync.Client.Command.Sync where

import Control.Monad
import Control.Monad.Logger
import Control.Monad.Reader
import Data.Aeson as JSON
import Data.Aeson.Encode.Pretty as JSON
import Data.ByteString (ByteString)
import qualified Data.ByteString as SB
import qualified Data.ByteString.Lazy as LB
import Data.Hashable
import Data.Map (Map)
import qualified Data.Map as M
import Data.Maybe
import qualified Data.Mergeful as Mergeful
import Data.Set (Set)
import qualified Data.Set as S
import qualified Data.Text as T
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Data.Validity.UUID ()
import Database.Persist.Sqlite as DB
import Pantry.SHA256 as SHA256
import Path
import Path.IO
import Smos.Client
import Smos.Sync.Client.Contents
import Smos.Sync.Client.ContentsMap (ContentsMap (..))
import Smos.Sync.Client.DB
import Smos.Sync.Client.Env
import Smos.Sync.Client.Meta
import Smos.Sync.Client.MetaMap (MetaMap (..))
import Smos.Sync.Client.OptParse
import Smos.Sync.Client.OptParse.Types
import System.Exit
import System.FileLock
import Text.Show.Pretty

syncSmosSyncClient :: Settings -> SyncSettings -> IO ()
syncSmosSyncClient Settings {..} SyncSettings {..} = do
  ensureDir $ parent syncSetMetadataDB
  withFileLock (fromAbsFile syncSetMetadataDB) Exclusive $ \_ ->
    runStderrLoggingT
      $ filterLogger (\_ ll -> ll >= setLogLevel)
      $ DB.withSqlitePool (T.pack $ fromAbsFile syncSetMetadataDB) 1
      $ \pool ->
        withClientEnv setServerUrl $ \cenv ->
          withLogin cenv setSessionPath setUsername setPassword $ \token -> do
            logDebugN "CLIENT START"
            let env =
                  SyncClientEnv {syncClientEnvServantClientEnv = cenv, syncClientEnvConnection = pool}
            flip runReaderT env $ do
              void $ runDB $ runMigrationSilent migrateAll
              mUUID <- liftIO $ readServerUUID syncSetUUIDFile
              serverUUID <- case mUUID of
                -- Never synced before
                Nothing -> do
                  serverUUID <- runInitialSync syncSetContentsDir syncSetIgnoreFiles token
                  liftIO $ writeServerUUID syncSetUUIDFile serverUUID
                  pure serverUUID
                -- Already synced before
                Just serverUUID -> pure serverUUID
              runSync syncSetContentsDir syncSetIgnoreFiles serverUUID token
            logDebugN "CLIENT END"

runInitialSync :: Path Abs Dir -> IgnoreFiles -> Token -> C ServerUUID
runInitialSync contentsDir ignoreFiles token = do
  logDebugN "INITIAL SYNC START"
  let clientStore = Mergeful.initialClientStore :: Mergeful.ClientStore (Path Rel File) FileUUID SyncFile
  let req = Mergeful.makeSyncRequest clientStore
  logDebugData "INITIAL SYNC REQUEST" req
  logInfoJsonData "INITIAL SYNC REQUEST (JSON)" req
  resp@SyncResponse {..} <- runSyncClientOrDie $ clientPostSync token req
  logDebugData "INITIAL SYNC RESPONSE" resp
  logInfoJsonData "INITIAL SYNC RESPONSE (JSON)" resp
  clientMergeSyncResponse contentsDir ignoreFiles syncResponseItems
  logDebugN "INITIAL SYNC END"
  pure syncResponseServerId

runSync :: Path Abs Dir -> IgnoreFiles -> ServerUUID -> Token -> C ()
runSync contentsDir ignoreFiles serverUUID token = do
  files <- liftIO $ readFilteredSyncFiles ignoreFiles contentsDir
  meta <- runDB readClientMetadata
  logDebugData "CLIENT META MAP BEFORE SYNC" meta
  let items = consolidateMetaMapWithFiles meta files
  logDebugN "SYNC START"
  let req = Mergeful.makeSyncRequest items
  logDebugData "SYNC REQUEST" req
  logInfoJsonData "SYNC REQUEST (JSON)" req
  resp@SyncResponse {..} <- runSyncClientOrDie $ clientPostSync token req
  logDebugData "SYNC RESPONSE" resp
  logInfoJsonData "SYNC RESPONSE (JSON)" resp
  liftIO
    $ unless (syncResponseServerId == serverUUID)
    $ die
    $ unlines
      [ "The server was reset since the last time it was synced with, refusing to sync.",
        "If you want to sync anyway, remove the client metadata file and sync again.",
        "Note that you can lose data by doing this, so make a backup first."
      ]
  clientMergeSyncResponse contentsDir ignoreFiles syncResponseItems
  logDebugN "SYNC END"

clientMergeSyncResponse :: Path Abs Dir -> IgnoreFiles -> Mergeful.SyncResponse (Path Rel File) FileUUID SyncFile -> C ()
clientMergeSyncResponse contentsDir ignoreFiles = runDB . Mergeful.mergeSyncResponseCustom Mergeful.mergeFromServerStrategy proc
  where
    proc :: Mergeful.ClientSyncProcessor (Path Rel File) FileUUID SyncFile (SqlPersistT IO)
    proc = Mergeful.ClientSyncProcessor {..}
      where
        clientSyncProcessorQuerySyncedButChangedValues :: Set FileUUID -> SqlPersistT IO (Map FileUUID (Mergeful.Timed SyncFile))
        clientSyncProcessorQuerySyncedButChangedValues s = fmap (M.fromList . catMaybes) $ forM (S.toList s) $ \u -> do
          mcf <- getBy (UniqueUUID u)
          case mcf of
            Nothing -> pure Nothing
            Just (Entity _ ClientFile {..}) -> do
              mContents <- liftIO $ forgivingAbsence $ SB.readFile $ fromAbsFile $ contentsDir </> clientFilePath
              case mContents of
                Nothing -> pure Nothing
                Just contents -> do
                  let sfm = SyncFileMeta {syncFileMetaUUID = u, syncFileMetaHashOld = clientFileHash, syncFileMetaHash = clientFileSha256, syncFileMetaTime = clientFileTime}
                  if isUnchanged sfm contents
                    then pure Nothing
                    else do
                      let sf = SyncFile {syncFilePath = clientFilePath, syncFileContents = contents}
                      let tsf = Mergeful.Timed sf clientFileTime
                      pure $ Just (u, tsf)
        clientSyncProcessorSyncClientAdded :: Map (Path Rel File) (Mergeful.ClientAddition FileUUID) -> SqlPersistT IO ()
        clientSyncProcessorSyncClientAdded m = forM_ (M.toList m) $ \(p, Mergeful.ClientAddition {..}) -> do
          mContents <- liftIO $ forgivingAbsence $ SB.readFile $ fromAbsFile $ contentsDir </> p
          case mContents of
            Nothing -> pure ()
            Just contents -> do
              insert_ ClientFile {clientFileUuid = clientAdditionId, clientFilePath = p, clientFileHash = Just $ hash contents, clientFileSha256 = Just $ SHA256.hashBytes contents, clientFileTime = clientAdditionServerTime}
        clientSyncProcessorSyncClientChanged :: Map FileUUID Mergeful.ServerTime -> SqlPersistT IO ()
        clientSyncProcessorSyncClientChanged m = forM_ (M.toList m) $ \(uuid, st) ->
          updateWhere [ClientFileUuid ==. uuid] [ClientFileTime =. st]
        clientSyncProcessorSyncClientDeleted :: Set FileUUID -> SqlPersistT IO ()
        clientSyncProcessorSyncClientDeleted s = forM_ (S.toList s) $ \uuid ->
          deleteBy (UniqueUUID uuid)
        clientSyncProcessorSyncMergedConflict :: Map FileUUID (Mergeful.Timed SyncFile) -> SqlPersistT IO ()
        clientSyncProcessorSyncMergedConflict m = forM_ (M.toList m) $ \(uuid, Mergeful.Timed SyncFile {..} st) -> unless (filePred syncFilePath) $ do
          let p = contentsDir </> syncFilePath
          liftIO $ do
            ensureDir $ parent p
            SB.writeFile (fromAbsFile p) syncFileContents
          -- Don't update the hashes so the item stays marked as 'changed'
          updateWhere [ClientFileUuid ==. uuid] [ClientFileTime =. st]
        clientSyncProcessorSyncServerAdded :: Map FileUUID (Mergeful.Timed SyncFile) -> SqlPersistT IO ()
        clientSyncProcessorSyncServerAdded m = forM_ (M.toList m) $ \(uuid, Mergeful.Timed SyncFile {..} st) -> unless (filePred syncFilePath) $ do
          let p = contentsDir </> syncFilePath
          liftIO $ do
            ensureDir $ parent p
            SB.writeFile (fromAbsFile p) syncFileContents
          -- Don't update the hashes so the item stays marked as 'changed'
          insert_ ClientFile {clientFileUuid = uuid, clientFilePath = syncFilePath, clientFileHash = Just $ hash syncFileContents, clientFileSha256 = Just $ SHA256.hashBytes syncFileContents, clientFileTime = st}
        clientSyncProcessorSyncServerChanged :: Map FileUUID (Mergeful.Timed SyncFile) -> SqlPersistT IO ()
        clientSyncProcessorSyncServerChanged m = forM_ (M.toList m) $ \(uuid, Mergeful.Timed SyncFile {..} st) -> unless (filePred syncFilePath) $ do
          let p = contentsDir </> syncFilePath
          liftIO $ do
            ensureDir $ parent p
            SB.writeFile (fromAbsFile p) syncFileContents
          -- Don't update the hashes so the item stays marked as 'changed'
          updateWhere [ClientFileUuid ==. uuid] [ClientFileHash =. Just (hash syncFileContents), ClientFileSha256 =. Just (SHA256.hashBytes syncFileContents), ClientFileTime =. st]
        clientSyncProcessorSyncServerDeleted :: Set FileUUID -> SqlPersistT IO ()
        clientSyncProcessorSyncServerDeleted s = forM_ (S.toList s) $ \uuid -> deleteBy (UniqueUUID uuid)
        filePred = case ignoreFiles of
          IgnoreNothing -> const True
          IgnoreHiddenFiles -> not . isHidden

logInfoJsonData :: ToJSON a => Text -> a -> C ()
logInfoJsonData name a =
  logInfoN $ T.unwords [name <> ":", TE.decodeUtf8 $ LB.toStrict $ encodePretty a]

logDebugData :: Show a => Text -> a -> C ()
logDebugData name a = logDebugN $ T.unwords [name <> ":", T.pack $ ppShow a]

readServerUUID :: Path Abs File -> IO (Maybe ServerUUID)
readServerUUID p = do
  mContents <- forgivingAbsence $ LB.readFile $ toFilePath p
  forM mContents $ \contents ->
    case JSON.eitherDecode contents of
      Left err -> die err
      Right store -> pure store

writeServerUUID :: Path Abs File -> ServerUUID -> IO ()
writeServerUUID p u = do
  ensureDir (parent p)
  LB.writeFile (fromAbsFile p) $ JSON.encodePretty u

consolidateInitialStoreWithFiles :: ClientStore -> ContentsMap -> Maybe ClientStore
consolidateInitialStoreWithFiles cs contentsMap =
  let Mergeful.ClientStore {..} = clientStoreItems cs
   in if not
        ( null clientStoreAddedItems
            && null clientStoreDeletedItems
            && null clientStoreSyncedButChangedItems
        )
        then Nothing
        else
          Just
            cs
              { clientStoreItems =
                  consolidateInitialSyncedItemsWithFiles clientStoreSyncedItems contentsMap
              }

consolidateInitialSyncedItemsWithFiles ::
  Map FileUUID (Mergeful.Timed SyncFile) -> ContentsMap -> Mergeful.ClientStore (Path Rel File) FileUUID SyncFile
consolidateInitialSyncedItemsWithFiles syncedItems =
  M.foldlWithKey go (Mergeful.initialClientStore {Mergeful.clientStoreSyncedItems = syncedItems})
    . contentsMapFiles
  where
    alreadySyncedMap = makeAlreadySyncedMap syncedItems
    go ::
      Mergeful.ClientStore (Path Rel File) FileUUID SyncFile ->
      Path Rel File ->
      ByteString ->
      Mergeful.ClientStore (Path Rel File) FileUUID SyncFile
    go s rf contents =
      let sf = SyncFile {syncFileContents = contents, syncFilePath = rf}
       in case M.lookup rf alreadySyncedMap of
            Nothing ->
              -- Not in the initial sync, that means it was added
              s {Mergeful.clientStoreAddedItems = M.insert rf sf $ Mergeful.clientStoreAddedItems s}
            Just (i, contents') ->
              if contents == contents'
                then-- We the same file locally, do nothing.
                  s
                else-- We have a different file locally, so we'll mark this as 'synced but changed'.
                  Mergeful.changeItemInClientStore i sf s

makeAlreadySyncedMap :: Map i (Mergeful.Timed SyncFile) -> Map (Path Rel File) (i, ByteString)
makeAlreadySyncedMap m = M.fromList $ map go $ M.toList m
  where
    go (i, Mergeful.Timed SyncFile {..} _) = (syncFilePath, (i, syncFileContents))

consolidateMetaMapWithFiles :: MetaMap -> ContentsMap -> Mergeful.ClientStore (Path Rel File) FileUUID SyncFile
consolidateMetaMapWithFiles clientMetaDataMap contentsMap =
  -- The existing files need to be checked for deletions and changes.
  let go1 ::
        Mergeful.ClientStore (Path Rel File) FileUUID SyncFile ->
        Path Rel File ->
        SyncFileMeta ->
        Mergeful.ClientStore (Path Rel File) FileUUID SyncFile
      go1 s rf sfm@SyncFileMeta {..} =
        case M.lookup rf $ contentsMapFiles contentsMap of
          Nothing ->
            -- The file is not there, that means that it must have been deleted.
            -- so we will mark it as such
            s
              { Mergeful.clientStoreDeletedItems =
                  M.insert syncFileMetaUUID syncFileMetaTime $ Mergeful.clientStoreDeletedItems s
              }
          Just contents ->
            -- The file is there, so we need to check if it has changed.
            if isUnchanged sfm contents
              then-- If it hasn't changed, it's still synced.

                s
                  { Mergeful.clientStoreSyncedItems =
                      M.insert
                        syncFileMetaUUID
                        ( Mergeful.Timed
                            { Mergeful.timedValue =
                                SyncFile {syncFilePath = rf, syncFileContents = contents},
                              timedTime = syncFileMetaTime
                            }
                        )
                        (Mergeful.clientStoreSyncedItems s)
                  }
              else-- If it has changed, mark it as such

                s
                  { Mergeful.clientStoreSyncedButChangedItems =
                      M.insert
                        syncFileMetaUUID
                        ( Mergeful.Timed
                            { Mergeful.timedValue =
                                SyncFile {syncFilePath = rf, syncFileContents = contents},
                              timedTime = syncFileMetaTime
                            }
                        )
                        (Mergeful.clientStoreSyncedButChangedItems s)
                  }
      syncedChangedAndDeleted =
        M.foldlWithKey go1 Mergeful.initialClientStore $ metaMapFiles clientMetaDataMap
      go2 ::
        Mergeful.ClientStore (Path Rel File) FileUUID SyncFile ->
        Path Rel File ->
        ByteString ->
        Mergeful.ClientStore (Path Rel File) FileUUID SyncFile
      go2 s rf contents =
        let sf = SyncFile {syncFilePath = rf, syncFileContents = contents}
         in s {Mergeful.clientStoreAddedItems = M.insert rf sf $ Mergeful.clientStoreAddedItems s}
   in M.foldlWithKey
        go2
        syncedChangedAndDeleted
        (contentsMapFiles contentsMap `M.difference` metaMapFiles clientMetaDataMap)

-- We will trust hashing. (TODO do we need to fix that?)
isUnchanged :: SyncFileMeta -> ByteString -> Bool
isUnchanged SyncFileMeta {..} contents =
  case (syncFileMetaHashOld, syncFileMetaHash) of
    (Nothing, Nothing) -> False -- Mark as changed, then we'll get a new hash later.
    (Just i, Nothing) -> hash contents == i
    (_, Just sha) -> SHA256.hashBytes contents == sha

-- TODO this could be probably optimised using the sync response
saveClientStore :: IgnoreFiles -> Path Abs Dir -> ClientStore -> C ()
saveClientStore igf dir store =
  case makeClientMetaData igf store of
    Nothing -> liftIO $ die "Something went wrong while building the metadata store"
    Just mm -> do
      runDB $ writeClientMetadata mm
      liftIO $ saveSyncFiles igf dir $ clientStoreItems store

saveSyncFiles :: IgnoreFiles -> Path Abs Dir -> Mergeful.ClientStore (Path Rel File) FileUUID SyncFile -> IO ()
saveSyncFiles igf dir store = saveContentsMap igf dir $ makeContentsMap store
