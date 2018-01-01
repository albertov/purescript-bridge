{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE KindSignatures    #-}
{-# LANGUAGE OverloadedStrings #-}

module Language.PureScript.Bridge.Printer where

import           Control.Lens
import           Control.Monad
import           Data.Map.Strict                     (Map)
import qualified Data.Map.Strict                     as Map
import           Data.Monoid
import           Data.Set                            (Set)
import qualified Data.Set                            as Set
import           Data.Text                           (Text)
import qualified Data.Text                           as T
import qualified Data.Text.IO                        as T
import           System.Directory
import           System.FilePath


import           Language.PureScript.Bridge.SumType
import           Language.PureScript.Bridge.TypeInfo


data Module (lang :: Language) = PSModule {
  psModuleName  :: !Text
, psImportLines :: !(Map Text ImportLine)
, psTypes       :: ![SumType lang]
} deriving Show

type PSModule = Module 'PureScript

data ImportLine = ImportLine {
  importModule :: !Text
, importTypes  :: !(Set Text)
} deriving Show

type Modules = Map Text PSModule
type ImportLines = Map Text ImportLine

printModule :: FilePath -> PSModule -> IO ()
printModule root m = do
  unlessM (doesDirectoryExist mDir) $ createDirectoryIfMissing True mDir
  T.writeFile mPath . moduleToText $ m
  where
    mFile = (joinPath . map T.unpack . T.splitOn "." $ psModuleName m) <> ".purs"
    mPath = root </> mFile
    mDir = takeDirectory mPath

sumTypesToNeededPackages :: [SumType lang] -> Set Text
sumTypesToNeededPackages = Set.unions . map sumTypeToNeededPackages

sumTypeToNeededPackages :: SumType lang -> Set Text
sumTypeToNeededPackages st =
  Set.filter (not . T.null) . Set.map _typePackage $ getUsedTypes st

moduleToText :: Module 'PureScript -> Text
moduleToText m = T.unlines $
  "-- File auto generated by purescript-bridge! --"
  : "module " <> psModuleName m <> " where\n"
  : map importLineToText allImports
  ++ [ ""
     , "import Prelude"
     , "import Data.Generic.Rep (class Generic)"
     , "import Data.Foreign.Class (class Decode, class Encode, decode, encode)"
     , "import Data.Foreign.Generic (defaultOptions, genericEncode, genericDecode)"
     , "import Data.Foreign.Generic.Types (Options, SumEncoding(..))"
     , "import Data.Foreign.Generic.Class (class GenericDecode, class GenericEncode)"
     , "import Data.Generic.Rep.Eq as GEq"
     , "import Data.Generic.Rep.Show as GShow"
     , ""
     , "jOpts = defaultOptions { sumEncoding = ObjectWithSingleField, unwrapSingleConstructors = true}"
     ]
  ++ map sumTypeToText (psTypes m)
  where
    otherImports = importsFromList _lensImports
    allImports = Map.elems $ mergeImportLines otherImports (psImportLines m)

_lensImports :: [ImportLine]
_lensImports = [
    ImportLine "Data.Maybe" $ Set.fromList ["Maybe(..)"]
  , ImportLine "Data.Lens" $ Set.fromList ["Iso'", "Prism'", "Lens'", "prism'", "lens"]
  , ImportLine "Data.Lens.Record" $ Set.fromList ["prop"]
  , ImportLine "Data.Lens.Iso.Newtype" $ Set.fromList ["_Newtype"]
  , ImportLine "Data.Symbol" $ Set.fromList ["SProxy(SProxy)"]
  , ImportLine "Data.Newtype" $ Set.fromList ["class Newtype"]
  ]

importLineToText :: ImportLine -> Text
importLineToText l = "import " <> importModule l <> " (" <> typeList <> ")"
  where
    typeList = T.intercalate ", " (Set.toList (importTypes l))

sumTypeToText :: SumType 'PureScript -> Text
sumTypeToText st =
  sumTypeToTypeDecls st
    <> "\n"
    <> sep
    <> "\n"
    <> sumTypeToOptics st
    <> sep
  where
    sep = T.replicate 80 "-"

sumTypeToTypeDecls :: SumType 'PureScript -> Text
sumTypeToTypeDecls st@(SumType t cs) = T.unlines $
    dataOrNewtype <> " " <> typeInfoToText True t <> " ="
  : "    " <> T.intercalate "\n  | " (map (constructorToText 4) cs) <> "\n"
  : "derive instance generic" <> _typeName t <> " :: " <> genericInstance t <> " _\n"
  : "instance encode" <> _typeName t <> " :: " <> constraints encodeInstance <> encodeInstance t <> " where encode = genericEncode jOpts\n"
  : "instance decode" <> _typeName t <> " :: " <> constraints decodeInstance <> decodeInstance t <> " where decode = genericDecode jOpts\n"
  : "instance show" <> _typeName t <> " :: " <> constraints showInstance <> showInstance t <> " where show = GShow.genericShow\n"
  : "instance eq" <> _typeName t <> " :: " <> constraints eqInstance <> eqInstance t <> " where eq = GEq.genericEq\n"
  : [ "derive instance newtype" <> _typeName t <> " :: " <> newtypeInstance t <> " _\n" | isNewtype cs]
  where
    encodeInstance = ("Encode " <>) . typeInfoToText False
    showInstance = ("Show " <>) . typeInfoToText False
    eqInstance = ("Eq " <>) . typeInfoToText False
    decodeInstance = ("Decode " <>) . typeInfoToText False
    genericInstance = ("Generic " <>) . typeInfoToText False
    newtypeInstance = ("Newtype " <>) . typeInfoToText False
    constraints inst
      | stpLength == 0 = mempty
      | otherwise = (<> " => ") $
          if stpLength == 1
            then encodeConstraintsInner
            else bracketWrap encodeConstraintsInner
      where encodeConstraintsInner = T.intercalate ", " $ map inst sumTypeParameters
    stpLength = length sumTypeParameters
    bracketWrap x = "(" <> x <> ")"
    sumTypeParameters = filter isTypeParam . Set.toList $ getUsedTypes st
    isTypeParam typ = _typeName typ `elem` map _typeName (_typeParameters t)
    isNewtype [constr]
      | either isSingletonList (const True) (_sigValues constr) = True
    isNewtype _   = False
    dataOrNewtype = if isNewtype cs then "newtype" else "data"
    isSingletonList [_] = True
    isSingletonList _   = False

sumTypeToOptics :: SumType 'PureScript -> Text
sumTypeToOptics st = constructorOptics st <> recordOptics st

constructorOptics :: SumType 'PureScript -> Text
constructorOptics st =
  case st ^. sumTypeConstructors of
    []  -> mempty -- No work required.
    [c] -> constructorToOptic False typeInfo c
    cs  -> T.unlines $ map (constructorToOptic True typeInfo) cs
  where
    typeInfo = st ^. sumTypeInfo


recordOptics :: SumType 'PureScript -> Text
-- Match on SumTypes with a single DataConstructor (that's a list of a single element)
recordOptics st@(SumType _ [_]) = T.unlines $ recordEntryToLens st <$> dcRecords
  where
    cs = st ^. sumTypeConstructors
    dcRecords = lensableConstructor ^.. traversed.sigValues._Right.traverse.filtered hasUnderscore
    hasUnderscore e = e ^. recLabel.to (T.isPrefixOf "_")
    lensableConstructor = filter singleRecordCons cs ^? _head
    singleRecordCons (DataConstructor _ (Right _)) = True
    singleRecordCons _                             = False
recordOptics _ = ""

constructorToText :: Int -> DataConstructor 'PureScript -> Text
constructorToText _ (DataConstructor n (Left []))  = n
constructorToText _ (DataConstructor n (Left ts))  = n <> " " <> T.intercalate " " (map (typeInfoToText False) ts)
constructorToText indentation (DataConstructor n (Right rs)) =
       n <> " {\n"
    <> spaces (indentation + 2) <> T.intercalate intercalation (map recordEntryToText rs) <> "\n"
    <> spaces indentation <> "}"
  where
    intercalation = "\n" <> spaces indentation <> "," <> " "

spaces :: Int -> Text
spaces c = T.replicate c " "


typeNameAndForall :: TypeInfo 'PureScript -> (Text, Text)
typeNameAndForall typeInfo = (typName, forAll)
  where
    typName = typeInfoToText False typeInfo
    forAllParams = typeInfo ^.. typeParameters.traversed.to (typeInfoToText False)
    forAll = case forAllParams of
      [] -> " :: "
      cs -> " :: forall " <> T.intercalate " " cs <> ". "

fromEntries :: (RecordEntry a -> Text) -> [RecordEntry a] -> Text
fromEntries mkElem rs = "{ " <> inners <> " }"
  where
    inners = T.intercalate ", " $ map mkElem rs

mkFnArgs :: [RecordEntry 'PureScript] -> Text
mkFnArgs [r] = r ^. recLabel
mkFnArgs rs  = fromEntries (\recE -> recE ^. recLabel <> ": " <> recE ^. recLabel) rs

mkTypeSig :: [RecordEntry 'PureScript] -> Text
mkTypeSig []  = "Unit"
mkTypeSig [r] = typeInfoToText False $ r ^. recValue
mkTypeSig rs  = fromEntries recordEntryToText rs

constructorToOptic :: Bool -> TypeInfo 'PureScript -> DataConstructor 'PureScript -> Text
constructorToOptic otherConstructors typeInfo (DataConstructor n args) =
  case (args,otherConstructors) of
    (Left [c], False) ->
        pName <> forAll <>  "Iso' " <> typName <> " " <> mkTypeSig (constructorTypes [c]) <> "\n"
              <> pName <> " = _Newtype"
              <> "\n"
    (Left cs, _) ->
        pName <> forAll <>  "Prism' " <> typName <> " " <> mkTypeSig types <> "\n"
              <> pName <> " = prism' " <> getter <> " f\n"
              <> spaces 2 <> "where\n"
              <> spaces 4 <> "f " <> mkF cs
              <> otherConstructorFallThrough
              <> "\n"
      where
        mkF [] = n <> " = Just unit\n"
        mkF _  = "(" <> n <> " " <> T.unwords (map _recLabel types) <> ") = Just $ " <> mkFnArgs types <> "\n"
        getter | null cs = "(\\_ -> " <> n <> ")"
               | length cs == 1   = n
               | otherwise = "(\\{ " <> T.intercalate ", " cArgs <> " } -> " <> n <> " " <> T.intercalate " " cArgs <> ")"
          where
            cArgs = map (T.singleton . fst) $ zip ['a'..] cs
        types = constructorTypes cs
    (Right rs, False) ->
        pName <> forAll <> "Iso' " <> typName <> " { " <> recordSig rs <> "}\n"
              <> pName <> " = _Newtype\n"
              <> "\n"
    (Right rs, True) ->
        pName <> forAll <> "Prism' " <> typName <> " { " <> recordSig rs <> " }\n"
              <> pName <> " = prism' " <> n <> " f\n"
              <> spaces 2 <> "where\n"
              <> spaces 4 <> "f (" <> n <> " r) = Just r\n"
              <> otherConstructorFallThrough
              <> "\n"
  where
    recordSig rs = T.intercalate ", " (map recordEntryToText rs)
    constructorTypes cs = [RecordEntry (T.singleton label) t | (label, t) <- zip ['a'..] cs]
    (typName, forAll) = typeNameAndForall typeInfo
    pName = "_" <> n
    otherConstructorFallThrough | otherConstructors = spaces 4 <> "f _ = Nothing"
                                | otherwise = ""

recordEntryToLens :: SumType 'PureScript -> RecordEntry 'PureScript -> Text
recordEntryToLens st e =
  if hasUnderscore
  then lensName <> forAll <>  "Lens' " <> typName <> " " <> recType <> "\n"
      <> lensName <> " = _Newtype <<< prop (SProxy :: SProxy \"" <> recName <> "\")\n"
  else ""
  where
    (typName, forAll) = typeNameAndForall (st ^. sumTypeInfo)
    recName = e ^. recLabel
    lensName = T.drop 1 recName
    recType = typeInfoToText False (e ^. recValue)
    hasUnderscore = e ^. recLabel.to (T.isPrefixOf "_")

recordEntryToText :: RecordEntry 'PureScript -> Text
recordEntryToText e = _recLabel e <> " :: " <> typeInfoToText True (e ^. recValue)


typeInfoToText :: Bool -> PSType -> Text
typeInfoToText topLevel t = if needParens then "(" <> inner <> ")" else inner
  where
    inner = _typeName t <>
      if pLength > 0
        then " " <> T.intercalate " " textParameters
        else ""
    params = _typeParameters t
    pLength = length params
    needParens = not topLevel && pLength > 0
    textParameters = map (typeInfoToText False) params

sumTypesToModules :: Modules -> [SumType 'PureScript] -> Modules
sumTypesToModules = foldr sumTypeToModule

sumTypeToModule :: SumType 'PureScript -> Modules -> Modules
sumTypeToModule st@(SumType t _) = Map.alter (Just . updateModule) (_typeModule t)
  where
    updateModule Nothing = PSModule {
          psModuleName = _typeModule t
        , psImportLines = dropSelf $ typesToImportLines Map.empty (getUsedTypes st)
        , psTypes = [st]
        }
    updateModule (Just m) = m {
        psImportLines = dropSelf $ typesToImportLines (psImportLines m) (getUsedTypes st)
      , psTypes = st : psTypes m
      }
    dropSelf = Map.delete (_typeModule t)

typesToImportLines :: ImportLines -> Set PSType -> ImportLines
typesToImportLines = foldr typeToImportLines

typeToImportLines :: PSType -> ImportLines -> ImportLines
typeToImportLines t ls = typesToImportLines (update ls) (Set.fromList (_typeParameters t))
  where
    update = if not (T.null (_typeModule t))
                then Map.alter (Just . updateLine) (_typeModule t)
                else id

    updateLine Nothing = ImportLine (_typeModule t) (Set.singleton (_typeName t))
    updateLine (Just (ImportLine m types)) = ImportLine m $ Set.insert (_typeName t) types

importsFromList :: [ImportLine] -> Map Text ImportLine
importsFromList ls = let
    pairs = zip (map importModule ls) ls
    merge a b = ImportLine (importModule a) (importTypes a `Set.union` importTypes b)
  in
    Map.fromListWith merge pairs

mergeImportLines :: ImportLines -> ImportLines -> ImportLines
mergeImportLines = Map.unionWith mergeLines
  where
    mergeLines a b = ImportLine (importModule a) (importTypes a `Set.union` importTypes b)

unlessM :: Monad m => m Bool -> m () -> m ()
unlessM mbool action = mbool >>= flip unless action
