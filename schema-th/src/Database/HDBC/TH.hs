{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}

-- |
-- Module      : Database.HDBC.TH
-- Copyright   : 2013 Kei Hibino
-- License     : BSD3
--
-- Maintainer  : ex8k.hibino@gmail.com
-- Stability   : experimental
-- Portability : unknown
--
-- This module contains templates to generate Haskell record types
-- and instances correspond to RDB table schema.
module Database.HDBC.TH (
  fieldInfo,

  derivingEq, derivingShow, derivingRead, derivingData, derivingTypable,

  compileErrorIO, compileError,

  defineRecordType,
  defineRecordConstructFunction,
  definePersistableInstance,
  defineRecordDecomposeFunction,

  defineRecord,
  defineRecordDefault,

  defineConstantSql,
  defineSqlPrimarySelect,
  defineSqlPrimaryUpdate,
  defineSqlInsert,

  defineSqls, defineSqlsDefault,

  defineWithTableDefault,
  defineWithPrimaryKeyDefault,
  defineWithNotNullKeyDefault,

  defineTableFromDB
  ) where

import Data.Char (toUpper, toLower)
import Data.Maybe (fromJust, listToMaybe)
import Data.List (elemIndex)

import Database.HDBC (IConnection, SqlValue, fromSql, toSql)

import Language.Haskell.TH.CamelCaseNames
  (ConName (conName), VarName (varName),
   conCamelcaseName, varCamelcaseName,
   varNameWithPrefix,
   toTypeCon)
import Language.Haskell.TH
  (Q, Name, mkName, runIO,
   TypeQ, ExpQ, DecQ, Dec,
   appsE, conE, varE, listE, litE, stringE, integerL,
   listP, varP, wildP,
   conT,
   dataD, sigD, funD, valD,
   clause, normalB,
   recC, cxt, varStrictType, strictType, isStrict)

import Database.HDBC.Session (withConnectionIO)
import Database.Record.Persistable
  (persistableRecord, Persistable, persistable,
   persistableRecordWidth, PersistableWidth, persistableWidth)
import Database.Record.KeyConstraint
  (HasKeyConstraint(constraintKey), specifyKeyConstraint, Primary, NotNull)
