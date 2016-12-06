{-# LANGUAGE AllowAmbiguousTypes       #-}
{-# LANGUAGE DefaultSignatures         #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE GADTs                     #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE Rank2Types                #-}
{-# LANGUAGE TypeFamilies              #-}
{-# LANGUAGE UndecidableInstances      #-}

-- |
-- Module      : Control.TimeWarp.Rpc.MonadTransfer
-- Copyright   : (c) Serokell, 2016
-- License     : GPL-3 (see the file LICENSE)
-- Maintainer  : Serokell <hi@serokell.io>
-- Stability   : experimental
-- Portability : POSIX, GHC
--
-- This module defines monad, which serves for sending and receiving raw byte streams.
--
-- UPGRAGE-NOTE (TW-47):
-- We'd like to have another interface for `listenRaw` function.
-- Currently it allows only single listener for given connection.
-- It makes difficult to define, for example, a listener for all outbound connections,
-- which is likely to have.
-- There is a proposal to have subscriptions-based interface:
--
--   * `listenRaw` is in some sense automatically applied when connection is created
--
--   * At `Dialog` layer, add `subscribe` function which allows to listen for messages at
--       specified port / specified outbound connection / sum of them.

module Control.TimeWarp.Rpc.MonadTransfer
       ( -- * Related datatypes
         Port
       , Host
       , NetworkAddress
       , Binding (..)
       , localhost
       , commLoggerName
       , commLog

       -- * MonadTransfer
       , MonadTransfer (..)

       -- * MonadResponse
       , MonadResponse (..)
       , ResponseContext (..)
       , ResponseT (..)
       , runResponseT
       , mapResponseT
       , hoistRespCond
       ) where

import           Control.Lens                (view)
import           Control.Monad.Catch         (MonadCatch, MonadMask, MonadThrow)
import           Control.Monad.Morph         (hoist)
import           Control.Monad.Reader        (MonadReader (..), ReaderT (..), mapReaderT)
import           Control.Monad.State         (MonadState)
import           Control.Monad.Trans         (MonadIO (..), MonadTrans (..))
import           Control.Monad.Trans.Control (MonadTransControl (..))
import           Data.ByteString             (ByteString)
import           Data.Conduit                (ConduitM, Producer, Sink, Source)
import           Data.Monoid                 ((<>))
import           Data.Text                   (Text)
import           Data.Word                   (Word16)
import           System.Wlog                 (CanLog, HasLoggerName, LoggerName,
                                              LoggerNameBox (..), WithLogger,
                                              modifyLoggerName)

import           Serokell.Util.Lens          (WrappedM (..), _UnwrappedM)

import           Control.TimeWarp.Timed      (MonadTimed, ThreadId)


-- * Related datatypes

-- | Port number.
type Port = Word16

-- | Host address.
type Host = ByteString

-- | @"127.0.0.1"@.
localhost :: Host
localhost = "127.0.0.1"

-- | Full node address.
type NetworkAddress = (Host, Port)

-- | Name of logger responsible for communication events - @comm@.
-- TODO: Make non-hardcoded.
commLoggerName :: LoggerName
commLoggerName = "comm"

-- | Appends `commLoggerName` as suffix to current logger name.
commLog :: HasLoggerName m => m a -> m a
commLog = modifyLoggerName (<> commLoggerName)

-- | Specifies type of `listen` binding.
--
-- UPGRADE-NOTE: adding /Loopback/ binding may be useful.
data Binding
    = AtPort Port              -- ^ Listen at port
    | AtConnTo NetworkAddress  -- ^ Listen at connection established earlier
    deriving (Eq, Ord, Show)


-- * MonadTransfer

-- | Allows to send/receive raw byte sequences.
class Monad m => MonadTransfer m where
    -- | Sends raw data.
    -- When invoked several times for same address, this function is expected to
    -- use same connection kept under hood.
    -- Byte sequence, produced by given source, will be transmitted as a whole;
    sendRaw :: NetworkAddress       -- ^ Destination address
            -> Source m ByteString  -- ^ Data to send
            -> m ()
    default sendRaw :: (WrappedM m, MonadTransfer (UnwrappedM m))
                    => NetworkAddress -> Source m ByteString -> m ()
    sendRaw addr req = view _UnwrappedM $
        sendRaw addr $ view _WrappedM `hoist` req

    -- | Listens at specified input or output connection.
    -- Returns server stopper, which blocks current thread until server is actually
    -- stopped.
    -- Calling this function in case there is defined listener already for this
    -- connection should lead to error.
    listenRaw :: Binding                           -- ^ Port/address to listen to
              -> Sink ByteString (ResponseT m) ()  -- ^ Parser for input byte stream
              -> m (m ())                          -- ^ Server stopper
    default listenRaw :: (WrappedM m, MonadTransfer (UnwrappedM m))
                      => Binding -> Sink ByteString (ResponseT m) () -> m (m ())
    listenRaw binding sink = view _UnwrappedM $ fmap (view _UnwrappedM) $
            listenRaw binding $ view _WrappedM `hoistRespCond` sink

    -- | Closes outbound connection to specified node, if exists.
    -- To close inbound connections, use `closeR`.
    close :: NetworkAddress -> m ()
    default close :: (WrappedM m, MonadTransfer (UnwrappedM m))
                  => NetworkAddress -> m ()
    close = view _UnwrappedM . close


-- * MonadResponse

-- | Provides operations related to /peer/ node. Peer is a node, which this node is
-- currently communicating with.
class Monad m => MonadResponse m where
    -- | Sends data to peer.
    replyRaw :: Producer m ByteString -> m ()

    -- | Closes connection with peer.
    closeR :: m ()

    -- | Gets address of peer, for debugging purposes only.
    peerAddr :: m Text

-- | Keeps information about peer.
data ResponseContext = ResponseContext
    { respSend     :: forall m . (MonadIO m, MonadMask m, WithLogger m)
                   => Source m ByteString -> m ()
    , respClose    :: IO ()
    , respPeerAddr :: Text
    }

-- | Default implementation of `MonadResponse`.
newtype ResponseT m a = ResponseT
    { getResponseT :: ReaderT ResponseContext m a
    } deriving (Functor, Applicative, Monad, MonadIO, MonadTrans,
                MonadThrow, MonadCatch, MonadMask,
                MonadState s, CanLog,
                HasLoggerName, MonadTimed)

-- | Unwrappes `ResponseT`.
runResponseT :: ResponseT m a -> ResponseContext -> m a
runResponseT = runReaderT . getResponseT

type instance ThreadId (ResponseT m) = ThreadId m

instance MonadReader r m => MonadReader r (ResponseT m) where
    ask = lift ask
    reader f = lift $ reader f
    local = mapResponseT . local

instance MonadTransfer m => MonadTransfer (ResponseT m) where
    sendRaw addr src = ResponseT ask >>=
        \ctx -> lift $ sendRaw addr (hoist (`runResponseT` ctx) src)
    listenRaw binding sink =
        fmap ResponseT $ ResponseT $ listenRaw binding $ hoistRespCond getResponseT sink
    close addr = lift $ close addr

instance (MonadIO m, MonadMask m, WithLogger m)
         => MonadResponse (ResponseT m) where
    replyRaw dat = ResponseT ask >>= \ctx -> respSend ctx dat

    closeR = ResponseT $ ask >>= liftIO . respClose

    peerAddr = respPeerAddr <$> ResponseT ask

-- | Maps entry of `ResponseT`.
-- TODO: implement `hoist` instead, it should be enough.
{-# INLINE mapResponseT #-}
mapResponseT :: (m a -> n b) -> ResponseT m a -> ResponseT n b
mapResponseT how = ResponseT . mapReaderT how . getResponseT


-- * Instances

-- | Allows to modify entry of @Conduit i o (ResponseT m) r@.
hoistRespCond :: Monad m
              => (forall a . m a -> n a)
              -> ConduitM i o (ResponseT m) r
              -> ConduitM i o (ResponseT n) r
hoistRespCond how = hoist $ mapResponseT how

instance MonadTransfer m => MonadTransfer (ReaderT r m) where
    sendRaw addr req = ask >>= \ctx -> lift $ sendRaw addr (hoist (`runReaderT` ctx) req)
    listenRaw binding sink =
        fmap lift $ liftWith $ \run -> listenRaw binding $ hoistRespCond run sink
    close = lift . close

instance MonadTransfer m => MonadTransfer (LoggerNameBox m) where

instance MonadResponse m => MonadResponse (ReaderT r m) where
    replyRaw dat = ask >>= \ctx -> lift $ replyRaw (hoist (`runReaderT` ctx) dat)
    closeR = lift closeR
    peerAddr = lift peerAddr
