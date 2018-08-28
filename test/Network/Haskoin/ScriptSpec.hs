{-# LANGUAGE OverloadedStrings #-}
module Network.Haskoin.ScriptSpec (spec) where

import           Control.Monad
import           Control.Monad.IO.Class
import qualified Crypto.Secp256k1            as EC
import           Data.Aeson                  as A
import           Data.ByteString             (ByteString)
import qualified Data.ByteString             as BS
import qualified Data.ByteString             as BS
import qualified Data.ByteString.Char8       as C
import qualified Data.ByteString.Lazy        as BL
import qualified Data.ByteString.Lazy.Char8  as CL
import           Data.Char                   (ord)
import           Data.Either
import           Data.Int                    (Int64)
import           Data.List
import           Data.List
import           Data.List.Split             (splitOn)
import           Data.Map.Strict             (singleton)
import           Data.Maybe
import           Data.Monoid                 ((<>))
import           Data.Serialize              as S
import           Data.String
import           Data.String.Conversions     (cs)
import           Data.Word
import           Data.Word
import           Network.Haskoin.Address
import           Network.Haskoin.Constants
import           Network.Haskoin.Crypto
import           Network.Haskoin.Keys
import           Network.Haskoin.Script
import           Network.Haskoin.Test
import           Network.Haskoin.Transaction
import           Network.Haskoin.Util
import           Numeric                     (readHex)
import           Test.Hspec
import           Test.HUnit                  as HUnit
import           Test.QuickCheck
import           Text.Read

spec :: Spec
spec = do
    let net = btc
    describe "btc scripts" $ props btc
    describe "bch scripts" $ props bch
    describe "integer types" $ do
        it "decodeInt . encodeInt Int" $ property testEncodeInt
        it "decodeFullInt . encodeInt Int" $ property testEncodeInt64
        it "cltvDecodeInt . encodeInt Int" $ property testEncodeCltv
        it "decodeBool . encodeBool Bool" $ property testEncodeBool
    describe "script file tests" $ do
        it "runs all canonical valid scripts" $
            testFile "data/script_valid.json" True
        it "runs all canonical invalid scripts" $
            testFile "data/script_invalid.json" False
    describe "multi signatures" $
        sequence_ $ zipWith (curry mapMulSigVector) mulSigVectors [0 ..]
    describe "signature decoding" $
        sequence_ $ zipWith (curry sigDecodeMap) scriptSigSignatures [0 ..]
    describe "json serialization" $ do
        it "encodes and decodes script output" $
            forAll (arbitraryScriptOutput net) testID
        it "encodes and decodes outpoint" $ forAll arbitraryOutPoint testID
        it "encodes and decodes sighash" $ forAll arbitrarySigHash testID
        it "encodes and decodes siginput" $
            forAll (arbitrarySigInput net) (testID . fst)
    describe "script serialization" $ do
        it "encodes and decodes script op" $
            property $ forAll arbitraryScriptOp cerealID
        it "encodes and decodes script" $
            property $ forAll arbitraryScript cerealID

props :: Network -> Spec
props net = do
    standardSpec net
    strictSigSpec net
    scriptSpec net
    txSigHashForkIdSpec net
    forkIdScriptSpec net
    sigHashSpec net
    txSigHashSpec net

cerealID :: (Serialize a, Eq a) => a -> Bool
cerealID x = S.decode (S.encode x) == Right x

standardSpec :: Network -> Spec
standardSpec net = do
    it "has intToScriptOp . scriptOpToInt identity" $
        property $
        forAll arbitraryIntScriptOp $ \i ->
            intToScriptOp <$> scriptOpToInt i `shouldBe` Right i
    it "has decodeOutput . encodeOutput identity" $
        property $
        forAll (arbitraryScriptOutput net) $ \so ->
            decodeOutput (encodeOutput so) `shouldBe` Right so
    it "has decodeInput . encodeOutput identity" $
        property $
        forAll arbitraryScriptInput $ \si ->
            decodeInput net (encodeInput si) `shouldBe` Right si
    it "can sort multisig scripts" $
        forAll arbitraryMSOutput $ \out ->
            map S.encode (getOutputMulSigKeys (sortMulSig out)) `shouldSatisfy` \xs ->
                xs == sort xs
    it "can decode inputs with empty signatures" $ do
        decodeInput net (Script [OP_0]) `shouldBe`
            Right (RegularInput (SpendPK TxSignatureEmpty))
        decodeInput net (Script [opPushData ""]) `shouldBe`
            Right (RegularInput (SpendPK TxSignatureEmpty))
        let pk =
                derivePubKey $
                makePrvKey $ fromJust $ EC.secKey $ BS.replicate 32 1
        decodeInput net (Script [OP_0, opPushData $ S.encode pk]) `shouldBe`
            Right (RegularInput (SpendPKHash TxSignatureEmpty pk))
        decodeInput net (Script [OP_0, OP_0]) `shouldBe`
            Right (RegularInput (SpendMulSig [TxSignatureEmpty]))
        decodeInput net (Script [OP_0, OP_0, OP_0, OP_0]) `shouldBe`
            Right (RegularInput (SpendMulSig $ replicate 3 TxSignatureEmpty))

scriptSpec :: Network -> Spec
scriptSpec net =
    when (getNetworkName net == "btc") $
    it "can verify standard scripts from script_tests.json file" $ do
        xs <- readTestFile "script_tests" :: IO [A.Value]
        let vectorsA =
                mapMaybe (A.decode . A.encode) xs :: [( String
                                                      , String
                                                      , String
                                                      , String
                                                      , String)]
            vectorsB =
                mapMaybe (A.decode . A.encode) xs :: [( [Word64]
                                                      , String
                                                      , String
                                                      , String
                                                      , String
                                                      , String)]
            vectors =
                map (\(a, b, c, d, e) -> ([0], a, b, c, d, e)) vectorsA <>
                vectorsB
        length vectors `shouldBe` 86
        forM_ vectors $ \([val], siStr, soStr, flags, res, _)
          -- We can disable specific tests by adding a DISABLED flag in the data
         ->
            unless ("DISABLED" `isInfixOf` flags) $ do
                let strict =
                        "DERSIG" `isInfixOf` flags ||
                        "STRICTENC" `isInfixOf` flags ||
                        "NULLDUMMY" `isInfixOf` flags
                    scriptSig = parseScript siStr
                    scriptPubKey = parseScript soStr
                    decodedOutput =
                        fromRight (error $ "Could not decode output: " <> soStr) $
                        decodeOutputBS scriptPubKey
                    ver =
                        verifyStdInput
                            net
                            strict
                            (spendTx scriptPubKey 0 scriptSig)
                            0
                            decodedOutput
                            (val * 100000000)
                case res of
                    "OK" -> ver `shouldBe` True
                    _    -> ver `shouldBe` False

forkIdScriptSpec :: Network -> Spec
forkIdScriptSpec net =
    when (isJust (getSigHashForkId net)) $
    it "can verify scripts from forkid_script_tests.json file" $ do
        xs <- readTestFile "forkid_script_tests" :: IO [A.Value]
        let vectors =
                mapMaybe (A.decode . A.encode) xs :: [( [Word64]
                                                      , String
                                                      , String
                                                      , String
                                                      , String
                                                      , String)]
        length vectors `shouldBe` 3
        forM_ vectors $ \([valBTC], siStr, soStr, _, res, _) -> do
            let val = valBTC * 100000000
                scriptSig = parseScript siStr
                scriptPubKey = parseScript soStr
                decodedOutput =
                    fromRight (error $ "Could not decode output: " <> soStr) $
                    decodeOutputBS scriptPubKey
                ver =
                    verifyStdInput
                        net
                        True -- Always strict
                        (spendTx scriptPubKey val scriptSig)
                        0
                        decodedOutput
                        val
            case res of
                "OK" -> ver `shouldBe` True
                _    -> ver `shouldBe` False

creditTx :: BS.ByteString -> Word64 -> Tx
creditTx scriptPubKey val =
    Tx 1 [txI] [txO] [] 0
  where
    txO = TxOut {outValue = val, scriptOutput = scriptPubKey}
    txI =
        TxIn
        { prevOutput = nullOutPoint
        , scriptInput = S.encode $ Script [OP_0, OP_0]
        , txInSequence = maxBound
        }

spendTx :: BS.ByteString -> Word64 -> BS.ByteString -> Tx
spendTx scriptPubKey val scriptSig =
    Tx 1 [txI] [txO] [] 0
  where
    txO = TxOut {outValue = val, scriptOutput = BS.empty}
    txI =
        TxIn
        { prevOutput = OutPoint (txHash $ creditTx scriptPubKey val) 0
        , scriptInput = scriptSig
        , txInSequence = maxBound
        }

parseScript :: String -> BS.ByteString
parseScript str =
    BS.concat $ fromMaybe err $ mapM f $ words str
  where
    f = decodeHex . cs . dropHex . replaceToken
    dropHex ('0':'x':xs) = xs
    dropHex xs           = xs
    err = error $ "Could not decode script: " <> str

replaceToken :: String -> String
replaceToken str = case readMaybe $ "OP_" <> str of
    Just opcode -> "0x" <> cs (encodeHex $ S.encode (opcode :: ScriptOp))
    _           -> str

strictSigSpec :: Network -> Spec
strictSigSpec net =
    when (getNetworkName net == "btc") $ do
        it "can decode strict signatures" $ do
            xs <- readTestFile "sig_strict"
            let vectors = mapMaybe (decodeHex . cs) (xs :: [String])
            length vectors `shouldBe` 3
            forM_ vectors $ \sig ->
                decodeTxStrictSig net sig `shouldSatisfy` isRight
        it "can detect non-strict signatures" $ do
            xs <- readTestFile "sig_nonstrict"
            let vectors = mapMaybe (decodeHex . cs) (xs :: [String])
            length vectors `shouldBe` 17
            forM_ vectors $ \sig ->
                decodeTxStrictSig net sig `shouldSatisfy` isLeft

txSigHashSpec :: Network -> Spec
txSigHashSpec net =
    when (getNetworkName net == "btc") $
    it "can produce valid sighashes from sighash.json test vectors" $ do
        xs <- readTestFile "sighash" :: IO [A.Value]
        let vectors =
                mapMaybe (A.decode . A.encode) xs :: [( String
                                                      , String
                                                      , Int
                                                      , Integer
                                                      , String)]
        length vectors `shouldBe` 500
        forM_ vectors $ \(txStr, scpStr, i, shI, resStr) -> do
            let tx = fromString txStr
                s =
                    fromMaybe (error $ "Could not decode script: " <> cs scpStr) $
                    eitherToMaybe . S.decode =<< decodeHex (cs scpStr)
                sh = fromIntegral shI
                res =
                    eitherToMaybe . S.decode . BS.reverse =<<
                    decodeHex (cs resStr)
            Just (txSigHash net tx s 0 i sh) `shouldBe` res

txSigHashForkIdSpec :: Network -> Spec
txSigHashForkIdSpec net =
    when (getNetworkName net == "btc") $
    it "can produce valid sighashes from forkid_sighash.json test vectors" $ do
        xs <- readTestFile "forkid_sighash" :: IO [A.Value]
        let vectors =
                mapMaybe (A.decode . A.encode) xs :: [( String
                                                      , String
                                                      , Int
                                                      , Word64
                                                      , Integer
                                                      , String)]
        length vectors `shouldBe` 13
        forM_ vectors $ \(txStr, scpStr, i, val, shI, resStr) -> do
            let tx = fromString txStr
                s =
                    fromMaybe (error $ "Could not decode script: " <> cs scpStr) $
                    eitherToMaybe . S.decode =<< decodeHex (cs scpStr)
                sh = fromIntegral shI
                res = eitherToMaybe . S.decode =<< decodeHex (cs resStr)
            Just (txSigHashForkId net tx s val i sh) `shouldBe` res

sigHashSpec :: Network -> Spec
sigHashSpec net = do
    it "can read . show" $
        property $ forAll arbitrarySigHash $ \sh -> read (show sh) `shouldBe` sh
    it "can correctly show" $ do
        show (0x00 :: SigHash) `shouldBe` "SigHash " <> show 0x00
        show (0x01 :: SigHash) `shouldBe` "SigHash " <> show 0x01
        show (0xff :: SigHash) `shouldBe` "SigHash " <> show 0xff
        show (0xabac3344 :: SigHash) `shouldBe` "SigHash " <> show 0xabac3344
    it "can add a forkid" $ do
        0x00 `sigHashAddForkId` 0x00 `shouldBe` 0x00
        0xff `sigHashAddForkId` 0x00ffffff `shouldBe` 0xffffffff
        0xffff `sigHashAddForkId` 0x00aaaaaa `shouldBe` 0xaaaaaaff
        0xffff `sigHashAddForkId` 0xaaaaaaaa `shouldBe` 0xaaaaaaff
        0xffff `sigHashAddForkId` 0x00004444 `shouldBe` 0x004444ff
        0xff01 `sigHashAddForkId` 0x44440000 `shouldBe` 0x44000001
        0xff03 `sigHashAddForkId` 0x00550000 `shouldBe` 0x55000003
    it "can extract a forkid" $ do
        sigHashGetForkId 0x00000000 `shouldBe` 0x00000000
        sigHashGetForkId 0x80000000 `shouldBe` 0x00800000
        sigHashGetForkId 0xffffffff `shouldBe` 0x00ffffff
        sigHashGetForkId 0xabac3403 `shouldBe` 0x00abac34
    it "can build some vectors" $ do
        sigHashAll `shouldBe` 0x01
        sigHashNone `shouldBe` 0x02
        sigHashSingle `shouldBe` 0x03
        setForkIdFlag sigHashAll `shouldBe` 0x41
        setAnyoneCanPayFlag sigHashAll `shouldBe` 0x81
        setAnyoneCanPayFlag (setForkIdFlag sigHashAll) `shouldBe` 0xc1
    it "can test flags" $ do
        hasForkIdFlag sigHashAll `shouldBe` False
        hasForkIdFlag (setForkIdFlag sigHashAll) `shouldBe` True
        hasAnyoneCanPayFlag sigHashAll `shouldBe` False
        hasAnyoneCanPayFlag (setAnyoneCanPayFlag sigHashAll) `shouldBe` True
        isSigHashAll sigHashNone `shouldBe` False
        isSigHashAll sigHashAll `shouldBe` True
        isSigHashNone sigHashSingle `shouldBe` False
        isSigHashNone sigHashNone `shouldBe` True
        isSigHashSingle sigHashAll `shouldBe` False
        isSigHashSingle sigHashSingle `shouldBe` True
        isSigHashUnknown sigHashAll `shouldBe` False
        isSigHashUnknown sigHashNone `shouldBe` False
        isSigHashUnknown sigHashSingle `shouldBe` False
        isSigHashUnknown 0x00 `shouldBe` True
        isSigHashUnknown 0x04 `shouldBe` True
    it "can decodeTxLaxSig . encode a TxSignature" $
        property $
        forAll arbitraryTxSignature $ \(_, _, ts) ->
            decodeTxLaxSig (encodeTxSig ts) `shouldBe` Right ts
    when (getNetworkName net == "btc") $
        it "can decodeTxStrictSig . encode a TxSignature" $
        property $
        forAll arbitraryTxSignature $ \(_, _, ts@(TxSignature _ sh)) ->
            if isSigHashUnknown sh || hasForkIdFlag sh
                then decodeTxStrictSig net (encodeTxSig ts) `shouldSatisfy`
                     isLeft
                else decodeTxStrictSig net (encodeTxSig ts) `shouldBe` Right ts
    it "can produce the sighash one" $
        property $
        forAll (arbitraryTx net) $ forAll arbitraryScript . testSigHashOne net

testSigHashOne :: Network -> Tx -> Script -> Word64 -> Bool -> Property
testSigHashOne net tx s val acp =
    not (null $ txIn tx) ==>
    if length (txIn tx) > length (txOut tx)
        then res `shouldBe` one
        else res `shouldNotBe` one
  where
    res = txSigHash net tx s val (length (txIn tx) - 1) (f sigHashSingle)
    one = "0100000000000000000000000000000000000000000000000000000000000000"
    f =
        if acp
            then setAnyoneCanPayFlag
            else id

{-- Test Utilities --}

readTestFile :: A.FromJSON a => FilePath -> IO a
readTestFile fp = do
    bs <- BL.readFile $ "data/" <> fp <> ".json"
    maybe (error $ "Could not read test file " <> fp) return $ A.decode bs

{- Script Evaluation Primitives -}

testEncodeInt :: Int64 -> Bool
testEncodeInt i
    | i >  0x7fffffff = isNothing i'
    | i < -0x7fffffff = isNothing i'
    | otherwise       = i' == Just i
  where
    i' = decodeInt $ encodeInt i

testEncodeCltv :: Int64 -> Bool
testEncodeCltv i
    -- As 'cltvEncodeInt' is just a wrapper for 'encodeInt',
    -- we use 'encodeInt' for encoding, to simultaneously
    -- test the handling of out-of-range integers by 'cltvDecodeInt'.
    | i < 0 || i > fromIntegral (maxBound :: Word32) =
        isNothing $ cltvDecodeInt (encodeInt i)
    | otherwise =
        cltvDecodeInt (encodeInt i) == Just (fromIntegral i)

testEncodeInt64 :: Int64 -> Bool
testEncodeInt64 i = decodeFullInt (encodeInt i) == Just i

testEncodeBool :: Bool -> Bool
testEncodeBool b = decodeBool (encodeBool b) == b

{- Script Evaluation -}

rejectSignature :: SigCheck
rejectSignature _ _ _ = False

{- Parse tests from bitcoin-qt repository -}

type ParseError = String

parseHex' :: String -> Maybe [Word8]
parseHex' (a:b:xs) =
    case readHex [a, b] :: [(Integer, String)] of
        [(i, "")] ->
            case parseHex' xs of
                Just ops -> Just $ fromIntegral i : ops
                Nothing  -> Nothing
        _ -> Nothing
parseHex' [_] = Nothing
parseHex' [] = Just []

parseFlags :: String -> [ Flag ]
parseFlags "" = []
parseFlags s  = map read . splitOn "," $ s

parseScriptEither :: String -> Either ParseError Script
parseScriptEither scriptString = do
    bytes <- BS.pack <$> parseBytes scriptString
    script <- decodeScript bytes
    when (S.encode script /= bytes) $ Left "encode script /= bytes"
    when
        (fromRight (error "Could not decode script") (S.decode (S.encode script)) /=
         script) $
        Left "decode (encode script) /= script"
    return script
  where
    decodeScript bytes =
        case S.decode bytes of
            Left e           -> Left $ "decode error: " ++ e
            Right (Script s) -> Right $ Script s
    parseBytes :: String -> Either ParseError [Word8]
    parseBytes string = concat <$> mapM parseToken (words string)
    parseToken :: String -> Either ParseError [Word8]
    parseToken tok =
        case alternatives of
            (ops:_) -> Right ops
            _       -> Left $ "unknown token " ++ tok
      where
        alternatives :: [[Word8]]
        alternatives = catMaybes [parseHex, parseInt, parseQuote, parseOp]
        parseHex
            | "0x" `isPrefixOf` tok = parseHex' (drop 2 tok)
            | otherwise = Nothing
        parseInt = fromInt . fromIntegral <$> (readMaybe tok :: Maybe Integer)
        parseQuote
            | tok == "''" = Just [0]
            | head tok == '\'' && last tok == '\'' =
                Just $
                encodeBytes $
                opPushData $
                BS.pack $ map (fromIntegral . ord) $ init . tail $ tok
            | otherwise = Nothing
        fromInt :: Int64 -> [Word8]
        fromInt n
            | n == 0 = [0x00]
            | n == -1 = [0x4f]
            | 1 <= n && n <= 16 = [0x50 + fromIntegral n]
            | otherwise = encodeBytes $ opPushData $ BS.pack $ encodeInt n
        parseOp = encodeBytes <$> readMaybe ("OP_" ++ tok)
        encodeBytes = BS.unpack . S.encode

testFile :: String -> Bool -> Assertion
testFile path expected =
    do
        dat <- liftIO $ CL.readFile path
        case A.decode dat :: Maybe [[String]] of
            Nothing -> assertFailure $ "can't read test file " ++ path
            Just testDefs ->
                mapM_ parseTest $ filterPureComments testDefs
  where
    parseTest s =
        case testParts s of
            Nothing -> assertFailure $ "json element " ++ show s
            Just (sig, pubKey, flags, l) -> makeTest l sig pubKey flags
    makeTest l sig pubKey flags =
        case (parseScriptEither sig, parseScriptEither pubKey) of
            (Left e, _) ->
                parseError $ "can't parse sig: " ++ show sig ++ " error: " ++ e
            (_, Left e) ->
                parseError $
                "can't parse key: " ++ show pubKey ++ " error: " ++ e
            (Right scriptSig, Right scriptPubKey) ->
                runTest scriptSig scriptPubKey (parseFlags flags)
      where
        label' =
            if null l
                then "sig: [" ++ sig ++ "] " ++ " pubKey: [" ++ pubKey ++ "] "
                else " label: " ++ l
    parseError message =
        HUnit.assertBool
            ("parse error in valid script: " ++ message)
            (not expected)
    filterPureComments = filter (not . null . tail)
    runTest scriptSig scriptPubKey scriptFlags =
        HUnit.assertBool
            (" eval error: " ++ errorMessage)
            (expected == scriptPairTestExec scriptSig scriptPubKey scriptFlags)
      where
        run f = f scriptSig scriptPubKey rejectSignature scriptFlags
        errorMessage =
            case run execScript of
                Left e  -> show e
                Right _ -> " none"

-- | Splits the JSON test into the different parts.  No processing,
-- just handling the fact that comments may not be there or might have
-- junk before it.  Output is the tuple ( sig, pubKey, flags, comment
-- ) as strings
testParts :: [String] -> Maybe (String, String, String, String)
testParts l =
    let (x, r) = splitAt 3 l
        comment =
            if null r
                then ""
                else last r
    in if length x < 3
           then Nothing
           else let [sig, pubKey, flags] = x
                in Just (sig, pubKey, flags, comment)

-- | Maximum value of sequence number
maxSeqNum :: Word32
maxSeqNum = 0xffffffff -- Perhaps this should be moved to constants.

-- | Some of the scripts tests require transactions be built in a
-- standard way.  This function builds the crediting transaction.
-- Quoting the top comment of script_valid.json: "It is evaluated as
-- if there was a crediting coinbase transaction with two 0 pushes as
-- scriptSig, and one output of 0 satoshi and given scriptPubKey,
-- followed by a spending transaction which spends this output as only
-- input (and correct prevout hash), using the given scriptSig. All
-- nLockTimes are 0, all nSequences are max."
buildCreditTx :: ByteString -> Tx
buildCreditTx scriptPubKey =
    Tx 1 [ txI ] [ txO ] [] 0
  where
    txO = TxOut { outValue = 0
                , scriptOutput = scriptPubKey
                }
    txI = TxIn { prevOutput = nullOutPoint
               , scriptInput = S.encode $ Script [ OP_0, OP_0 ]
               , txInSequence = maxSeqNum
               }

-- | Build a spending transaction for the tests.  Takes as input the
-- crediting transaction
buildSpendTx :: ByteString  -- ScriptSig
             -> Tx          -- Creditting Tx
             -> Tx
buildSpendTx scriptSig creditTx =
    Tx 1 [ txI ] [ txO ] [] 0
  where
    txI = TxIn { prevOutput = OutPoint { outPointHash = txHash creditTx
                                       , outPointIndex = 0
                                       }
               , scriptInput  = scriptSig
               , txInSequence = maxSeqNum
               }
    txO = TxOut { outValue = 0, scriptOutput = BS.empty }

-- | Executes the test of a scriptSig, pubKeyScript pair, including
-- building the required transactions and verifying the spending
-- transaction.
scriptPairTestExec :: Script    -- scriptSig
                   -> Script    -- pubKey
                   -> [ Flag ] -- Evaluation flags
                   -> Bool
scriptPairTestExec scriptSig pubKey flags =
    let bsScriptSig = S.encode scriptSig
        bsPubKey = S.encode pubKey
        spendTx = buildSpendTx bsScriptSig (buildCreditTx bsPubKey)
    in verifySpend btc spendTx 0 pubKey 0 flags


mapMulSigVector :: ((ByteString, ByteString), Int) -> Spec
mapMulSigVector (v, i) =
    it name $ runMulSigVector v
  where
    name = "check multisig vector " <> show i

runMulSigVector :: (ByteString, ByteString) -> Assertion
runMulSigVector (a, ops) = assertBool "multisig vector" $ Just a == b
  where
    s = do
        s <- decodeHex ops
        eitherToMaybe $ S.decode s
    b = do
        o <- s
        d <- eitherToMaybe $ decodeOutput o
        addrToString $ p2shAddr btc d

sigDecodeMap :: (ByteString, Int) -> Spec
sigDecodeMap (_, i) =
    it ("check signature " ++ show i) func
  where
    func = testSigDecode $ scriptSigSignatures !! i

testSigDecode :: ByteString -> Assertion
testSigDecode str =
    let bs = fromJust $ decodeHex str
        eitherSig = decodeTxLaxSig bs
    in assertBool
           (unwords
                [ "Decode failed:"
                , fromLeft (error "Decode did not fail") eitherSig
                ]) $
       isRight eitherSig

mulSigVectors :: [(ByteString, ByteString)]
mulSigVectors =
    [ ( "3QJmV3qfvL9SuYo34YihAf3sRCW3qSinyC"
      , "52410491bba2510912a5bd37da1fb5b1673010e43d2c6d812c514e91bfa9f2eb129e1c183329db55bd868e209aac2fbc02cb33d98fe74bf23f0c235d6126b1d8334f864104865c40293a680cb9c020e7b1e106d8c1916d3cef99aa431a56d253e69256dac09ef122b1a986818a7cb624532f062c1d1f8722084861c5c3291ccffef4ec687441048d2455d2403e08708fc1f556002f1b6cd83f992d085097f9974ab08a28838f07896fbab08f39495e15fa6fad6edbfb1e754e35fa1c7844c41f322a1863d4621353ae"
      )
    ]

scriptSigSignatures :: [ByteString]
scriptSigSignatures =
     -- Signature in input of txid 1983a69265920c24f89aac81942b1a59f7eb30821a8b3fb258f88882b6336053
    [ "304402205ca6249f43538908151fe67b26d020306c0e59fa206cf9f3ccf641f33357119d02206c82f244d04ac0a48024fb9cc246b66e58598acf206139bdb7b75a2941a2b1e401"
      -- Signature in input of txid fb0a1d8d34fa5537e461ac384bac761125e1bfa7fec286fa72511240fa66864d  Strange DER sizes. But in Blockchain
    , "3048022200002b83d59c1d23c08efd82ee0662fec23309c3adbcbd1f0b8695378db4b14e736602220000334a96676e58b1bb01784cb7c556dd8ce1c220171904da22e18fe1e7d1510db501"
    ]


testID :: (FromJSON a, ToJSON a, Eq a) => a -> Bool
testID x =
    (A.decode . A.encode) (singleton ("object" :: String) x) ==
    Just (singleton ("object" :: String) x)