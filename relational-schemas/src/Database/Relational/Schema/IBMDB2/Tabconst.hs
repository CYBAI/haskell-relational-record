{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}

-- |
-- Module      : Database.Relational.Schema.DB2Syscat.Tabconst
-- Copyright   : 2013-2019 Kei Hibino
-- License     : BSD3
--
-- Maintainer  : ex8k.hibino@gmail.com
-- Stability   : experimental
-- Portability : unknown
--
-- Generate template of SYSCAT.tabconst system catalog table.
-- Not all columns are mapped to Haskell record.
-- Minimum implementation required to generate table constraints.
module Database.Relational.Schema.IBMDB2.Tabconst where

import GHC.Generics (Generic)
import Database.Relational.TH (defineTableTypesAndRecord)

import Database.Relational.Schema.IBMDB2.Config (config)


-- Not all column is mapped. Minimum implementation.
$(defineTableTypesAndRecord config
  "SYSCAT" "tabconst"
  [("constname", [t| String |]),
   ("tabschema", [t| String |]),
   ("tabname"  , [t| String |]),
   --
   ("type"     , [t| String |]),
   ("enforced" , [t| String |])]
  [''Show, ''Generic])
