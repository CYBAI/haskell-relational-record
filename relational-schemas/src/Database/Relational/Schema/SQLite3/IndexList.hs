{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}

module Database.Relational.Schema.SQLite3.IndexList where

import GHC.Generics (Generic)
import Data.Int (Int64)
import Database.Relational.TH (defineTableTypesAndRecord)

import Database.Relational.Schema.SQLite3.Config (config)


$(defineTableTypesAndRecord config
  "pragma" "index_list"
  [
-- pragma "main.index_list"
-- column                type                NULL
-- --------------------- ------------------- ------
-- seq                   integer             No
    ("seq", [t|Int64|]),
-- name                  text                No
    ("name", [t|String|]),
-- unique                integer             No
    ("unique", [t|Int64|])
  ]
  [''Show, ''Generic])
