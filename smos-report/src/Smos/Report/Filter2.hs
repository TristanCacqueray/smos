{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}

module Smos.Report.Filter2 where

import GHC.Generics (Generic)

import Data.Aeson
import Data.Char as Char
import Data.Function
import Data.List
import Data.List.NonEmpty (NonEmpty(..))
import qualified Data.Map as M
import Data.Map (Map)
import Data.Maybe
import qualified Data.Text as T
import Data.Text (Text)
import Data.Validity
import Data.Void
import Path

import Control.Monad

import Lens.Micro

import Text.Megaparsec
import Text.Megaparsec.Char
import Text.Megaparsec.Char.Lexer

import Cursor.Simple.Forest
import Cursor.Simple.Tree

import Smos.Data

import Smos.Report.Path
import Smos.Report.Streaming
import Smos.Report.Time

data SmosFileAtPath =
  SmosFileAtPath
    { smosFilePath :: RootedPath
    , smosFileFile :: SmosFile
    }
  deriving (Show, Eq, Generic)

data Filter a where
  FilterFile :: Path Rel File -> Filter RootedPath
  -- Parsing filters
  FilterPropertyTime :: Filter (Maybe Time) -> Filter Text
  -- Text mapping filters
  FilterHeaderText :: Filter Text -> Filter Header
  FilterPropertyValueText :: Filter Text -> Filter PropertyValue
  FilterTagText :: Filter Text -> Filter Tag
  -- Entry mapping filters
  FilterEntryHeader :: Filter Header -> Filter Entry
  FilterEntryContents :: Filter (Maybe Contents) -> Filter Entry
  FilterEntryTimestamps :: Filter (Map TimestampName Timestamp) -> Filter Entry
  FilterEntryProperties :: Filter (Map PropertyName PropertyValue) -> Filter Entry
  FilterEntryTags :: Filter [Tag] -> Filter Entry
  -- Cursor-related filters
  FilterWithinCursor :: Filter a -> Filter (ForestCursor a)
  FilterParent :: Filter (ForestCursor a) -> Filter (ForestCursor a)
  FilterAncestor :: Filter (ForestCursor a) -> Filter (ForestCursor a)
  FilterChild :: Filter (ForestCursor a) -> Filter (ForestCursor a)
  FilterLegacy :: Filter (ForestCursor a) -> Filter (ForestCursor a)
  -- List filters
  FilterListHas :: (Show a, Eq a) => a -> Filter [a]
  -- Map filters
  FilterMapHas :: (Show k, Ord k) => k -> Filter (Map k v)
  FilterMapVal :: (Show k, Ord k) => k -> Filter (Maybe v) -> Filter (Map k v)
  -- Tuple filters
  FilterFst :: Filter a -> Filter (a, b)
  FilterSnd :: Filter b -> Filter (a, b)
  -- Maybe filters
  FilterMaybeTrue :: Filter a -> Filter (Maybe a)
  FilterMaybeFalse :: Filter a -> Filter (Maybe a)
  -- Comparison filters
  FilterSubtext :: Text -> Filter Text
  FilterOrd :: (Show a, Ord a) => Ordering -> a -> Filter a
  FilterEq :: (Show a, Eq a) => a -> Filter a
  -- Boolean filters
  FilterNot :: Filter a -> Filter a
  FilterAnd :: Filter a -> Filter a -> Filter a
  FilterOr :: Filter a -> Filter a -> Filter a

deriving instance Show (Filter a)

deriving instance Eq (Filter a)

