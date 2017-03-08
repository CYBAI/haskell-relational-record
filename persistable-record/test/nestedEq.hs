{-# OPTIONS -fno-warn-orphans #-}
{-# LANGUAGE MultiParamTypeClasses, FlexibleInstances #-}

import Test.QuickCheck.Simple (defaultMain, eqTest)

import Database.Record (toRecord, fromRecord)

import Model (User (..), Group (..), Membership (..))


main :: IO ()
main =
  defaultMain
  [ eqTest
    "toRecord just"
    (Membership { user  = User { uid = 1, uname = "Kei Hibino", note = "HRR developer" }
                , group = Just $ Group { gid = 1, gname = "Haskellers" }
                } )
    (toRecord ["1", "Kei Hibino", "HRR developer", "1", "Haskellers"])
  , eqTest
    "toRecord nothing"
    (Membership { user  = User { uid = 1, uname = "Kei Hibino", note = "HRR developer" }
                , group = Nothing
                } )
    (toRecord ["1", "Kei Hibino", "HRR developer", "<null>", "<null>"])
  , eqTest
    "fromRecord just"
    (fromRecord $ Membership { user  = User { uid = 1, uname = "Kei Hibino", note = "HRR developer" }
                             , group = Just $ Group { gid = 1, gname = "Haskellers" }
                             } )
    ["1", "Kei Hibino", "HRR developer", "1", "Haskellers"]
  , eqTest
    "fromRecord note"
    (fromRecord $ Membership { user  = User { uid = 1, uname = "Kei Hibino", note = "HRR developer" }
                             , group = Nothing
                             } )
    ["1", "Kei Hibino", "HRR developer", "<null>", "<null>"]
  ]
