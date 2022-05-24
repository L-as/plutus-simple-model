{-# OPTIONS_GHC -fno-warn-orphans #-}

{- | Simple test model for plutus scripts.

 We can create blockchain with main user that holds all the value
 and can distribute it to test users.

 The blockchain update happens according to the Cardano node rules
 and is executed as simple state update. We can query all blockchain stats
 for the users.

 Also it estimates execution of the TXs accordig to cardano model.
-}
module Plutus.Test.Model.Blockchain (
  -- * Address helpers
  HasAddress (..),
  HasStakingCredential (..),
  AppendStaking (..),
  appendStakingCredential,
  appendStakingPubKey,
  appendStakingScript,

  -- * Blockchain model
  Blockchain (..),
  BchConfig (..),
  CheckLimits (..),
  BchNames (..),
  User (..),
  TxStat (..),
  PoolId (..),
  ExecutionUnits (..),
  Result (..),
  isOkResult,
  FailReason (..),
  LimitOverflow (..),
  modifyBchNames,
  writeUserName,
  writeAddressName,
  writeAssetClassName,
  writeCurrencySymbolName,
  writeTxName,
  readUserName,
  readAddressName,
  readAssetClassName,
  readCurrencySymbolName,
  readTxName,
  Run (..),
  runBch,
  initBch,
  Percent (..),
  toPercent,
  StatPercent (..),
  PercentExecutionUnits (..),
  toStatPercent,

  -- * core blockchain functions
  getMainUser,
  signTx,
  sendBlock,
  sendTx,
  logFail,
  logInfo,
  logError,
  noLog,
  noLogTx,
  noLogInfo,
  pureFail,
  txOutRefAt,
  getTxOut,
  utxoAt,
  utxoAtState,
  datumAt,
  rewardAt,
  stakesAt,
  hasPool,
  hasStake,
  getPools,
  waitNSlots,
  getUserPubKey,

  -- * Blockchain config
  readBchConfig,
  readProtocolParameters,
  defaultBchConfig,
  readDefaultBchConfig,
  skipLimits,
  warnLimits,
  forceLimits,

  -- * Resources limits (Alonzo)
  mainnetBlockLimits,
  mainnetTxLimits,
  testnetBlockLimits,
  testnetTxLimits,

  -- * Logs
  Log (..),
  appendLog,
  nullLog,
  fromLog,
  fromGroupLog,
  BchEvent (..),
  silentLog,
  failLog,
  filterSlot,
  getLog,
  getFails,
  MustFailLog (..),

  -- * internal
  intToPubKey,
) where

import Prelude

import Data.Aeson (decodeFileStrict')
import Data.ByteString qualified as BS
import Data.Coerce (coerce)
import Data.Either
import Data.Foldable
import Data.Function (on)
import Data.List qualified as L
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as M
import Data.Maybe
import Data.Sequence (Seq (..))
import Data.Sequence qualified as Seq
import Data.Set (Set)
import Data.Set qualified as S
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Data.Vector qualified as V

import Basement.Compat.Natural
import Cardano.Api.Shelley (
  AlonzoEra,
  ConsensusMode (..),
  EraHistory (..),
  EraInMode (..),
  ExecutionUnits (..),
  NetworkId (..),
  ProtocolParameters (..),
  ScriptExecutionError,
  TransactionValidityError (..),
  UTxO (..),
  evaluateTransactionBalance,
  evaluateTransactionExecutionUnits,
  fromAlonzoData,
  serialiseToCBOR,
  toCtxUTxOTxOut,
  txOutValueToValue,
 )
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Slotting.Time (RelativeTime (..), SystemStart (..), slotLengthFromMillisec)
import Control.Monad.State.Strict
import Ledger (PaymentPubKeyHash (..), txId)
import Ledger.Typed.Scripts (TypedValidator, ValidatorTypes (..), validatorAddress)
import Plutus.V1.Ledger.Ada qualified as Ada
import Plutus.V1.Ledger.Address
import Plutus.V1.Ledger.Api
import Plutus.V1.Ledger.Interval ()
import Plutus.V1.Ledger.Interval qualified as Interval
import Plutus.V1.Ledger.Slot (Slot (..), SlotRange)
import Plutus.V1.Ledger.Tx (TxIn)
import Plutus.V1.Ledger.Tx qualified as P
import Plutus.V1.Ledger.Value (AssetClass, valueOf)
import PlutusTx.Prelude qualified as Plutus

import Ouroboros.Consensus.Block.Abstract (EpochNo (..), EpochSize (..))
import Ouroboros.Consensus.HardFork.History.EraParams
import Ouroboros.Consensus.HardFork.History.Qry (mkInterpreter)
import Ouroboros.Consensus.HardFork.History.Summary (
  Bound (..),
  EraEnd (..),
  EraSummary (..),
  Summary (..),
 )
import Ouroboros.Consensus.Util.Counting (NonEmpty (..))

import Cardano.Api qualified as Cardano
import Cardano.Binary qualified as CBOR
import Cardano.Crypto.Hash qualified as Crypto
import Cardano.Ledger.Alonzo.Data qualified as Alonzo
import Cardano.Ledger.Hashes as Ledger (EraIndependentTxBody)
import Ledger.Crypto (PubKey (..), Signature (..), pubKeyHash)
import Ledger.TimeSlot (SlotConfig (..))
import Ledger.Tx.CardanoAPI qualified as Cardano
import Paths_plutus_simple_model
import Plutus.Test.Model.Fork.CardanoAPI qualified as Fork
import Plutus.Test.Model.Fork.TxExtra
import Plutus.Test.Model.Stake

class HasAddress a where
  toAddress :: a -> Address

instance HasAddress Address where
  toAddress = id

instance HasAddress PubKeyHash where
  toAddress = pubKeyHashAddress

instance HasAddress ValidatorHash where
  toAddress = scriptHashAddress

instance HasAddress (TypedValidator a) where
  toAddress = validatorAddress

class HasStakingCredential a where
  toStakingCredential :: a -> StakingCredential

instance HasStakingCredential StakingCredential where
  toStakingCredential = id

instance HasStakingCredential PubKeyHash where
  toStakingCredential = keyToStaking

instance HasStakingCredential StakeValidator where
  toStakingCredential = scriptToStaking

-- | Encodes appening of staking address
data AppendStaking a
  = AppendStaking StakingCredential a

instance ValidatorTypes (TypedValidator a) where
  type DatumType (TypedValidator a) = DatumType a
  type RedeemerType (TypedValidator a) = RedeemerType a

instance ValidatorTypes (AppendStaking (TypedValidator a)) where
  type DatumType (AppendStaking (TypedValidator a)) = DatumType a
  type RedeemerType (AppendStaking (TypedValidator a)) = RedeemerType a

instance HasAddress a => HasAddress (AppendStaking a) where
  toAddress (AppendStaking stakeCred a) = appendStake (toAddress a)
    where
      appendStake addr = addr {addressStakingCredential = Just stakeCred}

appendStakingCredential :: Credential -> a -> AppendStaking a
appendStakingCredential cred = AppendStaking (StakingHash cred)

appendStakingPubKey :: PubKeyHash -> a -> AppendStaking a
appendStakingPubKey pkh = appendStakingCredential (PubKeyCredential pkh)

appendStakingScript :: StakeValidatorHash -> a -> AppendStaking a
appendStakingScript sh = appendStakingCredential (ScriptCredential $ coerce sh)

instance Semigroup ExecutionUnits where
  (<>) (ExecutionUnits a1 b1) (ExecutionUnits a2 b2) =
    ExecutionUnits (a1 + a2) (b1 + b2)

instance Monoid ExecutionUnits where
  mempty = ExecutionUnits 0 0

data PercentExecutionUnits = PercentExecutionUnits
  { percentExecutionSteps :: !Percent
  , percentExecutionMemory :: !Percent
  }
  deriving (Show, Eq)

newtype User = User
  { userPubKey :: PubKey
  }
  deriving (Show)

-- | TX with stats of TX execution onchain.
data TxStat = TxStat
  { txStatTx :: !Tx
  , txStatTime :: !Slot
  , txStat :: !Stat
  , txStatPercent :: !StatPercent
  }
  deriving (Show)

-- | Config for the blockchain.
data BchConfig = BchConfig
  { -- | limits check mode
    bchConfigCheckLimits :: !CheckLimits
  , -- | TX execution resources limits
    bchConfigLimitStats :: !Stat
  , -- | Protocol parameters
    bchConfigProtocol :: !ProtocolParameters
  , -- | Network id (mainnet / testnet)
    bchConfigNetworkId :: !NetworkId
  , -- | Slot config
    bchConfigSlotConfig :: !SlotConfig
  }

data CheckLimits
  = -- | ignore TX-limits
    IgnoreLimits
  | -- | log TX to error log if it exceeds limits but accept TX
    WarnLimits
  | -- | reject TX if it exceeds the limits
    ErrorLimits
  deriving (Show)

-- | Default slot config
defaultSlotConfig :: SlotConfig
defaultSlotConfig =
  SlotConfig
    { scSlotLength = 1000 -- each slot lasts for 1 second
    , scSlotZeroTime = 0 -- starts at unix epoch start
    }

-- | Loads default config for the blockchain. Uses presaved era history and protocol parameters.
readDefaultBchConfig :: IO BchConfig
readDefaultBchConfig = do
  paramsFile <- getDataFileName "data/protocol-params.json"
  readBchConfig paramsFile

-- | Default blockchain config.
defaultBchConfig :: ProtocolParameters -> BchConfig
defaultBchConfig params =
  BchConfig
    { bchConfigLimitStats = mainnetTxLimits
    , bchConfigCheckLimits = ErrorLimits
    , bchConfigProtocol = params
    , bchConfigNetworkId = Mainnet
    , bchConfigSlotConfig = defaultSlotConfig
    }

-- | Do not check for limits
skipLimits :: BchConfig -> BchConfig
skipLimits cfg = cfg {bchConfigCheckLimits = IgnoreLimits}

-- | Warn on limits
warnLimits :: BchConfig -> BchConfig
warnLimits cfg = cfg {bchConfigCheckLimits = WarnLimits}

-- | Error on limits
forceLimits :: BchConfig -> BchConfig
forceLimits cfg = cfg {bchConfigCheckLimits = ErrorLimits}

{- | Read config for protocol parameters and form blockchain config.

 > readBchConfig protocolParametersFile
-}
readBchConfig :: FilePath -> IO BchConfig
readBchConfig paramsFile =
  defaultBchConfig <$> readProtocolParameters paramsFile

-- | Reads protocol parameters from file.
readProtocolParameters :: FilePath -> IO ProtocolParameters
readProtocolParameters file =
  fmap fromJust $ decodeFileStrict' file

-- | Stats of TX execution onchain.
data Stat = Stat
  { -- | TX-size in bytes
    statSize :: !Integer
  , -- | execution units of TX
    statExecutionUnits :: !ExecutionUnits
  }
  deriving (Show, Eq)

-- | Percent values from 0 to 100 %.
newtype Percent = Percent {getPercent :: Float}
  deriving (Show, Eq)

-- | Convert integer to percent based on maximum value (first argument)
toPercent :: Integer -> Integer -> Percent
toPercent maxLim n = Percent $ (fromInteger @Float $ 100 * n) / fromInteger maxLim

-- | Stats measured in percents (0 to 100 %)
data StatPercent = StatPercent
  { statPercentSize :: !Percent
  , statPercentExecutionUnits :: !PercentExecutionUnits
  }
  deriving (Show, Eq)

-- | Get Stats expressed in percents based on maximum limits and given stats.
toStatPercent :: Stat -> Stat -> StatPercent
toStatPercent maxStat stat =
  StatPercent
    { statPercentSize = percent statSize
    , statPercentExecutionUnits =
        PercentExecutionUnits
          { percentExecutionSteps = percentNat executionSteps
          , percentExecutionMemory = percentNat executionMemory
          }
    }
  where
    percentNat getter = percent (naturalToInteger . getter . statExecutionUnits)

    percent :: (Stat -> Integer) -> Percent
    percent getter = toPercent (getter maxStat) (getter stat)

{- | Simple model for UTXO-based blockchain.
 We have set of UTXOs. Every UTXO can belong to the user (owner of PubKey) or to script.
 We submit blocks of TXs to update the blockchain. TX destroys input UTXOs and produces new UTXOs.

 Update happens as pure function in the State-monad. As TX is submitted we get useful performance stats
 such as TX-size and execution units. All stats are calculated with cardano node functions and TX-size
 is estimated on Cardano version of TX.
-}
data Blockchain = Blockchain
  { bchUsers :: !(Map PubKeyHash User)
  , bchAddresses :: !(Map Address (Set TxOutRef))
  , bchUtxos :: !(Map TxOutRef TxOut)
  , bchDatums :: !(Map DatumHash Datum)
  , bchStake :: !Stake
  , bchTxs :: !(Log TxStat)
  , bchConfig :: !BchConfig
  , bchCurrentSlot :: !Slot
  , bchUserStep :: !Integer
  , bchFails :: !(Log FailReason)
  , bchInfo :: !(Log String)
  , mustFailLog :: !(Log MustFailLog)
  , -- | human readable names. Idea is to substitute for them
    -- in pretty printers for error logs, user names, script names.
    bchNames :: !BchNames
  }

newtype Log a = Log {unLog :: Seq (Slot, a)}
  deriving (Functor)

instance Semigroup (Log a) where
  (<>) (Log sa) (Log sb) = Log (merge sa sb)
    where
      merge Empty b = b
      merge a Empty = a
      merge (a :<| as) (b :<| bs) =
        if fst a <= fst b
          then a Seq.<| merge as (b Seq.<| bs)
          else b Seq.<| merge (a Seq.<| as) bs

appendLog :: Slot -> a -> Log a -> Log a
appendLog slot val (Log xs) = Log (xs Seq.|> (slot, val))

nullLog :: Log a -> Bool
nullLog (Log a) = Seq.null a

fromLog :: Log a -> [(Slot, a)]
fromLog (Log s) = toList s

fromGroupLog :: Log a -> [(Slot, [a])]
fromGroupLog = fmap toGroup . L.groupBy ((==) `on` fst) . fromLog
  where
    toGroup ((a, b) : rest) = (a, b : fmap snd rest)
    toGroup [] = error "toGroup: Empty list"

instance Monoid (Log a) where
  mempty = Log Seq.empty

{- | Wrapper for error logs, produced in the paths of execution protected by
 'mustFail' combinator.
-}
data MustFailLog = MustFailLog String FailReason

-- | Result of the execution.
data Result = Ok | Fail FailReason
  deriving (Show)

-- | Result is ok.
isOkResult :: Result -> Bool
isOkResult = \case
  Ok -> True
  _ -> False

-- | Fail reasons.
data FailReason
  = -- | use with given pub key hash is not found. User was not registered with @newUser@ or @newUserWith@.
    NoUser PubKeyHash
  | -- | not enough funds for the user.
    NotEnoughFunds PubKeyHash Value
  | -- | time or vlaid range related errors
    IntervalError TransactionValidityError
  | -- | TX is not balanced. Sum of inputs does not equal to sum of outputs.
    NotBalancedTx
  | -- | no utxo on the address
    FailToReadUtxo
  | -- | failed to convert plutus TX to cardano TX. TX is malformed.
    FailToCardano Cardano.ToCardanoError
  | -- | execution of the script failure
    TxScriptFail [ScriptExecutionError]
  | -- | invalid range. TX is submitted with current slot not in valid range
    TxInvalidRange Slot SlotRange
  | -- | invalid reward for staking credential, expected and actual values for stake at the moment of reward
    TxInvalidWithdraw WithdrawError
  | -- | Certificate errors
    TxInvalidCertificate DCertError
  | TxLimitError [LimitOverflow] StatPercent
  | -- | Any error (can be useful to report logic errors on testing)
    GenericFail String
  deriving (Show)

-- | Encodes overflow of the TX-resources
data LimitOverflow
  = -- | by how many bytes we exceed the limit
    TxSizeError !Integer !Percent
  | -- | how many mem units exceeded
    ExMemError !Integer !Percent
  | -- | how many steps executions exceeded
    ExStepError !Integer !Percent
  deriving (Show, Eq)

-- | State monad wrapper to run blockchain.
newtype Run a = Run (State Blockchain a)
  deriving (Functor, Applicative, Monad, MonadState Blockchain)

{- | Dummy instance to be able to use partial pattern matching
 in do-notation
-}
instance MonadFail Run where
  fail err = error $ "Failed to recover: " <> err

-- | Human readable names for pretty printing.
data BchNames = BchNames
  { bchNameUsers :: !(Map PubKeyHash String)
  , bchNameAddresses :: !(Map Address String)
  , bchNameAssetClasses :: !(Map AssetClass String)
  , bchNameCurrencySymbols :: !(Map CurrencySymbol String)
  , bchNameTxns :: !(Map TxId String)
  }

-- | Modifies the mappings to human-readable names
modifyBchNames :: (BchNames -> BchNames) -> Run ()
modifyBchNames f = modify' $ \s -> s {bchNames = f (bchNames s)}

-- | Assigns human-readable name to user
writeUserName :: PubKeyHash -> String -> Run ()
writeUserName pkh name = do
  modifyBchNames $ \ns ->
    ns {bchNameUsers = M.insert pkh name (bchNameUsers ns)}
  writeAddressName (pubKeyHashAddress pkh) name

-- | Assigns human-readable name to address
writeAddressName :: Address -> String -> Run ()
writeAddressName addr name = modifyBchNames $ \ns ->
  ns {bchNameAddresses = M.insert addr name (bchNameAddresses ns)}

-- | Assigns human-readable name to asset class
writeAssetClassName :: AssetClass -> String -> Run ()
writeAssetClassName ac name = modifyBchNames $ \ns ->
  ns {bchNameAssetClasses = M.insert ac name (bchNameAssetClasses ns)}

-- | Assigns human-readable name to currency symbol
writeCurrencySymbolName :: CurrencySymbol -> String -> Run ()
writeCurrencySymbolName cs name = modifyBchNames $ \ns ->
  ns {bchNameCurrencySymbols = M.insert cs name (bchNameCurrencySymbols ns)}

-- | Assigns human-readable name to a transaction
writeTxName :: Tx -> String -> Run ()
writeTxName (txId . tx'plutus -> ident) name = modifyBchNames $ \ns ->
  ns {bchNameTxns = M.insert ident name (bchNameTxns ns)}

-- | Gets human-readable name of user
readUserName :: BchNames -> PubKeyHash -> Maybe String
readUserName names pkh = M.lookup pkh (bchNameUsers names)

-- | Gets human-readable name of address
readAddressName :: BchNames -> Address -> Maybe String
readAddressName names addr = M.lookup addr (bchNameAddresses names)

-- | Gets human-readable name of user
readAssetClassName :: BchNames -> AssetClass -> Maybe String
readAssetClassName names ac = M.lookup ac (bchNameAssetClasses names)

-- | Gets human-readable name of user
readCurrencySymbolName :: BchNames -> CurrencySymbol -> Maybe String
readCurrencySymbolName names cs = M.lookup cs (bchNameCurrencySymbols names)

-- | Gets human-readable name of transaction
readTxName :: BchNames -> TxId -> Maybe String
readTxName names cs = M.lookup cs (bchNameTxns names)

--------------------------------------------------------
-- API

{- | Get pub key hash of the admin user.
 It can be useful to distribute funds to the users.
-}
getMainUser :: Run PubKeyHash
getMainUser = pure $ pubKeyHash $ intToPubKey 0

-- | Run blockchain.
runBch :: Run a -> Blockchain -> (a, Blockchain)
runBch (Run act) = runState act

-- | Init blockchain state.
initBch :: BchConfig -> Value -> Blockchain
initBch cfg initVal =
  Blockchain
    { bchUsers = M.singleton genesisUserId genesisUser
    , bchUtxos = M.singleton genesisTxOutRef genesisTxOut
    , bchDatums = M.empty
    , bchAddresses = M.singleton genesisAddress (S.singleton genesisTxOutRef)
    , bchStake = initStake
    , bchTxs = mempty
    , bchConfig = cfg
    , bchCurrentSlot = Slot 1
    , bchUserStep = 1
    , bchFails = mempty
    , bchInfo = mempty
    , mustFailLog = mempty
    , bchNames =
        BchNames
          (M.singleton genesisUserId "Genesis role")
          (M.singleton genesisAddress "Genesis role")
          M.empty
          M.empty
          M.empty
    }
  where
    genesisUserId = pubKeyHash genesisPubKey
    genesisPubKey = intToPubKey 0
    genesisUser = User genesisPubKey
    genesisAddress = pubKeyHashAddress genesisUserId

    genesisTxOutRef = TxOutRef genesisTxId 0
    genesisTxOut = TxOut (pubKeyHashAddress genesisUserId) initVal Nothing

    initStake =
      Stake
        { stake'pools = M.singleton genesisPoolId (Pool {pool'stakes = [genesisStakingCred]})
        , stake'poolIds = V.singleton genesisPoolId
        , stake'stakes = M.singleton genesisStakingCred 0
        , stake'nextReward = 0
        }

    genesisPoolId = PoolId genesisUserId
    genesisStakingCred = keyToStaking genesisUserId

-- Hash for genesis transaction
dummyHash :: Crypto.Hash Crypto.Blake2b_256 Ledger.EraIndependentTxBody
dummyHash = Crypto.castHash $ Crypto.hashWith CBOR.serialize' ()

-- | genesis transaction ID
genesisTxId :: TxId
genesisTxId = Cardano.fromCardanoTxId . Cardano.TxId $ dummyHash

intToPubKey :: Integer -> PubKey
intToPubKey n = PubKey $ LedgerBytes $ Plutus.sha2_256 $ Plutus.consByteString n Plutus.mempty

getUserPubKey :: PubKeyHash -> Run (Maybe PubKey)
getUserPubKey pkh =
  fmap userPubKey . M.lookup pkh <$> gets bchUsers

-- | Sign TX for the user.
signTx :: PubKeyHash -> Tx -> Run Tx
signTx pkh = updatePlutusTx $ \tx -> do
  mPk <- getUserPubKey pkh
  case mPk of
    Just pk -> pure $ tx {P.txSignatures = M.insert pk (Signature $ getPubKeyHash pkh) $ P.txSignatures tx}
    Nothing -> do
      logFail (NoUser pkh)
      pure tx

-- | Return list of failures
getFails :: Run (Log FailReason)
getFails = gets bchFails

-- | Logs failure and returns it.
pureFail :: FailReason -> Run Result
pureFail res = do
  logFail res
  pure $ Fail res

-- | Log failure.
logFail :: FailReason -> Run ()
logFail res = do
  curTime <- gets bchCurrentSlot
  modify' $ \s -> s {bchFails = appendLog curTime res (bchFails s)}

-- | Log generic error.
logError :: String -> Run ()
logError = logFail . GenericFail

logInfo :: String -> Run ()
logInfo msg = do
  slot <- gets bchCurrentSlot
  modify' $ \s -> s {bchInfo = appendLog slot msg (bchInfo s)}

-- | Igonres log of TXs and info messages during execution (but not errors)
noLog :: Run a -> Run a
noLog act = do
  txLog <- gets bchTxs
  infoLog <- gets bchInfo
  res <- act
  modify' $ \st -> st {bchTxs = txLog, bchInfo = infoLog}
  pure res

-- | Igonres log of TXs during execution
noLogTx :: Run a -> Run a
noLogTx act = do
  txLog <- gets bchTxs
  res <- act
  modify' $ \st -> st {bchTxs = txLog}
  pure res

-- | Igonres log of info level messages during execution
noLogInfo :: Run a -> Run a
noLogInfo act = do
  infoLog <- gets bchInfo
  res <- act
  modify' $ \st -> st {bchInfo = infoLog}
  pure res

-- | Send block of TXs to blockchain.
sendBlock :: [Tx] -> Run (Either FailReason [Stat])
sendBlock txs = do
  res <- sequence <$> mapM sendSingleTx txs
  when (isRight res) bumpSlot
  pure res

-- | Sends block with single TX to blockchai
sendTx :: Tx -> Run (Either FailReason Stat)
sendTx tx = do
  res <- sendSingleTx tx
  when (isRight res) bumpSlot
  pure res

{- | Send single TX to blockchain. It logs failure if TX is invalid
 and produces performance stats if TX was ok.
-}
sendSingleTx :: Tx -> Run (Either FailReason Stat)
sendSingleTx (Tx extra tx) =
  withCheckStaking $
    withCheckRange $
      withTxBody $ \protocol txBody -> do
        let tid = Cardano.fromCardanoTxId $ Cardano.getTxId txBody
        withUTxO tid $ \utxo ->
          withCheckBalance protocol utxo txBody $
            withCheckUnits protocol utxo txBody $ \cost -> do
              let txSize = fromIntegral $ BS.length $ serialiseToCBOR txBody
                  stat = Stat txSize cost
              withCheckTxLimits stat $ do
                applyTx stat tid (Tx extra tx)
                pure $ Right stat
  where
    pkhs = fmap pubKeyHash $ M.keys $ P.txSignatures tx

    withCheckStaking cont = withCheckWithdraw (withCheckCertificates cont)

    withCheckWithdraw cont = maybe cont leftFail =<< checkWithdraws (extra'withdraws extra)
    withCheckCertificates cont = maybe cont leftFail =<< checkCertificates (extra'certificates extra)

    checkWithdraws ws = do
      st <- gets bchStake
      go st ws
      where
        go st = \case
          [] -> pure Nothing
          Withdraw {..} : rest ->
            case checkWithdrawStake pkhs withdraw'credential withdraw'amount st of
              Nothing -> go st rest
              Just err -> pure $ Just $ TxInvalidWithdraw err

    checkCertificates certs = do
      st <- gets bchStake
      go st (certificate'dcert <$> certs)
      where
        go st = \case
          [] -> pure Nothing
          c : cs -> case checkDCert c st of
            Nothing -> go (reactDCert c st) cs
            Just err -> pure $ Just $ TxInvalidCertificate err

    withCheckRange cont = do
      curSlot <- gets bchCurrentSlot
      if Interval.member curSlot $ P.txValidRange tx
        then cont
        else leftFail $ TxInvalidRange curSlot (P.txValidRange tx)

    withUTxO tid cont = do
      mUtxo <- getUTxO tid tx
      case mUtxo of
        Just (Right utxo) -> cont utxo
        Just (Left err) -> leftFail $ FailToCardano err
        Nothing -> leftFail FailToReadUtxo

    withTxBody cont = do
      cfg <- gets bchConfig
      case Fork.toCardanoTxBody (fmap PaymentPubKeyHash pkhs) (Just $ bchConfigProtocol cfg) (bchConfigNetworkId cfg) (Tx extra tx) of
        Right txBody -> cont (bchConfigProtocol cfg) txBody
        Left err -> leftFail $ FailToCardano err

    withCheckBalance protocol utxo txBody cont
      | balanceIsOk = cont
      | otherwise = leftFail NotBalancedTx
      where
        balanceIsOk = txOutValueToValue (evaluateTransactionBalance protocol S.empty utxo txBody) == mempty

    withCheckUnits protocol utxo txBody cont = do
      slotCfg <- gets (bchConfigSlotConfig . bchConfig)
      let cardanoSystemStart = SystemStart $ posixSecondsToUTCTime $ fromInteger $ (`div` 1000) $ getPOSIXTime $ scSlotZeroTime slotCfg
          -- see EraSummary: http://localhost:8080/file//nix/store/qix63dnd40m23iap66184b4vib426r66-ouroboros-consensus-lib-ouroboros-consensus-0.1.0.0-haddock-doc/share/doc/ouroboros-consensus/html/Ouroboros-Consensus-HardFork-History-Summary.html#t:EraSummary
          eStart = Bound (RelativeTime 0) (SlotNo 0) (EpochNo 0)
          eEnd = EraUnbounded
          eParams = EraParams (EpochSize 1) (slotLengthFromMillisec $ scSlotLength slotCfg) (StandardSafeZone 1)
          eraHistory = EraHistory CardanoMode $ mkInterpreter $ Summary $ NonEmptyOne $ EraSummary eStart eEnd eParams
      case getExecUnits cardanoSystemStart eraHistory of
        Right res ->
          let res' = (\(k, v) -> fmap (k,) v) <$> M.toList res
              errs = foldErrors res'
              cost = foldCost res'
           in case errs of
                [] -> cont cost
                _ -> leftFail $ TxScriptFail errs
        Left err -> leftFail $ IntervalError err
      where
        getExecUnits sysStart eraHistory = evaluateTransactionExecutionUnits AlonzoEraInCardanoMode sysStart eraHistory protocol utxo txBody
        foldErrors = lefts
        foldCost = foldMap snd . rights

    withCheckTxLimits stat cont = do
      maxLimits <- gets (bchConfigLimitStats . bchConfig)
      checkLimits <- gets (bchConfigCheckLimits . bchConfig)
      let errs = compareLimits maxLimits stat
          statPercent = toStatPercent maxLimits stat
      if null errs
        then cont
        else case checkLimits of
          IgnoreLimits -> cont
          WarnLimits -> logFail (TxLimitError errs statPercent) >> cont
          ErrorLimits -> leftFail (TxLimitError errs statPercent)

    leftFail err = do
      logFail err
      pure $ Left err

compareLimits :: Stat -> Stat -> [LimitOverflow]
compareLimits maxLimits stat =
  catMaybes
    [ cmp TxSizeError statSize
    , cmp ExMemError (naturalToInteger . executionMemory . statExecutionUnits)
    , cmp ExStepError (naturalToInteger . executionSteps . statExecutionUnits)
    ]
  where
    cmp cons getter
      | overflow > 0 = Just $ cons overflow (toPercent (getter maxLimits) overflow)
      | otherwise = Nothing
      where
        overflow = getter stat - getter maxLimits

-- | Read UTxO relevant to transaction
getUTxO :: TxId -> P.Tx -> Run (Maybe (Either Cardano.ToCardanoError (UTxO AlonzoEra)))
getUTxO tid tx = do
  networkId <- bchConfigNetworkId <$> gets bchConfig
  mOuts <- sequence <$> mapM (getTxOut . P.txInRef) ins
  pure $ fmap (toUtxo networkId . zip ins) mOuts
  where
    ins = S.toList $ P.txInputs tx
    outs = zip [0 ..] $ P.txOutputs tx

    fromOutTxOut networkId (ix, tout) = do
      cin <- Cardano.toCardanoTxIn $ TxOutRef tid ix
      cout <-
        fmap toCtxUTxOTxOut $
          Cardano.TxOut
            <$> Cardano.toCardanoAddress networkId (txOutAddress tout)
            <*> toCardanoTxOutValue (txOutValue tout)
            <*> pure
              ( fromMaybe Cardano.TxOutDatumNone $ do
                  dh <- txOutDatumHash tout
                  dat <- M.lookup dh (P.txData tx)
                  pure $ Cardano.TxOutDatum Cardano.ScriptDataInAlonzoEra (toScriptData dat)
              )
      pure (cin, cout)

    fromTxOut networkId (tin, tout) = do
      cin <- Cardano.toCardanoTxIn $ P.txInRef tin
      cout <- fmap toCtxUTxOTxOut $ Cardano.toCardanoTxOut networkId (P.txData tx) tout
      pure (cin, cout)

    toUtxo :: NetworkId -> [(TxIn, TxOut)] -> Either Cardano.ToCardanoError (UTxO AlonzoEra)
    toUtxo networkId xs = UTxO . M.fromList <$> (mappend <$> mapM (fromTxOut networkId) xs <*> mapM (fromOutTxOut networkId) outs)

toScriptData :: ToData a => a -> Cardano.ScriptData
toScriptData d = fromAlonzoData $ Alonzo.Data $ toData d

toCardanoTxOutValue :: Value -> Either Cardano.ToCardanoError (Cardano.TxOutValue Cardano.AlonzoEra)
toCardanoTxOutValue value = do
  when (Ada.fromValue value == mempty) (Left Cardano.OutputHasZeroAda)
  Cardano.TxOutValue Cardano.MultiAssetInAlonzoEra <$> Cardano.toCardanoValue value

-- | Reads TxOut by its reference.
getTxOut :: TxOutRef -> Run (Maybe TxOut)
getTxOut ref = M.lookup ref <$> gets bchUtxos

bumpSlot :: Run ()
bumpSlot = modify' $ \s -> s {bchCurrentSlot = bchCurrentSlot s + 1}

-- | Makes slot counter of blockchain to move forward on given amount.
waitNSlots :: Slot -> Run ()
waitNSlots n = modify' $ \s -> s {bchCurrentSlot = bchCurrentSlot s + n}

-- | Applies valid TX to modify blockchain.
applyTx :: Stat -> TxId -> Tx -> Run ()
applyTx stat tid etx@(Tx extra P.Tx {..}) = do
  updateUtxos
  updateRewards
  updateCertificates
  updateFees
  saveTx
  saveDatums
  where
    saveDatums = modify' $ \s -> s {bchDatums = txData <> bchDatums s}

    saveTx = do
      t <- gets bchCurrentSlot
      statPercent <- getStatPercent
      modify' $ \s -> s {bchTxs = appendLog t (TxStat etx t stat statPercent) $ bchTxs s}

    getStatPercent = do
      maxLimits <- gets (bchConfigLimitStats . bchConfig)
      pure $ toStatPercent maxLimits stat

    updateUtxos = do
      removeIns txInputs
      mapM_ insertOut $ zip [0 ..] txOutputs

    removeIns ins = modify $ \s ->
      s
        { bchUtxos = rmIns (bchUtxos s)
        , bchAddresses = fmap (`S.difference` inRefSet) (bchAddresses s)
        }
      where
        inRefSet = S.map P.txInRef ins
        inRefs = M.fromList $ (,()) . P.txInRef <$> S.toList ins
        rmIns a = M.difference a inRefs

    insertOut (ix, out) = do
      insertAddresses
      insertUtxos
      where
        ref = TxOutRef tid ix
        addr = txOutAddress out

        insertAddresses = modify' $ \s -> s {bchAddresses = M.alter (Just . maybe (S.singleton ref) (S.insert ref)) addr $ bchAddresses s}
        insertUtxos = modify' $ \s -> s {bchUtxos = M.singleton ref out <> bchUtxos s}

    updateRewards = mapM_ modifyWithdraw $ extra'withdraws extra
      where
        modifyWithdraw Withdraw {..} = onStake (withdrawStake withdraw'credential)

    updateCertificates = mapM_ (onStake . reactDCert . certificate'dcert) $ extra'certificates extra

    onStake f = modify' $ \st -> st {bchStake = f $ bchStake st}

    updateFees = do
      st <- gets bchStake
      forM_ (rewardStake amount st) $ \nextSt -> modify' $ \bch -> bch {bchStake = nextSt}
      where
        amount = valueOf txFee adaSymbol adaToken

-- | Read all TxOutRefs that belong to given address.
txOutRefAt :: Address -> Run [TxOutRef]
txOutRefAt addr = txOutRefAtState addr <$> get

-- | Read all TxOutRefs that belong to given address.
txOutRefAtState :: Address -> Blockchain -> [TxOutRef]
txOutRefAtState addr st = maybe [] S.toList . M.lookup addr $ bchAddresses st

-- | Get all UTXOs that belong to an address
utxoAt :: HasAddress user => user -> Run [(TxOutRef, TxOut)]
utxoAt addr = utxoAtState addr <$> get

-- | Get all UTXOs that belong to an address
utxoAtState :: HasAddress user => user -> Blockchain -> [(TxOutRef, TxOut)]
utxoAtState (toAddress -> addr) st =
  mapMaybe (\r -> (r,) <$> M.lookup r (bchUtxos st)) refs
  where
    refs = txOutRefAtState addr st

-- | Reads typed datum from blockchain that belongs to UTXO (by reference).
datumAt :: FromData a => TxOutRef -> Run (Maybe a)
datumAt ref = do
  dhs <- gets bchDatums
  mDh <- (txOutDatumHash =<<) <$> getTxOut ref
  pure $ fromBuiltinData . getDatum =<< (`M.lookup` dhs) =<< mDh

-- | Reads current reward amount for a staking credential
rewardAt :: HasStakingCredential cred => cred -> Run Integer
rewardAt cred = gets (maybe 0 id . lookupReward (toStakingCredential cred) . bchStake)

-- | Returns all stakes delegatged to a pool
stakesAt :: PoolId -> Run [StakingCredential]
stakesAt (PoolId poolKey) = gets (lookupStakes (PoolId poolKey) . bchStake)

-- | Checks that pool is registered
hasPool :: PoolId -> Run Bool
hasPool (PoolId pkh) = gets (M.member (PoolId pkh) . stake'pools . bchStake)

-- | Checks that staking credential is registered
hasStake :: HasStakingCredential a => a -> Run Bool
hasStake key = gets (M.member (toStakingCredential key) . stake'stakes . bchStake)

getPools :: Run [PoolId]
getPools = gets (V.toList . stake'poolIds . bchStake)

---------------------------------------------------------------------
-- stat resources limits (Alonzo era)

-- | Limits for TX-execution resources on Mainnet (Alonzo)
mainnetTxLimits :: Stat
mainnetTxLimits =
  Stat
    { statSize = 16 * 1024
    , statExecutionUnits =
        ExecutionUnits
          { executionMemory = 14_000_000
          , executionSteps = 10_000_000_000
          }
    }

-- | Limits for Block-execution resources resources on Mainnet
mainnetBlockLimits :: Stat
mainnetBlockLimits =
  Stat
    { statSize = 65 * 1024
    , statExecutionUnits =
        ExecutionUnits
          { executionMemory = 50_000_000
          , executionSteps = 40_000_000_000
          }
    }

-- | Limits for TX-execution resources resources on Testnet
testnetTxLimits :: Stat
testnetTxLimits = mainnetTxLimits

-- | Limits for Block-execution resources resources on Testnet
testnetBlockLimits :: Stat
testnetBlockLimits = mainnetBlockLimits

----------------------------------------------------------------
-- logs

-- | Blockchain events to log.
data BchEvent
  = -- | Sucessful TXs
    BchTx TxStat
  | -- | Info messages
    BchInfo String
  | -- | Errors
    BchFail FailReason
  | -- | Expected errors, see 'mustFail'
    BchMustFailLog MustFailLog

-- | Skip all info messages
silentLog :: Log BchEvent -> Log BchEvent
silentLog (Log xs) = Log $ Seq.filter (not . isInfo . snd) xs
  where
    isInfo = \case
      BchInfo _ -> True
      _ -> False

-- | Skip successful TXs
failLog :: Log BchEvent -> Log BchEvent
failLog (Log xs) = Log $ Seq.filter (not . isTx . snd) xs
  where
    isTx = \case
      BchTx _ -> True
      _ -> False

-- | filter by slot. Can be useful to filter out unnecessary info.
filterSlot :: (Slot -> Bool) -> Log a -> Log a
filterSlot f (Log xs) = Log (Seq.filter (f . fst) xs)

-- | Reads the log.
getLog :: Blockchain -> Log BchEvent
getLog Blockchain {..} =
  mconcat [BchInfo <$> bchInfo, BchMustFailLog <$> mustFailLog, BchTx <$> bchTxs, BchFail <$> bchFails]
