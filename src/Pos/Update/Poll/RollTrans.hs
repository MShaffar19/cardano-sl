{-# LANGUAGE Rank2Types #-}
-- | Proxy transformer for tracking updates for
-- rollback. Single-threaded.

module Pos.Update.Poll.RollTrans
       ( RollT (..)
       , runRollT
       , execRollT
       ) where

import           Control.Lens              ((%=), (.=))
import           Control.Monad.Except      (MonadError (..))
import           Control.Monad.Trans.Class (MonadTrans)
import           Data.Default              (def)
import qualified Data.HashMap.Strict       as HM
import           Universum

import           Pos.Crypto                (hash)

import           Pos.Types.Version         (SoftwareVersion (..))
import           Pos.Update.Poll.Class     (MonadPoll (..), MonadPollRead (..))
import           Pos.Update.Poll.Types     (PrevValue, USUndo (..), maybeToPrev,
                                            psProposal, unChangedBVL, unChangedPropsL,
                                            unChangedSVL, unLastAdoptedBVL)

newtype RollT m a = RollT
    { getRollT :: StateT USUndo m a
    } deriving (Functor, Applicative, Monad, MonadThrow, MonadTrans, MonadError e)

instance MonadPollRead m => MonadPollRead (RollT m)

whenNothingM :: Monad m => m (Maybe a) -> m () -> m () -- dratuti
whenNothingM mb action = mb >>= \case
    Nothing -> action
    Just _  -> pass

-- | Monad transformer which stores USUndo and implements writable
-- MonadPoll. Its purpose is to collect data necessary for rollback.
--
-- [WARNING] This transformer uses StateT and is intended for
-- single-threaded usage only.
instance MonadPoll m => MonadPoll (RollT m) where
    -- only one time can be called
    putBVState bv sv = RollT $ do
        insertIfNotExist bv unChangedBVL getBVState
        putBVState bv sv

    delBVState bv = RollT $ do
        insertIfNotExist bv unChangedBVL getBVState
        delBVState bv

    setLastAdoptedBV pv = RollT $ do
        prevBV <- getLastAdoptedBV
        whenNothingM (use unLastAdoptedBVL) $
            unLastAdoptedBVL .= Just prevBV
        setLastAdoptedBV pv

    setLastConfirmedSV sv@SoftwareVersion{..} = RollT $ do
        insertIfNotExist svAppName unChangedSVL getLastConfirmedSV
        setLastConfirmedSV sv

    -- can't be called by applying
    delConfirmedSV = lift . delConfirmedSV

    -- can't be rolled back
    addConfirmedProposal = lift . addConfirmedProposal

    addActiveProposal ps = RollT $ do
        insertIfNotExist (hash $ psProposal $ ps) unChangedPropsL getProposal
        addActiveProposal ps

    deactivateProposal id = RollT $ do
        insertIfNotExist id unChangedPropsL getProposal
        deactivateProposal id

insertIfNotExist
    :: (Eq a, Hashable a, MonadState USUndo m)
    => a
    -> Lens' USUndo (HashMap a (PrevValue b))
    -> (a -> m (Maybe b))
    -> m ()
insertIfNotExist id setter getter = do
    res <- HM.lookup id <$> use setter
    case res of
        Nothing -> do
            prev <- getter id
            setter %= HM.insert id (maybeToPrev prev)
        Just _  -> pass

runRollT :: RollT m a -> m (a, USUndo)
runRollT = flip runStateT def . getRollT

execRollT :: Monad m => RollT m a -> m USUndo
execRollT = flip execStateT def . getRollT