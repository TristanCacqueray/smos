module Cursor.Tree.Base where

import Prelude
import Data.List
import Data.Maybe
import Control.Monad
import Cursor.Tree.Types

singletonTreeCursor :: forall a b. a -> TreeCursor a b
singletonTreeCursor v = { treeAbove: Nothing, treeCurrent: v, treeBelow: emptyCForest }

makeTreeCursor :: forall a b. (b -> a) -> CTree b -> TreeCursor a b
makeTreeCursor g (CTree cn) = { treeAbove: Nothing, treeCurrent: g cn.rootLabel, treeBelow: cn.subForest }

rebuildTreeCursor :: forall a b. (a -> b) -> TreeCursor a b -> CTree b
rebuildTreeCursor f tc = wrapAbove tc.treeAbove (CTree { rootLabel: f tc.treeCurrent, subForest: tc.treeBelow })
  where
  wrapAbove mta t = case mta of
    Nothing -> t
    Just (TreeAbove ta) ->
      wrapAbove ta.treeAboveAbove
        $ CTree
            { rootLabel: ta.treeAboveNode
            , subForest:
              openForest
                $ concat
                $ fromFoldable
                    [ reverse ta.treeAboveLefts
                    , singleton t
                    , ta.treeAboveRights
                    ]
            }

mapTreeCursor :: forall a b c d. (a -> c) -> (b -> d) -> TreeCursor a b -> TreeCursor c d
mapTreeCursor f g tc = { treeAbove: map g <$> tc.treeAbove, treeCurrent: f tc.treeCurrent, treeBelow: map g tc.treeBelow }

currentTree :: forall a b. (a -> b) -> TreeCursor a b -> CTree b
currentTree f tc = CTree { rootLabel: f tc.treeCurrent, subForest: tc.treeBelow }

makeTreeCursorWithAbove :: forall a b. (b -> a) -> CTree b -> Maybe (TreeAbove b) -> TreeCursor a b
makeTreeCursorWithAbove g (CTree cn) mta = { treeAbove: mta, treeCurrent: g cn.rootLabel, treeBelow: cn.subForest }

foldTreeCursor ::
  forall a b c.
  (List (CTree b) -> b -> List (CTree b) -> c -> c) ->
  (a -> CForest b -> c) ->
  TreeCursor a b ->
  c
foldTreeCursor wrapFunc currentFunc tc = wrapAbove tc.treeAbove $ currentFunc tc.treeCurrent tc.treeBelow
  where
  wrapAbove :: Maybe (TreeAbove b) -> c -> c
  wrapAbove Nothing = identity

  wrapAbove (Just ta) = goAbove ta

  goAbove :: TreeAbove b -> c -> c
  goAbove (TreeAbove ta) = wrapAbove ta.treeAboveAbove <<< wrapFunc (reverse ta.treeAboveLefts) ta.treeAboveNode ta.treeAboveRights
