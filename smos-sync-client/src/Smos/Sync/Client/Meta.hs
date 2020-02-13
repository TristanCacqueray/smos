{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Smos.Sync.Client.Meta where

import Data.Hashable
import qualified Data.Map as M
import Data.Maybe (fromJust)

import qualified Data.Mergeful as Mergeful
import qualified Data.Mergeful.Timed as Mergeful

import Pantry.SHA256 as SHA256

import Control.Monad.Reader

import Database.Persist.Sql as DB

import Smos.Client

import Smos.Sync.Client.Contents
import Smos.Sync.Client.DB
import Smos.Sync.Client.Env
import Smos.Sync.Client.MetaMap (MetaMap(..))
import qualified Smos.Sync.Client.MetaMap as MM
import Smos.Sync.Client.OptParse.Types

readClientMetadata :: MonadIO m => SqlPersistT m MetaMap
readClientMetadata = do
  cfs <- selectList [] []
  pure $
    fromJust $ -- Safe because of DB constraints
    MM.fromList $
    map
      (\(Entity _ ClientFile {..}) ->
         ( clientFilePath
         , SyncFileMeta
             { syncFileMetaUUID = clientFileUuid
             , syncFileMetaHashOld = clientFileHash
             , syncFileMetaHash = clientFileSha256
             , syncFileMetaTime = clientFileTime
             }))
      cfs

-- | We only check the synced items, because it should be the case that
-- they're the only ones that are not empty.
makeClientMetaData :: IgnoreFiles -> ClientStore -> Maybe MetaMap
makeClientMetaData igf ClientStore {..} =
  let Mergeful.ClientStore {..} = clientStoreItems
   in if not
           (null clientStoreAddedItems &&
            null clientStoreDeletedItems && null clientStoreSyncedButChangedItems)
        then Nothing
        else let go :: MetaMap -> FileUUID -> Mergeful.Timed SyncFile -> Maybe MetaMap
                 go m u Mergeful.Timed {..} =
                   let SyncFile {..} = timedValue
                       goOn =
                         MM.insert
                           syncFilePath
                           SyncFileMeta
                             { syncFileMetaUUID = u
                             , syncFileMetaTime = timedTime
                             , syncFileMetaHashOld = Just $ hash syncFileContents
                             , syncFileMetaHash = Just $ SHA256.hashBytes syncFileContents
                             }
                           m
                    in case igf of
                         IgnoreNothing -> goOn
                         IgnoreHiddenFiles ->
                           if isHidden syncFilePath
                             then Just m
                             else goOn
              in foldM (\m (f, t) -> go m f t) MM.empty $ M.toList clientStoreSyncedItems
