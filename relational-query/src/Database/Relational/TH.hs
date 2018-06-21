{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ExplicitForAll #-}
{-# LANGUAGE ParallelListComp #-}
{-# LANGUAGE CPP #-}

-- |
-- Module      : Database.Relational.TH
-- Copyright   : 2013-2018 Kei Hibino
-- License     : BSD3
--
-- Maintainer  : ex8k.hibino@gmail.com
-- Stability   : experimental
-- Portability : unknown
--
-- This module defines templates for Haskell record type and type class instances
-- to define column projection on SQL query like Haskell records.
-- Templates are generated by also using functions of "Database.Record.TH" module,
-- so mapping between list of untyped SQL type and Haskell record type will be done too.
module Database.Relational.TH (
  -- * All templates about table
  defineTable,

  -- * Inlining typed 'Query'
  unsafeInlineQuery,
  inlineQuery,

  -- * Column projections and basic 'Relation' for Haskell record
  defineTableTypesAndRecord,

  -- * Constraint key templates
  defineHasPrimaryKeyInstance,
  defineHasPrimaryKeyInstanceWithConfig,
  defineHasNotNullKeyInstance,
  defineHasNotNullKeyInstanceWithConfig,
  defineScalarDegree,

  -- * Column projections
  defineColumnsDefault, defineOverloadedColumnsDefault,
  defineColumns, defineOverloadedColumns,

  defineTuplePi,

  -- * Table metadata type and basic 'Relation'
  defineTableTypes, defineTableTypesWithConfig,

  -- * Basic SQL templates generate rules
  definePrimaryQuery,
  definePrimaryUpdate,

  -- * Var expression templates
  derivationExpDefault,
  tableVarExpDefault,
  relationVarExp,

  -- * Derived SQL templates from table definitions
  defineSqlsWithPrimaryKey,
  defineSqlsWithPrimaryKeyDefault,

  -- * Reify
  makeRelationalRecordDefault,
  makeRelationalRecordDefault',
  reifyRelation,
  ) where

import Data.Char (toUpper, toLower)
import Data.List (foldl1')
import Data.Array.IArray ((!))
import Data.Functor.ProductIsomorphic.TH
  (reifyRecordType, defineProductConstructor)
import Data.Functor.ProductIsomorphic.Unsafe (ProductConstructor (..))

import Language.Haskell.TH
  (Name, nameBase, Q, reify, Dec, instanceD, ExpQ, stringE, listE,
   TypeQ, Type (AppT, ConT), varT, tupleT, appT, arrowT, classP)
import Language.Haskell.TH.Compat.Reify (unVarI)
import Language.Haskell.TH.Name.CamelCase
  (VarName, varName, ConName (ConName), conName,
   varCamelcaseName, toVarExp, toTypeCon)
import Language.Haskell.TH.Lib.Extra (simpleValD, maybeD, integralE)

import Database.Record.TH
  (columnOffsetsVarNameDefault, recordTypeName, recordTemplate,
   defineRecordTypeWithConfig, defineHasColumnConstraintInstance)
import qualified Database.Record.TH as Record

import Database.Relational
  (Table, Pi, id', Relation, ShowConstantTermsSQL,
   NameConfig (..), SchemaNameMode (..), IdentifierQuotation (..), defaultConfig,
   Config (normalizedTableName, disableOverloadedProjection, disableSpecializedProjection,
           schemaNameMode, nameConfig, identifierQuotation),
   relationalQuerySQL, Query, relationalQuery, KeyUpdate,
   Insert, insert, InsertQuery, insertQuery,
   HasConstraintKey(constraintKey), Primary, NotNull, primarySelect, primaryUpdate)

import Database.Relational.InternalTH.Base (defineTuplePi, defineRecordProjections)
import Database.Relational.Scalar (defineScalarDegree)
import Database.Relational.Constraint (unsafeDefineConstraintKey)
import Database.Relational.Table (TableDerivable (..))
import qualified Database.Relational.Table as Table
import Database.Relational.Relation (derivedRelation)
import Database.Relational.SimpleSql (QuerySuffix)
import Database.Relational.Type (unsafeTypedQuery)
import qualified Database.Relational.Pi.Unsafe as UnsafePi

import qualified Database.Relational.InternalTH.Overloaded as Overloaded

-- | Rule template to infer constraint key.
defineHasConstraintKeyInstance :: TypeQ   -- ^ Constraint type
                               -> TypeQ   -- ^ Record type
                               -> TypeQ   -- ^ Key type
                               -> [Int]   -- ^ Indexes specifies key
                               -> Q [Dec] -- ^ Result 'HasConstraintKey' declaration
defineHasConstraintKeyInstance constraint recType colType indexes =
  [d| instance HasConstraintKey $constraint $recType $colType  where
        constraintKey = unsafeDefineConstraintKey $(listE [integralE ix | ix <- indexes])
    |]

-- | Rule template to infer primary key.
defineHasPrimaryKeyInstance :: TypeQ   -- ^ Record type
                            -> TypeQ   -- ^ Key type
                            -> [Int]   -- ^ Indexes specifies key
                            -> Q [Dec] -- ^ Result constraint key declarations
defineHasPrimaryKeyInstance recType colType indexes = do
  kc <- Record.defineHasPrimaryKeyInstance recType indexes
  ck <- defineHasConstraintKeyInstance [t| Primary |] recType colType indexes
  pp <- Overloaded.definePrimaryHasProjection recType colType indexes
  return $ kc ++ ck ++ pp

-- | Rule template to infer primary key.
defineHasPrimaryKeyInstanceWithConfig :: Config  -- ^ configuration parameters
                                      -> String  -- ^ Schema name
                                      -> String  -- ^ Table name
                                      -> TypeQ   -- ^ Column type
                                      -> [Int]   -- ^ Primary key index
                                      -> Q [Dec] -- ^ Declarations of primary constraint key
defineHasPrimaryKeyInstanceWithConfig config scm =
  defineHasPrimaryKeyInstance . fst . recordTemplate (recordConfig $ nameConfig config) scm

-- | Rule template to infer not-null key.
defineHasNotNullKeyInstance :: TypeQ   -- ^ Record type
                            -> Int     -- ^ Column index
                            -> Q [Dec] -- ^ Result 'ColumnConstraint' declaration
defineHasNotNullKeyInstance =
  defineHasColumnConstraintInstance [t| NotNull |]

-- | Rule template to infer not-null key.
defineHasNotNullKeyInstanceWithConfig :: Config  -- ^ configuration parameters
                                      -> String  -- ^ Schema name
                                      -> String  -- ^ Table name
                                      -> Int     -- ^ NotNull key index
                                      -> Q [Dec] -- ^ Declaration of not-null constraint key
defineHasNotNullKeyInstanceWithConfig config scm =
  defineHasNotNullKeyInstance . fst . recordTemplate (recordConfig $ nameConfig config) scm


projectionTemplate :: ConName   -- ^ Record type name
                   -> VarName   -- ^ Column declaration variable name
                   -> Int       -- ^ Column leftest index
                   -> TypeQ     -- ^ Column type
                   -> Q [Dec]   -- ^ Column projection path declaration
projectionTemplate recName var ix colType = do
  let offsetsExp = toVarExp . columnOffsetsVarNameDefault $ conName recName
  simpleValD (varName var)
    [t| Pi $(toTypeCon recName) $colType |]
    [| UnsafePi.definePi $ $offsetsExp ! $(integralE ix) |]

-- | Projection path 'Pi' templates.
defineColumns :: ConName           -- ^ Record type name
              -> [(VarName, TypeQ)] -- ^ Column info list
              -> Q [Dec]           -- ^ Column projection path declarations
defineColumns recTypeName cols = do
  let defC (name, typ) ix = projectionTemplate recTypeName name ix typ
  fmap concat . sequence $ zipWith defC cols [0 :: Int ..]

-- | Overloaded projection path 'Pi' templates.
defineOverloadedColumns :: ConName           -- ^ Record type name
                        -> [(String, TypeQ)] -- ^ Column info list
                        -> Q [Dec]           -- ^ Column projection path declarations
defineOverloadedColumns recTypeName cols = do
  let defC (name, typ) ix =
        Overloaded.monomorphicProjection recTypeName name ix typ
  fmap concat . sequence $ zipWith defC cols [0 :: Int ..]

-- | Make projection path templates using default naming rule.
defineColumnsDefault :: ConName           -- ^ Record type name
                     -> [(String, TypeQ)] -- ^ Column info list
                     -> Q [Dec]           -- ^ Column projection path declarations
defineColumnsDefault recTypeName cols =
  defineColumns     recTypeName [ (varCamelcaseName $ name ++ "'",             typ) | (name, typ) <- cols ]

-- | Make overloaded projection path templates using default naming rule.
defineOverloadedColumnsDefault :: ConName           -- ^ Record type name
                               -> [(String, TypeQ)] -- ^ Column info list
                               -> Q [Dec]           -- ^ Column projection path declarations
defineOverloadedColumnsDefault recTypeName cols =
  defineOverloadedColumns recTypeName [ (nameBase . varName $ varCamelcaseName name, typ) | (name, typ) <- cols ]

-- | Rule template to infer table derivations.
defineTableDerivableInstance :: TypeQ -> String -> [String] -> Q [Dec]
defineTableDerivableInstance recordType' table columns =
  [d| instance TableDerivable $recordType' where
        derivedTable = Table.table $(stringE table) $(listE $ map stringE columns)
    |]

-- | Template to define inferred entries from table type.
defineTableDerivations :: VarName -- ^ Table declaration variable name
                       -> VarName -- ^ Relation declaration variable name
                       -> VarName -- ^ Insert statement declaration variable name
                       -> VarName -- ^ InsertQuery statement declaration variable name
                       -> TypeQ   -- ^ Record type
                       -> Q [Dec] -- ^ Table and Relation declaration
defineTableDerivations tableVar' relVar' insVar' insQVar' recordType' = do
  let tableVar = varName tableVar'
  tableDs <- simpleValD tableVar [t| Table $recordType' |]
             [| derivedTable |]
  let relVar   = varName relVar'
  relDs   <- simpleValD relVar   [t| Relation () $recordType' |]
             [| derivedRelation |]
  let insVar   = varName insVar'
  insDs   <- simpleValD insVar   [t| Insert $recordType' |]
             [| insert id' |]
  let insQVar  = varName insQVar'
  insQDs  <- simpleValD insQVar  [t| forall p . Relation p $recordType' -> InsertQuery p |]
             [| insertQuery id' |]
  return $ concat [tableDs, relDs, insDs, insQDs]

-- | 'Table' and 'Relation' templates.
defineTableTypes :: VarName  -- ^ Table declaration variable name
                 -> VarName  -- ^ Relation declaration variable name
                 -> VarName  -- ^ Insert statement declaration variable name
                 -> VarName  -- ^ InsertQuery statement declaration variable name
                 -> TypeQ    -- ^ Record type
                 -> String   -- ^ Table name in SQL ex. FOO_SCHEMA.table0
                 -> [String] -- ^ Column names
                 -> Q [Dec]  -- ^ Table and Relation declaration
defineTableTypes tableVar' relVar' insVar' insQVar' recordType' table columns = do
  iDs <- defineTableDerivableInstance recordType' table columns
  dDs <- defineTableDerivations tableVar' relVar' insVar' insQVar' recordType'
  return $ iDs ++ dDs

tableSQL :: Bool -> SchemaNameMode -> IdentifierQuotation -> String -> String -> String
tableSQL normalize snm iq schema table = case snm of
  SchemaQualified     ->  (qt normalizeS) ++ '.' : (qt normalizeT)
  SchemaNotQualified  ->  (qt normalizeT)
  where
    normalizeS
      | normalize = map toUpper schema
      | otherwise = schema
    normalizeT
      | normalize = map toLower table
      | otherwise = table
    qt = quote iq

quote :: IdentifierQuotation -> String -> String
quote NoQuotation   s = s
quote (Quotation q) s = q : (escape s) ++ q : []
  where escape = (>>= (\c -> if c == q then [q, q] else [c]))

varNameWithPrefix :: String -> String -> VarName
varNameWithPrefix n p = varCamelcaseName $ p ++ "_" ++ n

derivationVarNameDefault :: String -> VarName
derivationVarNameDefault =  (`varNameWithPrefix` "derivationFrom")

-- | Make 'TableDerivation' variable expression template from table name using default naming rule.
derivationExpDefault :: String -- ^ Table name string
                     -> ExpQ   -- ^ Result var Exp
derivationExpDefault =  toVarExp . derivationVarNameDefault

tableVarNameDefault :: String -> VarName
tableVarNameDefault =  (`varNameWithPrefix` "tableOf")

-- | Make 'Table' variable expression template from table name using default naming rule.
tableVarExpDefault :: String -- ^ Table name string
                   -> ExpQ   -- ^ Result var Exp
tableVarExpDefault =  toVarExp . tableVarNameDefault

-- | Make 'Relation' variable expression template from table name using specified naming rule.
relationVarExp :: Config -- ^ Configuration which has  naming rules of templates
                         -> String -- ^ Schema name string
                         -> String -- ^ Table name string
                         -> ExpQ   -- ^ Result var Exp
relationVarExp config scm = toVarExp . relationVarName (nameConfig config) scm

-- | Make template for record 'ProductConstructor' instance using specified naming rule.
defineProductConstructorInstanceWithConfig :: Config -> String -> String -> [Q Type] -> Q [Dec]
defineProductConstructorInstanceWithConfig config schema table colTypes = do
  let (recType, recData) = recordTemplate (recordConfig $ nameConfig config) schema table
  [d| instance ProductConstructor $(foldr (appT . (arrowT `appT`)) recType colTypes) where
        productConstructor = $(recData)
    |]

-- | Make templates about table and column metadatas using specified naming rule.
defineTableTypesWithConfig :: Config            -- ^ Configuration to generate query with
                           -> String            -- ^ Schema name
                           -> String            -- ^ Table name
                           -> [(String, TypeQ)] -- ^ Column names and types and constraint type
                           -> Q [Dec]           -- ^ Result declarations
defineTableTypesWithConfig config schema table columns = do
  let nmconfig = nameConfig config
      recConfig = recordConfig nmconfig
  tableDs <- defineTableTypes
             (tableVarNameDefault table)
             (relationVarName nmconfig schema table)
             (table `varNameWithPrefix` "insert")
             (table `varNameWithPrefix` "insertQuery")
             (fst $ recordTemplate recConfig schema table)
             (tableSQL (normalizedTableName config) (schemaNameMode config) (identifierQuotation config) schema table)
             (map ((quote (identifierQuotation config)) . fst) columns)
  let typeName = recordTypeName recConfig schema table
  colsDs  <- if disableSpecializedProjection config
             then [d| |]
             else defineColumnsDefault     typeName columns
  pcolsDs <- if disableOverloadedProjection config
             then [d| |]
             else defineOverloadedColumnsDefault typeName columns
  return $ tableDs ++ colsDs ++ pcolsDs

-- | Make templates about table, column and haskell record using specified naming rule.
defineTableTypesAndRecord :: Config            -- ^ Configuration to generate query with
                          -> String            -- ^ Schema name
                          -> String            -- ^ Table name
                          -> [(String, TypeQ)] -- ^ Column names and types
                          -> [Name]            -- ^ Record derivings
                          -> Q [Dec]           -- ^ Result declarations
defineTableTypesAndRecord config schema table columns derives = do
  let recConfig = recordConfig $ nameConfig config
  recD    <- defineRecordTypeWithConfig recConfig schema table columns derives
  rconD   <- defineProductConstructorInstanceWithConfig config schema table [t | (_, t) <- columns]
  ctD     <- [d| instance ShowConstantTermsSQL $(fst $ recordTemplate recConfig schema table) |]
  tableDs <- defineTableTypesWithConfig config schema table columns
  return $ recD ++ rconD ++ ctD ++ tableDs

-- | Template of derived primary 'Query'.
definePrimaryQuery :: VarName -- ^ Variable name of result declaration
                   -> TypeQ   -- ^ Parameter type of 'Query'
                   -> TypeQ   -- ^ Record type of 'Query'
                   -> ExpQ    -- ^ 'Relation' expression
                   -> Q [Dec] -- ^ Result 'Query' declaration
definePrimaryQuery toDef' paramType recType relE = do
  let toDef = varName toDef'
  simpleValD toDef
    [t| Query $paramType $recType |]
    [|  relationalQuery (primarySelect $relE) |]

-- | Template of derived primary 'Update'.
definePrimaryUpdate :: VarName -- ^ Variable name of result declaration
                    -> TypeQ   -- ^ Parameter type of 'Update'
                    -> TypeQ   -- ^ Record type of 'Update'
                    -> ExpQ    -- ^ 'Table' expression
                    -> Q [Dec] -- ^ Result 'Update' declaration
definePrimaryUpdate toDef' paramType recType tableE = do
  let toDef = varName toDef'
  simpleValD toDef
    [t| KeyUpdate $paramType $recType |]
    [|  primaryUpdate $tableE |]


-- | SQL templates derived from primary key.
defineSqlsWithPrimaryKey :: VarName -- ^ Variable name of select query definition from primary key
                         -> VarName -- ^ Variable name of update statement definition from primary key
                         -> TypeQ   -- ^ Primary key type
                         -> TypeQ   -- ^ Record type
                         -> ExpQ    -- ^ Relation expression
                         -> ExpQ    -- ^ Table expression
                         -> Q [Dec] -- ^ Result declarations
defineSqlsWithPrimaryKey sel upd paramType recType relE tableE = do
  selD <- definePrimaryQuery  sel paramType recType relE
  updD <- definePrimaryUpdate upd paramType recType tableE
  return $ selD ++ updD

-- | SQL templates derived from primary key using default naming rule.
defineSqlsWithPrimaryKeyDefault :: String  -- ^ Table name of Database
                                -> TypeQ   -- ^ Primary key type
                                -> TypeQ   -- ^ Record type
                                -> ExpQ    -- ^ Relation expression
                                -> ExpQ    -- ^ Table expression
                                -> Q [Dec] -- ^ Result declarations
defineSqlsWithPrimaryKeyDefault table  =
  defineSqlsWithPrimaryKey sel upd
  where
    sel = table `varNameWithPrefix` "select"
    upd = table `varNameWithPrefix` "update"

-- | All templates about primary key.
defineWithPrimaryKey :: Config
                     -> String  -- ^ Schema name
                     -> String  -- ^ Table name string
                     -> TypeQ   -- ^ Type of primary key
                     -> [Int]   -- ^ Indexes specifies primary key
                     -> Q [Dec] -- ^ Result declarations
defineWithPrimaryKey config schema table keyType ixs = do
  instD <- defineHasPrimaryKeyInstanceWithConfig config schema table keyType ixs
  let recType  = fst $ recordTemplate (recordConfig $ nameConfig config) schema table
      tableE   = tableVarExpDefault table
      relE     = relationVarExp config schema table
  sqlsD <- defineSqlsWithPrimaryKeyDefault table keyType recType relE tableE
  return $ instD ++ sqlsD

-- | All templates about not-null key.
defineWithNotNullKeyWithConfig :: Config -> String -> String -> Int -> Q [Dec]
defineWithNotNullKeyWithConfig = defineHasNotNullKeyInstanceWithConfig

-- | Generate all templtes about table using specified naming rule.
defineTable :: Config            -- ^ Configuration to generate query with
            -> String            -- ^ Schema name string of Database
            -> String            -- ^ Table name string of Database
            -> [(String, TypeQ)] -- ^ Column names and types
            -> [Name]            -- ^ derivings for Record type
            -> [Int]             -- ^ Primary key index
            -> Maybe Int         -- ^ Not null key index
            -> Q [Dec]           -- ^ Result declarations
defineTable config schema table columns derives primaryIxs mayNotNullIdx = do
  tblD  <- defineTableTypesAndRecord config schema table columns derives
  let pairT x y = appT (appT (tupleT 2) x) y
      keyType   = foldl1' pairT . map (snd . (columns !!)) $ primaryIxs
  primD <- case primaryIxs of
    []  -> return []
    ixs -> defineWithPrimaryKey config schema table keyType ixs
  nnD   <- maybeD (\i -> defineWithNotNullKeyWithConfig config schema table i) mayNotNullIdx
  return $ tblD ++ primD ++ nnD


-- | Unsafely inlining SQL string 'Query' in compile type.
unsafeInlineQuery :: TypeQ   -- ^ Query parameter type
                  -> TypeQ   -- ^ Query result type
                  -> String  -- ^ SQL string query to inline
                  -> VarName -- ^ Variable name for inlined query
                  -> Q [Dec] -- ^ Result declarations
unsafeInlineQuery p r sql qVar' =
  simpleValD (varName qVar')
    [t| Query $p $r |]
    [|  unsafeTypedQuery $(stringE sql) |]

-- | Extract param type and result type from defined Relation
reifyRelation :: Name           -- ^ Variable name which has Relation type
              -> Q (Type, Type) -- ^ Extracted param type and result type from Relation type
reifyRelation relVar = do
  relInfo <- reify relVar
  case unVarI relInfo of
    Just (_, (AppT (AppT (ConT prn) p) r), _)
      | prn == ''Relation    ->  return (p, r)
    _                        ->
      fail $ "expandRelation: Variable must have Relation type: " ++ show relVar

-- | Inlining composed 'Query' in compile type.
inlineQuery :: Name         -- ^ Top-level variable name which has 'Relation' type
            -> Relation p r -- ^ Object which has 'Relation' type
            -> Config       -- ^ Configuration to generate SQL
            -> QuerySuffix  -- ^ suffix SQL words
            -> String       -- ^ Variable name to define as inlined query
            -> Q [Dec]      -- ^ Result declarations
inlineQuery relVar rel config sufs qns = do
  (p, r) <- reifyRelation relVar
  unsafeInlineQuery (return p) (return r)
    (relationalQuerySQL config rel sufs)
    (varCamelcaseName qns)

-- | Generate all templates against defined record like type constructor
--   other than depending on sql-value type.
makeRelationalRecordDefault' :: Config
                             -> Name    -- ^ Type constructor name
                             -> Q [Dec] -- ^ Result declaration
makeRelationalRecordDefault' config recTypeName = do
  let recTypeConName = ConName recTypeName
  (((tyCon, vars), _dataCon), (mayNs, cts)) <- reifyRecordType recTypeName
  pw <- Record.definePersistableWidthInstance tyCon vars
  cols <- case mayNs of
    Nothing   ->  return []
    Just ns   ->  case vars of
      []      ->  do {- monomorphic case -}
        off <- Record.defineColumnOffsets recTypeConName
        let cnames =  [ (nameBase n, ct) | n  <- ns  | ct <- cts ]
        cs  <- if disableSpecializedProjection config
               then [d| |]
               else defineColumnsDefault     recTypeConName cnames
        pcs <- if disableOverloadedProjection config
               then [d| |]
               else defineOverloadedColumnsDefault recTypeConName cnames
        return $ off ++ cs ++ pcs
      _:_     ->  do {- polymorphic case -}
        cols <- if disableSpecializedProjection config
                then [d| |]
                else defineRecordProjections tyCon vars
                     [varName $ varCamelcaseName (nameBase n ++ "'") | n <- ns]
                     cts
        ovls <- if disableOverloadedProjection config
                then [d| |]
                else Overloaded.polymorphicProjections tyCon vars
                     [nameBase n | n <- ns]
                     cts
        return $ cols ++ ovls

  pc <- defineProductConstructor recTypeName
  let scPred v = classP ''ShowConstantTermsSQL [varT v]
  ct <- instanceD (mapM scPred vars) (appT [t| ShowConstantTermsSQL |] tyCon) []
  return $ concat [pw, cols, pc, [ct]]

-- | Generate all templates against defined record like type constructor
--   other than depending on sql-value type.
makeRelationalRecordDefault ::  Name   -- ^ Type constructor name
                            -> Q [Dec] -- ^ Result declaration
makeRelationalRecordDefault = makeRelationalRecordDefault' defaultConfig