import Database.Record.FromSql (FromSql(recordFromSql), recordFromSql')
import Database.Record.ToSql (ToSql(recordToSql), recordToSql')
import Database.Relational.Query.Type (unsafeTypedQuery)
import Database.Relational.Query (Query)
import Database.HDBC.Record.Persistable ()
import Language.SQL.Keyword (Keyword(..), (.=.))
import qualified Language.SQL.Keyword as SQL

import Database.HDBC.Schema.Driver (Driver, getFields, getPrimaryKey)


nameOfTableSQL :: String -> String -> String
nameOfTableSQL schema table = map toUpper schema ++ '.' : map toLower table

recordTypeNameDefault :: String -> ConName
recordTypeNameDefault =  conCamelcaseName

recordTypeDefault :: String -> TypeQ
recordTypeDefault =  toTypeCon . recordTypeNameDefault


fieldInfo :: String
          -> TypeQ
          -> ((VarName, TypeQ), String) -- ^ (fieldVarName, (fieldInSQL, fieldTypeInTable))
fieldInfo n t = ((varCamelcaseName n, t), n)


derivingEq   = conCamelcaseName "Eq"
derivingShow = conCamelcaseName "Show"
derivingRead = conCamelcaseName "Read"
derivingData = conCamelcaseName "Data"
derivingTypable = conCamelcaseName "Typable"
derivingEq, derivingShow, derivingRead, derivingData, derivingTypable :: ConName

compileErrorIO :: String -> IO a
compileErrorIO =  ioError . userError

compileError :: String -> Q a
compileError =  runIO . compileErrorIO

mayDeclare :: (a -> Q [Dec]) -> Maybe a -> Q [Dec]
mayDeclare =  maybe (return [])

integralE :: Integral a => a -> ExpQ
integralE =  litE . integerL . toInteger

defineRecordType :: ConName            -- ^ Name of the data type of table record type.
                 -> [(VarName, TypeQ)] -- ^ List of fields in the table. Must be legal, properly cased record fields.
                 -> [ConName]          -- ^ Deriving type class names.
                 -> DecQ               -- ^ The data type record declaration.
defineRecordType typeName' fields derives = do
  let typeName = conName typeName'
  dataD (cxt []) typeName [] [recC typeName (map fld fields)] (map conName derives)
  where
    fld (n, tq) = varStrictType (varName n) (strictType isStrict tq)

defineRecordConstructFunction :: VarName   -- ^ Name of record construct function.
                              -> ConName   -- ^ Name of record type.
                              -> Int       -- ^ Count of record fields.
                              -> Q [Dec]   -- ^ Declaration of record construct function from SqlValues.
defineRecordConstructFunction funName' typeName' width = do
  let funName = varName funName'
      typeName = conName typeName'
      names = map (mkName . ('f':) . show) [1 .. width]
      fromSqlE n = [| fromSql $(varE n) |]
  sig <- sigD funName [t| [SqlValue] -> $(conT typeName) |]
  var <- funD funName
         [ clause
           [listP (map varP names)]
            (normalB . appsE $ conE typeName : map fromSqlE names)
            [],
            clause [wildP]
            (normalB
             [| error
                $(stringE
                  $ "Generated code of 'defineRecordConstructFunction': Fail to pattern match in: "
                  ++ show funName
                  ++ ", count of fields is " ++ show width) |])
            [] ]
  return [sig, var]

simpleValD :: Name -> TypeQ -> ExpQ -> Q [Dec]
simpleValD var typ expr =  do
  sig <- sigD var typ
  val <- valD (varP var) (normalB expr) []
  return [sig, val]

defineTableInfo :: VarName -> String
                -> VarName -> [String]
                -> VarName -> Int
                -> Q [Dec]
defineTableInfo tableVar' table fieldsVar' fields widthVar' width = do
  let tableVar = varName tableVar'
      fieldsVar = varName fieldsVar'
      widthVar = varName widthVar'
  tableQ  <- simpleValD tableVar  [t| String |]   [| $(stringE table) |]
  fieldsQ <- simpleValD fieldsVar [t| [String] |] [| $(listE $ map stringE fields) |]
  widthQ  <- simpleValD widthVar  [t| Int |]      [| $(integralE $ width) |]
  return $ concat [tableQ, fieldsQ, widthQ]

definePersistableInstance :: VarName -> TypeQ -> VarName -> VarName -> Int -> Q [Dec]
definePersistableInstance widthVar' typeCon consFunName' decompFunName' width = do
  [d| instance PersistableWidth $typeCon where
        persistableWidth = persistableRecordWidth $(varE $ varName widthVar')

      instance Persistable SqlValue $typeCon where
        persistable = persistableRecord
                      persistableWidth
                      $(varE $ varName consFunName')
                      $(varE $ varName decompFunName')

      instance FromSql SqlValue $typeCon where
        recordFromSql = recordFromSql'

      instance ToSql SqlValue $typeCon where
        recordToSql = recordToSql'
    |]

defineHasKeyConstraintInstance :: TypeQ -> TypeQ -> Int -> Q [Dec]
defineHasKeyConstraintInstance constraint typeCon index =
  [d| instance HasKeyConstraint $constraint $typeCon where
        constraintKey = specifyKeyConstraint $(integralE index) |]

defineHasNotNullKeyInstance :: TypeQ -> Int -> Q [Dec]
defineHasNotNullKeyInstance =
  defineHasKeyConstraintInstance [t| NotNull |]

defineHasPrimaryKeyInstance :: TypeQ -> Int -> Q [Dec]
defineHasPrimaryKeyInstance =
  defineHasKeyConstraintInstance [t| Primary |]

defineRecordDecomposeFunction :: VarName   -- ^ Name of record decompose function.
                              -> TypeQ     -- ^ Name of record type.
                              -> [VarName] -- ^ List of field names of record.
                              -> Q [Dec]   -- ^ Declaration of record construct function from SqlValues.
defineRecordDecomposeFunction funName' typeCon fields = do
  let funName = varName funName'
      accessors = map (varE . varName) fields
      recVar = mkName "rec"
  sig <- sigD funName [t| $typeCon -> [SqlValue] |]
  var <- funD funName [ clause [varP recVar]
                        (normalB . listE $ map (\a -> [| toSql ($a $(varE recVar)) |]) accessors)
                        [] ]
  return [sig, var]

defineRecord :: (VarName, VarName)
            -> (String, ConName)
            -> (VarName, VarName, VarName)
            -> [((VarName, TypeQ), String)]
            -> [ConName]
            -> Q [Dec]
defineRecord
  (cF, dF) (tableSQL, tyC)
  (tableN, fldsN, widthN)
  schemas' drvs = do

  let schemas = map fst schemas'
  typ  <- defineRecordType tyC schemas drvs
  let width = length schemas'
      typeCon = toTypeCon tyC
  fromSQL  <- defineRecordConstructFunction cF tyC width
  toSQL    <- defineRecordDecomposeFunction dF typeCon (map fst schemas)
  tableI   <- defineTableInfo
              tableN tableSQL
              fldsN (map snd schemas') widthN width
  instSQL  <- definePersistableInstance widthN typeCon cF dF width
  return $ typ : fromSQL ++ toSQL ++ tableI ++ instSQL

defineRecordDefault :: String
                    -> String
                    -> [(String, TypeQ)]
                    -> [ConName]
                    -> Q [Dec]
defineRecordDefault schema table fields drives = do
  let tableSQL = nameOfTableSQL schema table
      fields' = map (uncurry fieldInfo) fields
  defineRecord
    (table `varNameWithPrefix` "fromSqlOf",
     table `varNameWithPrefix` "toSqlOf")
    (tableSQL, recordTypeNameDefault table)
    (table `varNameWithPrefix` "tableOf",
     table `varNameWithPrefix` "fieldsOf",
     table `varNameWithPrefix` "widthOf")
    fields'
    drives

defineHasPrimaryKeyInstanceDefault :: String -> Int -> Q [Dec]
defineHasPrimaryKeyInstanceDefault =
  defineHasPrimaryKeyInstance . recordTypeDefault

defineHasNotNullKeyInstanceDefault :: String -> Int -> Q [Dec]
defineHasNotNullKeyInstanceDefault =
  defineHasNotNullKeyInstance . recordTypeDefault


defineConstantSql :: VarName -> String -> Q [Dec]
defineConstantSql name' sqlStr = do
  let name = varName name'
  sig <- sigD name [t| String |]
  var <- valD (varP name)
         (normalB . stringE $ sqlStr)
         []
  return [sig, var]

defineConstantSqlQuery :: TypeQ -> TypeQ -> VarName -> String -> Q [Dec]
defineConstantSqlQuery pkeyType recordType name' sqlStr = do
  let name = varName name'
  sig <- sigD name [t| Query $pkeyType $recordType |]
  var <- valD (varP name)
         (normalB [| unsafeTypedQuery $(stringE $ sqlStr) |])
         []
  return [sig, var]

defineSqlPrimarySelect :: VarName -> (String, TypeQ)-> [(String, TypeQ)] -> String -> Q [Dec]
defineSqlPrimarySelect name' (table, recordType) fields pkey =
  defineConstantSqlQuery pkeyType recordType name'
  . SQL.unwordsSQL
  $ [SELECT, fields' `SQL.sepBy` ", ",
     FROM, SQL.word table, WHERE, SQL.word pkey .=. "?"]
  where fields' = map (SQL.word . fst) fields
        pkeyType = fromJust $ lookup pkey fields

defineSqlPrimaryUpdate :: VarName -> String -> [String] -> String -> Q [Dec]
defineSqlPrimaryUpdate name' table fields pkey =
  defineConstantSql name'
  . SQL.unwordsSQL
  $ [UPDATE, SQL.word table, SET, assignments `SQL.sepBy` ", ",
     WHERE, SQL.word pkey, "= ?"]
  where assignments = map (\f -> SQL.word f .=. "?") . filter (/= pkey) $ fields

defineSqlInsert :: VarName -> String -> [String] -> Q [Dec]
defineSqlInsert name' table fields = do
  defineConstantSql name'
  . SQL.unwordsSQL
  $ [INSERT, INTO, SQL.word table, fields' `SQL.parenSepBy` ", ",
     VALUES, pfs `SQL.parenSepBy` ", "]
    where fields' = map SQL.word fields
          pfs     = replicate (length fields) "?"

defineSqls :: VarName -- ^ SQL insert statement var name
               -> (String, TypeQ)
               -> [(String, TypeQ)]
               -> Q [Dec] -- ^ SQL statement String declarations
defineSqls ins (table, _recordType) fields =
  defineSqlInsert ins table (map fst fields)

defineSqlsWithPrimaryKey :: Int               -- ^ Primary key field index
                         -> VarName           -- ^ SQL select statement var name
                         -> VarName           -- ^ SQL update statement var name
                         -> (String, TypeQ)   -- ^ Table name String in SQL and record type
                         -> [(String, TypeQ)] -- ^ Field name strings
                         -> Q [Dec]           -- ^ SQL statement String declarations
defineSqlsWithPrimaryKey i sel upd (table, recordType) fields = do
  let width = length fields
      fields' = map fst fields
      getPrimaryKeyName
        | i < 0 || width <= i = compileError
                                $  "defineSqls: Index out of bounds!: "
                                ++ "fields count is " ++ show width ++ ", but index is " ++ show i
        | otherwise           = return . fst $ fields !! i
  keyName <- getPrimaryKeyName
  selD <- defineSqlPrimarySelect sel (table, recordType) fields keyName
  updD <- defineSqlPrimaryUpdate upd table fields' keyName
  return $ selD ++ updD

defineSqlsDefault :: String -> String -> [(String, TypeQ)] -> Q [Dec]
defineSqlsDefault schema table fields =
  defineSqls ins (tableSQL, recordType) fields
  where
    tableSQL = nameOfTableSQL schema table
    recordType = recordTypeDefault table
    ins = table `varNameWithPrefix` "insert"

defineSqlsWithPrimaryKeyDefault :: String -> String -> [(String, TypeQ)] -> Int -> Q [Dec]
defineSqlsWithPrimaryKeyDefault schema table fields idx =
  defineSqlsWithPrimaryKey idx sel upd (tableSQL, recordType) fields
  where
    tableSQL = nameOfTableSQL schema table
    recordType = recordTypeDefault table
    sel = table `varNameWithPrefix` "select"
    upd = table `varNameWithPrefix` "update"

defineWithTableDefault' :: String
                        -> String
                        -> [(String, TypeQ)]
                        -> [ConName]
                        -> Q [Dec]
defineWithTableDefault' schema table fields derives = do
  recD <- defineRecordDefault schema table fields derives
  sqlD <- defineSqlsDefault schema table fields
  return $ recD ++ sqlD

defineWithPrimaryKeyDefault :: String -> String -> [(String, TypeQ)] -> Int -> Q [Dec]
defineWithPrimaryKeyDefault schema table fields idx = do
  instD <- defineHasPrimaryKeyInstanceDefault table idx
  sqlsD <- defineSqlsWithPrimaryKeyDefault schema table fields idx
  return $ instD ++ sqlsD

defineWithNotNullKeyDefault :: String -> Int -> Q [Dec]
defineWithNotNullKeyDefault =  defineHasNotNullKeyInstanceDefault

defineWithTableDefault :: String
                       -> String
                       -> [(String, TypeQ)]
                       -> [ConName]
                       -> Maybe Int
                       -> Maybe Int
                       -> Q [Dec]
defineWithTableDefault schema table fields derives mayPrimaryIdx mayNotNullIdx  = do
  tblD  <- defineWithTableDefault' schema table fields derives
  primD <- mayDeclare (defineWithPrimaryKeyDefault schema table fields) mayPrimaryIdx
  nnD   <- mayDeclare (defineWithNotNullKeyDefault table) mayNotNullIdx
  return $ tblD ++ primD ++ nnD

putLog :: String -> IO ()
putLog =  putStrLn

defineTableFromDB :: IConnection conn
                   => IO conn
                   -> Driver conn
                   -> String
                   -> String 
                   -> [ConName]
                   -> Q [Dec]
defineTableFromDB connect drv scm tbl derives = do
  let getDBinfo =
        withConnectionIO connect
        (\conn ->  do
            (cols, notNullIdxs) <- getFields drv conn scm tbl
            mayPrimaryKey       <- getPrimaryKey drv conn scm tbl

            mayPrimaryIdx <- case mayPrimaryKey of
              Just key -> case elemIndex key $ map fst cols of
                Nothing -> do putLog $ "defineTableFromDB: fail to find index of pkey - " ++ key ++ ". Something wrong!!"
                              return   Nothing
                Just ix ->    return $ Just ix
              Nothing  ->     return   Nothing
            return (cols, notNullIdxs, mayPrimaryIdx) )

  (cols, notNullIdxs, mayPrimaryIdx) <- runIO getDBinfo
  defineWithTableDefault scm tbl cols derives mayPrimaryIdx (listToMaybe notNullIdxs)