filterPredicate :: Filter a -> a -> Bool
filterPredicate = go
  where
    go :: forall a. Filter a -> a -> Bool
    go f a =
      let goF f' = go f' a
          goProj :: forall b. (a -> b) -> Filter b -> Bool
          goProj func f' = go f' $ func a
       in case f of
            FilterFile rp -> fromRelFile rp `isInfixOf` fromAbsFile (resolveRootedPath a)
            -- Parsing filters
            FilterPropertyTime f' -> goProj parseTime f'
            -- Text mapping filters
            FilterHeaderText f' -> goProj headerText f'
            FilterPropertyValueText f' -> goProj propertyValueText f'
            FilterTagText f' -> goProj tagText f'
            -- Entry mapping filters
            FilterEntryHeader f' -> goProj entryHeader f'
            FilterEntryContents f' -> goProj entryContents f'
            FilterEntryTimestamps f' -> goProj entryTimestamps f'
            FilterEntryProperties f' -> goProj entryProperties f'
            FilterEntryTags f' -> goProj entryTags f'
            -- Cursor-related filters
            FilterWithinCursor f' -> go f' (forestCursorCurrent a)
            FilterAncestor f' ->
              maybe False (\fc_ -> go f' fc_ || go f fc_) (forestCursorSelectAbove a) || go f' a
            FilterLegacy f' ->
              any (\fc_ -> go f' fc_ || go f fc_) (forestCursorChildren a) || go f' a
            FilterParent f' -> maybe False (go f') (forestCursorSelectAbove a)
            FilterChild f' -> any (\fc_ -> go f' fc_) (forestCursorChildren a)
            -- List filters
            FilterListHas a' -> a' `elem` a
            -- Map filters
            FilterMapHas k -> M.member k a
            FilterMapVal k f' -> goProj (M.lookup k) f'
            -- Tuple filters
            FilterFst f' -> goProj fst f'
            FilterSnd f' -> goProj snd f'
            -- Maybe filters
            FilterMaybeTrue f' -> maybe True (go f') a
            FilterMaybeFalse f' -> maybe False (go f') a
            -- Comparison filters
            FilterSubtext t -> t `T.isInfixOf` t
            FilterOrd o a' -> compare a a' == o
            FilterEq a' -> a == a'
            -- Boolean
            FilterNot f' -> not $ goF f'
            FilterAnd f1 f2 -> goF f1 && goF f2
            FilterOr f1 f2 -> goF f1 || goF f2
