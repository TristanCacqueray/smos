{-# OPTIONS_GHC -fno-warn-orphans #-}

module Smos.Sync.Client.MetaMap.Gen where

import Data.GenValidity
import Smos.API.Gen ()
import Smos.Sync.Client.DirTree.Gen ()
import Smos.Sync.Client.MetaMap
import Smos.Sync.Client.Sync.Gen ()

instance GenValid MetaMap where
  genValid = genValidStructurally
  shrinkValid = shrinkValidStructurally
