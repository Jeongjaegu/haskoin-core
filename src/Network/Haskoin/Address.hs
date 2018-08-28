{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}
module Network.Haskoin.Address
    ( -- * Address
      Address(..)
    , addrToString
    , stringToAddr
    , addrFromJSON
    , pubKeyAddr
      -- ** Wallet Import Format (WIF)
    , fromWif
    , toWif
    ) where

import           Control.Applicative
import           Control.DeepSeq
import           Control.Monad
import qualified Crypto.Secp256k1                 as EC
import           Data.Aeson                       as A
import           Data.Aeson.Types
import qualified Data.Array                       as Arr
import           Data.Bits
import           Data.ByteString                  (ByteString)
import qualified Data.ByteString                  as B
import qualified Data.ByteString.Char8            as C
import           Data.Char
import           Data.Function
import           Data.List
import           Data.Maybe
import           Data.Serialize                   as S
import           Data.String
import           Data.String.Conversions
import           Data.Word
import           GHC.Generics                     as G (Generic)
import           Network.Haskoin.Address.Base58
import           Network.Haskoin.Address.Bech32
import           Network.Haskoin.Address.CashAddr
import           Network.Haskoin.Constants
import           Network.Haskoin.Crypto
import           Network.Haskoin.Keys.Types
import           Network.Haskoin.Util
import           Text.Read                        as R

data Address
    = PubKeyAddress { getAddrHash160 :: !Hash160
                    , getAddrNet     :: !Network }
    | ScriptAddress { getAddrHash160 :: !Hash160
                    , getAddrNet     :: !Network }
    | WitnessPubKeyAddress { getAddrHash160 :: !Hash160
                           , getAddrNet     :: !Network }
    | WitnessScriptAddress { getAddrHash256 :: !Hash256
                           , getAddrNet     :: !Network }
    deriving (Eq, G.Generic)

instance Ord Address where
    compare = compare `on` f
      where
        f (PubKeyAddress h _)        = S.encode h
        f (ScriptAddress h _)        = S.encode h
        f (WitnessPubKeyAddress h _) = S.encode h
        f (WitnessScriptAddress h _) = S.encode h

instance NFData Address

base58get :: Network -> Get Address
base58get net = do
    pfx <- getWord8
    addr <- S.get
    f pfx addr
  where
    f x a
        | x == getAddrPrefix net = return (PubKeyAddress a net)
        | x == getScriptPrefix net = return (ScriptAddress a net)
        | otherwise = fail "Does not recognize address prefix"

base58put :: Putter Address
base58put (PubKeyAddress h net) = do
        putWord8 (getAddrPrefix net)
        put h
base58put (ScriptAddress h net) = do
        putWord8 (getScriptPrefix net)
        put h

instance Show Address where
    showsPrec d a =
        case addrToString a of
            Just s  -> shows s
            Nothing -> showString "InvalidAddress"

instance ToJSON Address where
    toJSON =
        A.String .
        cs . fromMaybe (error "Could not encode address") . addrToString

addrFromJSON :: Network -> Value -> Parser Address
addrFromJSON net =
    withText "address" $ \t ->
        case stringToAddr net (cs t) of
            Nothing -> fail "could not decode address"
            Just x  -> return x

addrToString :: Address -> Maybe ByteString
addrToString a@PubKeyAddress {getAddrHash160 = h, getAddrNet = net}
    | isNothing (getCashAddrPrefix net) =
        return $ encodeBase58Check $ runPut $ base58put a
    | otherwise = cashAddrEncode net 0 (S.encode h)
addrToString a@ScriptAddress {getAddrHash160 = h, getAddrNet = net}
    | isNothing (getCashAddrPrefix net) =
        return $ encodeBase58Check $ runPut $ base58put a
    | otherwise = cashAddrEncode net 1 (S.encode h)
addrToString WitnessPubKeyAddress {getAddrHash160 = h, getAddrNet = net} = do
    hrp <- (getBech32Prefix net)
    segwitEncode hrp 0 (B.unpack (S.encode h))
addrToString WitnessScriptAddress {getAddrHash256 = h, getAddrNet = net} = do
    hrp <- (getBech32Prefix net)
    segwitEncode hrp 0 (B.unpack (S.encode h))

stringToAddr :: Network -> ByteString -> Maybe Address
stringToAddr net bs = cash <|> segwit <|> b58
  where
    b58 = eitherToMaybe . runGet (base58get net) =<< decodeBase58Check bs
    cash = cashAddrDecode net bs >>= \(ver, bs') -> case ver of
        0 -> do
            h <- eitherToMaybe (S.decode bs')
            return $ PubKeyAddress h net
        1 -> do
            h <- eitherToMaybe (S.decode bs')
            return $ ScriptAddress h net
    segwit = do
        hrp <- getBech32Prefix net
        (ver, bs') <- segwitDecode hrp bs
        guard (ver == 0)
        let bs'' = B.pack bs'
        case B.length bs'' of
            20 -> do
                h <- eitherToMaybe (S.decode bs'')
                return $ WitnessPubKeyAddress h net
            32 -> do
                h <- eitherToMaybe (S.decode bs'')
                return $ WitnessScriptAddress h net
            _ -> Nothing

pubKeyAddr :: Serialize (PubKeyI c) => Network -> PubKeyI c -> Address
pubKeyAddr net k = PubKeyAddress (addressHash (S.encode k)) net

fromWif :: Network -> ByteString -> Maybe PrvKey
fromWif net wif = do
    bs <- decodeBase58Check wif
    -- Check that this is a private key
    guard (B.head bs == getSecretPrefix net)
    case B.length bs of
        -- Uncompressed format
        33 -> makePrvKeyG False <$> EC.secKey (B.tail bs)
        -- Compressed format
        34 -> do
            guard $ B.last bs == 0x01
            makePrvKeyG True <$> EC.secKey (B.tail $ B.init bs)
        -- Bad length
        _  -> Nothing

toWif :: Network -> PrvKeyI c -> ByteString
toWif net (PrvKeyI k c) =
    encodeBase58Check . B.cons (getSecretPrefix net) $
    if c
        then EC.getSecKey k `B.snoc` 0x01
        else EC.getSecKey k