-- deriving instance Generic (Filter a)
--
-- filterPredicate ::
--      Filter (RootedPath, ForestCursor Entry) -> RootedPath -> ForestCursor Entry -> Bool
-- filterPredicate f rp fce =
--   let go f' = filterPredicate f' rp fce
--    in case f of
--         FilterNot f' -> not $ filterPredicate f' rp fce
--         FilterAnd f1 f2 -> go f1 && go f2
--         FilterOr f1 f2 -> go f1 || go f2
--         FilterLeft f' ->
--           case f' of
--             FilterFile t -> fromRelFile t `isInfixOf` fromAbsFile (resolveRootedPath rp)
--
-- filterPredicate :: Filter -> RootedPath -> ForestCursor Entry -> Bool
-- filterPredicate f_ rp = go f_
--   where
--     go f fc =
--       let parent_ :: Maybe (ForestCursor Entry)
--           parent_ = fc & forestCursorSelectedTreeL treeCursorSelectAbove
--           children_ :: [ForestCursor Entry]
--           children_ =
--             mapMaybe
--               (\i -> fc & forestCursorSelectBelowAtPos i)
--               (let CNode _ cf = rebuildTreeCursor $ fc ^. forestCursorSelectedTreeL
--                 in [0 .. length (rebuildCForest cf) - 1])
--           cur :: Entry
--           cur = fc ^. forestCursorSelectedTreeL . treeCursorCurrentL
--        in case f of
--             FilterHasTag t -> t `elem` entryTags cur
--             FilterTodoState mts -> Just mts == entryState cur
--             FilterFile t -> fromRelFile t `isInfixOf` fromAbsFile (resolveRootedPath rp)
--             FilterHeader h ->
--               T.toCaseFold (headerText h) `T.isInfixOf` T.toCaseFold (headerText (entryHeader cur))
--             FilterExactProperty pn pv ->
--               case M.lookup pn $ entryProperties cur of
--                 Nothing -> False
--                 Just pv' -> pv == pv'
--             FilterHasProperty pn -> isJust $ M.lookup pn $ entryProperties cur
--             FilterLevel l -> l == level fc
--             FilterParent f' -> maybe False (go f') parent_
--             FilterAncestor f' -> maybe False (\fc_ -> go f' fc_ || go f fc_) parent_ || go f' fc
--             FilterChild f' -> any (go f') children_
--             FilterLegacy f' -> any (\fc_ -> go f' fc_ || go f fc_) children_ || go f' fc
--             FilterNot f' -> not $ go f' fc
--             FilterAnd f1 f2 -> go f1 fc && go f2 fc
--             FilterOr f1 f2 -> go f1 fc || go f2 fc
--     level :: ForestCursor a -> Word
--     level fc = go' $ fc ^. forestCursorSelectedTreeL
--       where
--         go' tc =
--           case tc ^. treeCursorAboveL of
--             Nothing -> 0
--             Just tc' -> 1 + goA' tc'
--         goA' ta =
--           case treeAboveAbove ta of
--             Nothing -> 0
--             Just ta' -> 1 + goA' ta'
-- data Filter
--   = FilterHasTag Tag
--   | FilterTodoState TodoState
--   | FilterFile (Path Rel File) -- Substring of the filename
--   | FilterLevel Word -- The level of the entry in the tree (0 is top)
--   | FilterHeader Header -- Substring of the headder
--   | FilterExactProperty PropertyName PropertyValue
--   | FilterHasProperty PropertyName
--   | FilterParent Filter -- Match direct parent
--   | FilterAncestor Filter -- Match self, parent or parent of parents recursively
--   | FilterChild Filter -- Match any direct child
--   | FilterLegacy Filter -- Match self, any direct child or their children
--   | FilterNot Filter
--   | FilterAnd Filter Filter
--   | FilterOr Filter Filter
--   deriving (Show, Eq, Ord, Generic)
--
-- instance Validity Filter where
--   validate f =
--     mconcat
--       [ genericValidate f
--       , case f of
--           FilterFile s ->
--             declare "The filenames are restricted" $ all (\c -> not (Char.isSpace c) && c /= ')') $
--             fromRelFile s
--           FilterHeader h ->
--             declare "The header characters are restricted" $
--             all (\c -> not (Char.isSpace c) && c /= ')') $
--             T.unpack $
--             headerText h
--           _ -> valid
--       ]
--
-- instance FromJSON Filter where
--   parseJSON =
--     withText "Filter" $ \t ->
--       case parseFilter t of
--         Nothing -> fail "could not parse filter."
--         Just f -> pure f
--
-- instance ToJSON Filter where
--   toJSON = toJSON . renderFilter
--
-- foldFilterAnd :: NonEmpty Filter -> Filter
-- foldFilterAnd = foldl1 FilterAnd
--
-- filterPredicate :: Filter -> RootedPath -> ForestCursor Entry -> Bool
-- filterPredicate f_ rp = go f_
--   where
--     go f fc =
--       let parent_ :: Maybe (ForestCursor Entry)
--           parent_ = fc & forestCursorSelectedTreeL treeCursorSelectAbove
--           children_ :: [ForestCursor Entry]
--           children_ =
--             mapMaybe
--               (\i -> fc & forestCursorSelectBelowAtPos i)
--               (let CNode _ cf = rebuildTreeCursor $ fc ^. forestCursorSelectedTreeL
--                 in [0 .. length (rebuildCForest cf) - 1])
--           cur :: Entry
--           cur = fc ^. forestCursorSelectedTreeL . treeCursorCurrentL
--        in case f of
--             FilterHasTag t -> t `elem` entryTags cur
--             FilterTodoState mts -> Just mts == entryState cur
--             FilterFile t -> fromRelFile t `isInfixOf` fromAbsFile (resolveRootedPath rp)
--             FilterHeader h ->
--               T.toCaseFold (headerText h) `T.isInfixOf` T.toCaseFold (headerText (entryHeader cur))
--             FilterExactProperty pn pv ->
--               case M.lookup pn $ entryProperties cur of
--                 Nothing -> False
--                 Just pv' -> pv == pv'
--             FilterHasProperty pn -> isJust $ M.lookup pn $ entryProperties cur
--             FilterLevel l -> l == level fc
--             FilterParent f' -> maybe False (go f') parent_
--             FilterAncestor f' -> maybe False (\fc_ -> go f' fc_ || go f fc_) parent_ || go f' fc
--             FilterChild f' -> any (go f') children_
--             FilterLegacy f' -> any (\fc_ -> go f' fc_ || go f fc_) children_ || go f' fc
--             FilterNot f' -> not $ go f' fc
--             FilterAnd f1 f2 -> go f1 fc && go f2 fc
--             FilterOr f1 f2 -> go f1 fc || go f2 fc
--     level :: ForestCursor a -> Word
--     level fc = go' $ fc ^. forestCursorSelectedTreeL
--       where
--         go' tc =
--           case tc ^. treeCursorAboveL of
--             Nothing -> 0
--             Just tc' -> 1 + goA' tc'
--         goA' ta =
--           case treeAboveAbove ta of
--             Nothing -> 0
--             Just ta' -> 1 + goA' ta'
--
-- type P = Parsec Void Text
--
-- parseFilter :: Text -> Maybe Filter
-- parseFilter = parseMaybe filterP
--
-- filterP :: P Filter
-- filterP =
--   try filterHasTagP <|> try filterTodoStateP <|> try filterFileP <|> try filterLevelP <|>
--   try filterHeaderP <|>
--   try filterExactPropertyP <|>
--   try filterHasPropertyP <|>
--   try filterParentP <|>
--   try filterAncestorP <|>
--   try filterChildP <|>
--   try filterLegacyP <|>
--   try filterNotP <|>
--   filterBinRelP
--
-- filterHasTagP :: P Filter
-- filterHasTagP = do
--   void $ string' "tag:"
--   s <- many (satisfy $ \c -> Char.isPrint c && not (Char.isSpace c) && not (Char.isPunctuation c))
--   either fail (pure . FilterHasTag) $ parseTag $ T.pack s
--
-- filterTodoStateP :: P Filter
-- filterTodoStateP = do
--   void $ string' "state:"
--   s <- many (satisfy $ \c -> Char.isPrint c && not (Char.isSpace c) && not (Char.isPunctuation c))
--   either fail (pure . FilterTodoState) $ parseTodoState $ T.pack s
--
-- filterFileP :: P Filter
-- filterFileP = do
--   void $ string' "file:"
--   s <- many (satisfy $ \c -> not (Char.isSpace c) && c /= ')')
--   r <- either (fail . show) (pure . FilterFile) $ parseRelFile s
--   case prettyValidate r of
--     Left err -> fail err
--     Right f -> pure f
--
-- filterLevelP :: P Filter
-- filterLevelP = do
--   void $ string' "level:"
--   FilterLevel <$> decimal
--
-- filterHeaderP :: P Filter
-- filterHeaderP = do
--   void $ string' "header:"
--   s <- many (satisfy $ \c -> Char.isPrint c && not (Char.isSpace c) && c /= ')')
--   either fail (pure . FilterHeader) $ parseHeader $ T.pack s
--
-- filterParentP :: P Filter
-- filterParentP = do
--   void $ string' "parent:"
--   FilterParent <$> filterP
--
-- filterAncestorP :: P Filter
-- filterAncestorP = do
--   void $ string' "ancestor:"
--   FilterAncestor <$> filterP
--
-- filterChildP :: P Filter
-- filterChildP = do
--   void $ string' "child:"
--   FilterChild <$> filterP
--
-- filterLegacyP :: P Filter
-- filterLegacyP = do
--   void $ string' "legacy:"
--   FilterLegacy <$> filterP
--
-- filterNotP :: P Filter
-- filterNotP = do
--   void $ string' "not:"
--   FilterNot <$> filterP
--
-- filterBinRelP :: P Filter
-- filterBinRelP = do
--   void $ char '('
--   f <- try filterOrP <|> filterAndP
--   void $ char ')'
--   pure f
--
-- filterOrP :: P Filter
-- filterOrP = do
--   f1 <- filterP
--   void $ string' " or "
--   f2 <- filterP
--   pure $ FilterOr f1 f2
--
-- filterAndP :: P Filter
-- filterAndP = do
--   f1 <- filterP
--   void $ string' " and "
--   f2 <- filterP
--   pure $ FilterAnd f1 f2
--
-- filterHasPropertyP :: P Filter
-- filterHasPropertyP = do
--   void $ string' "has-property:"
--   FilterHasProperty <$> propertyNameP
--
-- filterExactPropertyP :: P Filter
-- filterExactPropertyP = do
--   void $ string' "exact-property:"
--   pn <- propertyNameP
--   void $ string' ":"
--   pv <- propertyValueP
--   pure $ FilterExactProperty pn pv
--
-- propertyNameP :: P PropertyName
-- propertyNameP = do
--   s <- many (satisfy $ \c -> Char.isPrint c && not (Char.isSpace c) && not (Char.isPunctuation c))
--   either fail pure $ parsePropertyName $ T.pack s
--
-- propertyValueP :: P PropertyValue
-- propertyValueP = do
--   s <- many (satisfy $ \c -> Char.isPrint c && not (Char.isSpace c) && not (Char.isPunctuation c))
--   either fail pure $ parsePropertyValue $ T.pack s
--
-- renderFilter :: Filter -> Text
-- renderFilter f =
--   case f of
--     FilterHasTag t -> "tag:" <> tagText t
--     FilterTodoState ts -> "state:" <> todoStateText ts
--     FilterFile t -> "file:" <> T.pack (fromRelFile t)
--     FilterLevel l -> "level:" <> T.pack (show l)
--     FilterHeader h -> "header:" <> headerText h
--     FilterExactProperty pn pv ->
--       "exact-property:" <> propertyNameText pn <> ":" <> propertyValueText pv
--     FilterHasProperty pn -> "has-property:" <> propertyNameText pn
--     FilterParent f' -> "parent:" <> renderFilter f'
--     FilterAncestor f' -> "ancestor:" <> renderFilter f'
--     FilterChild f' -> "child:" <> renderFilter f'
--     FilterLegacy f' -> "legacy:" <> renderFilter f'
--     FilterNot f' -> "not:" <> renderFilter f'
--     FilterOr f1 f2 -> T.concat ["(", renderFilter f1, " or ", renderFilter f2, ")"]
--     FilterAnd f1 f2 -> T.concat ["(", renderFilter f1, " and ", renderFilter f2, ")"]
--
-- filterCompleter :: String -> [String]
-- filterCompleter = makeCompleterFromOptions ':' filterCompleterOptions
--
-- data CompleterOption
--   = Nullary String [String]
--   | Unary String
--   deriving (Show, Eq)
--
-- filterCompleterOptions :: [CompleterOption]
-- filterCompleterOptions =
--   [ Nullary "tag" ["out", "online", "offline", "toast", "personal", "work"]
--   , Nullary "state" ["CANCELLED", "DONE", "NEXT", "READY", "STARTED", "TODO", "WAITING"]
--   , Nullary "file" []
--   , Nullary "level" []
--   , Nullary "property" []
--   , Unary "parent"
--   , Unary "ancestor"
--   , Unary "child"
--   , Unary "legacy"
--   , Unary "not"
--   ]
--
-- makeCompleterFromOptions :: Char -> [CompleterOption] -> String -> [String]
-- makeCompleterFromOptions separator os s =
--   case separate separator (dropSeparatorAtEnd s) of
--     [] -> allOptions
--     pieces ->
--       let l = last pieces
--           prefix = intercalate [separator] pieces :: String
--           searchResults =
--             mapMaybe (\o -> (,) o <$> searchString l (renderCompletionOption o)) os :: [( CompleterOption
--                                                                                         , SearchResult)]
--        in flip concatMap searchResults $ \(o, sr) ->
--             case sr of
--               PrefixFound _ -> [renderCompletionOption o <> [separator]]
--               ExactFound ->
--                 case o of
--                   Unary _ -> map ((prefix <> [separator]) <>) allOptions
--                   Nullary _ rest -> map ((prefix <> [separator]) <>) rest
--   where
--     allOptions :: [String]
--     allOptions = map ((<> [separator]) . renderCompletionOption) os
--     dropSeparatorAtEnd :: String -> String
--     dropSeparatorAtEnd = reverse . dropWhile (== separator) . reverse
--
-- data SearchResult
--   = PrefixFound String
--   | ExactFound
--
-- searchString :: String -> String -> Maybe SearchResult
-- searchString needle haystack =
--   if needle `isPrefixOf` haystack
--     then Just $
--          if needle == haystack
--            then ExactFound
--            else PrefixFound needle
--     else Nothing
--
-- renderCompletionOption :: CompleterOption -> String
-- renderCompletionOption co =
--   case co of
--     Nullary s _ -> s
--     Unary s -> s
--
-- separate :: Char -> String -> [String]
-- separate c s =
--   case dropWhile (== c) s of
--     "" -> []
--     s' -> w : words s''
--       where (w, s'') = break (== c) s'
