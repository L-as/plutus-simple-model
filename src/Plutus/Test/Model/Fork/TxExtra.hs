module Plutus.Test.Model.Fork.TxExtra (
  -- * Plutus TX with extra fields
  TxExtra(..),
  Extra(..),
  Withdraw(..),
  toExtra,
  setExtra,
  -- * Staking valdiators primitives
  stakeWithdrawKey,
  stakeWithdrawScript,
) where

import Prelude
import Ledger
import Plutus.V1.Ledger.Api

-- | Plutus TX with extra fields for Cardano TX
data TxExtra = TxExtra
  { txExtra'extra :: Extra
  , txExtra'tx    :: Tx
  }

-- | Wrap TX to extra fields (empty fields are allocated)
toExtra :: Tx -> TxExtra
toExtra = TxExtra mempty

-- | Extra fields for Cardano TX
data Extra = Extra
  { extra'withdraws      :: [Withdraw]
  , extra'certificates   :: [DCert]
  }

-- | Stake withdrawal
data Withdraw = Withdraw
  { withdraw'credential :: StakingCredential                 -- ^ staking credential
  , withdraw'amount     :: Integer                           -- ^ amount of withdrawal in Lovelace
  , withdraw'script     :: Maybe (Redeemer, StakeValidator)  -- ^ Just in case of script withdrawal
  }

instance Semigroup Extra where
  (<>) (Extra a1 a2) (Extra b1 b2) = Extra (a1 <> b1) (a2 <> b2)

instance Monoid Extra where
  mempty = Extra [] []

-- | Adds to TxExtra new settings
setExtra :: Extra -> TxExtra -> TxExtra
setExtra a (TxExtra e tx) = TxExtra (e <> a) tx

-- | Add staking withdrawal based on pub key hash
stakeWithdrawKey :: PubKeyHash -> Integer -> TxExtra -> TxExtra
stakeWithdrawKey key amount = setExtra $ mempty
  { extra'withdraws = [Withdraw (StakingHash $ PubKeyCredential key) amount Nothing]
  }

-- | Add staking withdrawal based on script
stakeWithdrawScript :: ToData redeemer
  => StakeValidator -> redeemer -> Integer -> TxExtra -> TxExtra
stakeWithdrawScript validator red amount = setExtra $ mempty
  { extra'withdraws = pure $
    Withdraw (StakingHash $ ScriptCredential vh) amount (Just (Redeemer $ toBuiltinData red, validator))
  }
  where
    vh = validatorHash $ Validator $ getStakeValidator validator

