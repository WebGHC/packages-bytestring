{-# LANGUAGE ScopedTypeVariables, CPP, BangPatterns, MonoPatBinds #-}
{-# OPTIONS_HADDOCK hide #-}
-- |
-- Copyright   : 2010-2011 Simon Meier, 2010 Jasper van der Jeugt
-- License     : BSD3-style (see LICENSE)
--
-- Maintainer  : Simon Meier <iridcode@gmail.com>
-- Stability   : experimental
-- Portability : GHC
--
-- This module is internal. It is only intended to be used by the 'bytestring'
-- and the 'text' library. Please contact the maintainer, if you need to use
-- this module in your library. We are glad to accept patches for further
-- standard encodings of standard Haskell values.
--
-- If you need to write your own primitive encoding, then be aware that you are
-- writing code with /all saftey belts off/; i.e.,
-- *this is the code that might make your application vulnerable to buffer-overflow attacks!*
-- The "Codec.Bounded.Encoding.Internal.Test" module provides you with
-- utilities for testing your encodings thoroughly.
--
module Data.ByteString.Lazy.Builder.BasicEncoding.Internal (
  -- * Fixed-size Encodings
    Size
  , FixedEncoding
  , fixedEncoding
  , size
  , runF

  , emptyF
  , contramapF
  , pairF
  -- , liftIOF

  , storableToF

  -- * Bounded-size Encodings
  , BoundedEncoding
  , boundedEncoding
  , sizeBound
  , runB

  , emptyB
  , contramapB
  , pairB
  , eitherB
  , ifB

  -- , liftIOB

  , toB
  , fromF

  -- , withSizeFB
  -- , withSizeBB

  -- * Shared operators
  , (>$<)
  , (>*<)

  ) where

import Foreign
import Prelude hiding (maxBound)

------------------------------------------------------------------------------
-- Supporting infrastructure
------------------------------------------------------------------------------

-- | Contravariant functors as in the 'contravariant' package.
class Contravariant f where
    contramap :: (b -> a) -> f a -> f b

infixl 4 >$<

-- | An overloaded infix operator for 'contramapF' and 'contramapB'.
--
-- We can use it for example to prepend and/or append fixed values to an
-- encoding.
--
-- >showEncoding ((\x -> ('\'', (x, '\''))) >$< fixed3) 'x' = "'x'"
-- >  where
-- >    fixed3 = char7 >*< char7 >*< char7
--
-- Note that the rather verbose syntax for composition stems from the
-- requirement to be able to compute the 'size's and 'sizeBound's at
-- compile time.
--
(>$<) :: Contravariant f => (b -> a) -> f a -> f b
(>$<) = contramap


instance Contravariant FixedEncoding where
    contramap = contramapF

instance Contravariant BoundedEncoding where
    contramap = contramapB


-- | Type-constructors supporting lifting of type-products.
class Monoidal f where
    pair :: f a -> f b -> f (a, b)

instance Monoidal FixedEncoding where
    pair = pairF

instance Monoidal BoundedEncoding where
    pair = pairB

infixr 5 >*<

-- | An overloaded infix operator for 'pairF' and 'pairB'.
-- For example,
--
-- >showF (char7 >*< char7) ('x','y') = "xy"
--
-- We can combine multiple encodings using '>*<' multiple times.
--
-- >showEncoding (char7 >*< char7 >*< char7) ('x',('y','z')) = "xyz"
--
(>*<) :: Monoidal f => f a -> f b -> f (a, b)
(>*<) = pair


-- | The type used for sizes and sizeBounds of sizes.
type Size = Int


------------------------------------------------------------------------------
-- Fixed-size Encodings
------------------------------------------------------------------------------

-- | An encoding that always results in a sequence of bytes of a
-- pre-determined, fixed size.
data FixedEncoding a = FE {-# UNPACK #-} !Int (a -> Ptr Word8 -> IO ())

fixedEncoding :: Int -> (a -> Ptr Word8 -> IO ()) -> FixedEncoding a
fixedEncoding = FE

-- | The size of the sequences of bytes generated by this 'FixedEncoding'.
{-# INLINE CONLIKE size #-}
size :: FixedEncoding a -> Int
size (FE l _) = l

{-# INLINE CONLIKE runF #-}
runF :: FixedEncoding a -> a -> Ptr Word8 -> IO ()
runF (FE _ io) = io

-- | The 'FixedEncoding' that always results in the zero-length sequence.
{-# INLINE CONLIKE emptyF #-}
emptyF :: FixedEncoding a
emptyF = FE 0 (\_ _ -> return ())

-- | Encode a pair by encoding its first component and then its second component.
{-# INLINE CONLIKE pairF #-}
pairF :: FixedEncoding a -> FixedEncoding b -> FixedEncoding (a, b)
pairF (FE l1 io1) (FE l2 io2) =
    FE (l1 + l2) (\(x1,x2) op -> io1 x1 op >> io2 x2 (op `plusPtr` l1))

-- | Change an encoding such that it first applies a function to the value
-- to be encoded.
--
-- Note that encodings are 'Contrafunctors'
-- <http://hackage.haskell.org/package/contravariant>. Hence, the following
-- laws hold.
--
-- >contramapF id = id
-- >contramapF f . contramapF g = contramapF (g . f)
{-# INLINE CONLIKE contramapF #-}
contramapF :: (b -> a) -> FixedEncoding a -> FixedEncoding b
contramapF f (FE l io) = FE l (\x op -> io (f x) op)

-- | Convert a 'FixedEncoding' to a 'BoundedEncoding'.
{-# INLINE CONLIKE toB #-}
toB :: FixedEncoding a -> BoundedEncoding a
toB (FE l io) = BE l (\x op -> io x op >> (return $! op `plusPtr` l))

-- | Convert a 'FixedEncoding' to a 'BoundedEncoding'.
{-# INLINE CONLIKE fromF #-}
fromF :: FixedEncoding a -> BoundedEncoding a
fromF = toB

{-# INLINE CONLIKE storableToF #-}
storableToF :: forall a. Storable a => FixedEncoding a
storableToF = FE (sizeOf (undefined :: a)) (\x op -> poke (castPtr op) x)

{-
{-# INLINE CONLIKE liftIOF #-}
liftIOF :: FixedEncoding a -> FixedEncoding (IO a)
liftIOF (FE l io) = FE l (\xWrapped op -> do x <- xWrapped; io x op)
-}

------------------------------------------------------------------------------
-- Bounded-size Encodings
------------------------------------------------------------------------------

-- | An encoding that always results in sequence of bytes that is no longer
-- than a pre-determined bound.
data BoundedEncoding a = BE {-# UNPACK #-} !Int (a -> Ptr Word8 -> IO (Ptr Word8))

-- | The bound on the size of sequences of bytes generated by this 'BoundedEncoding'.
{-# INLINE CONLIKE sizeBound #-}
sizeBound :: BoundedEncoding a -> Int
sizeBound (BE b _) = b

boundedEncoding :: Int -> (a -> Ptr Word8 -> IO (Ptr Word8)) -> BoundedEncoding a
boundedEncoding = BE

{-# INLINE CONLIKE runB #-}
runB :: BoundedEncoding a -> a -> Ptr Word8 -> IO (Ptr Word8)
runB (BE _ io) = io

-- | Change a 'BoundedEncoding' such that it first applies a function to the
-- value to be encoded.
--
-- Note that 'BoundedEncoding's are 'Contrafunctors'
-- <http://hackage.haskell.org/package/contravariant>. Hence, the following
-- laws hold.
--
-- >contramapB id = id
-- >contramapB f . contramapB g = contramapB (g . f)
{-# INLINE CONLIKE contramapB #-}
contramapB :: (b -> a) -> BoundedEncoding a -> BoundedEncoding b
contramapB f (BE b io) = BE b (\x op -> io (f x) op)

-- | The 'BoundedEncoding' that always results in the zero-length sequence.
{-# INLINE CONLIKE emptyB #-}
emptyB :: BoundedEncoding a
emptyB = BE 0 (\_ op -> return op)

-- | Encode a pair by encoding its first component and then its second component.
{-# INLINE CONLIKE pairB #-}
pairB :: BoundedEncoding a -> BoundedEncoding b -> BoundedEncoding (a, b)
pairB (BE b1 io1) (BE b2 io2) =
    BE (b1 + b2) (\(x1,x2) op -> io1 x1 op >>= io2 x2)

-- | Encode an 'Either' value using the first 'BoundedEncoding' for 'Left'
-- values and the second 'BoundedEncoding' for 'Right' values.
--
-- Note that the functions 'eitherB', 'pairB', and 'contramapB' (written below
-- using '>$<') suffice to construct 'BoundedEncoding's for all non-recursive
-- algebraic datatypes. For example,
--
-- @
--maybeB :: BoundedEncoding () -> BoundedEncoding a -> BoundedEncoding (Maybe a)
--maybeB nothing just = 'maybe' (Left ()) Right '>$<' eitherB nothing just
-- @
{-# INLINE CONLIKE eitherB #-}
eitherB :: BoundedEncoding a -> BoundedEncoding b -> BoundedEncoding (Either a b)
eitherB (BE b1 io1) (BE b2 io2) =
    BE (max b1 b2)
        (\x op -> case x of Left x1 -> io1 x1 op; Right x2 -> io2 x2 op)

-- | Conditionally select a 'BoundedEncoding'.
-- For example, we can implement the ASCII encoding that drops characters with
-- Unicode codepoints above 127 as follows.
--
-- @
--charASCIIDrop = 'ifB' (< '\128') ('fromF' 'char7') 'emptyB'
-- @
{-# INLINE CONLIKE ifB #-}
ifB :: (a -> Bool) -> BoundedEncoding a -> BoundedEncoding a -> BoundedEncoding a
ifB p be1 be2 =
    contramapB (\x -> if p x then Left x else Right x) (eitherB be1 be2)


{-
{-# INLINE withSizeFB #-}
withSizeFB :: (Word -> FixedEncoding Word) -> BoundedEncoding a -> BoundedEncoding a
withSizeFB feSize (BE b io) =
    BE (lSize + b)
       (\x op0 -> do let !op1 = op0 `plusPtr` lSize
                     op2 <- io x op1
                     ioSize (fromIntegral $ op2 `minusPtr` op1) op0
                     return op2)
  where
    FE lSize ioSize = feSize (fromIntegral b)


{-# INLINE withSizeBB #-}
withSizeBB :: BoundedEncoding Word -> BoundedEncoding a -> BoundedEncoding a
withSizeBB (BE bSize ioSize) (BE b io) =
    BE (bSize + 2*b)
       (\x op0 -> do let !opTmp = op0 `plusPtr` (bSize + b)
                     opTmp' <- io x opTmp
                     let !s = opTmp' `minusPtr` opTmp
                     op1 <- ioSize (fromIntegral s) op0
                     copyBytes op1 opTmp s
                     return $! op1 `plusPtr` s)

{-# INLINE CONLIKE liftIOB #-}
liftIOB :: BoundedEncoding a -> BoundedEncoding (IO a)
liftIOB (BE l io) = BE l (\xWrapped op -> do x <- xWrapped; io x op)
-}

------------------------------------------------------------------------------
-- Encodings from 'ByteString's.
------------------------------------------------------------------------------

{-
-- | A 'FixedEncoding' that always results in the same byte sequence given as a
-- strict 'S.ByteString'. We can use this encoding to insert fixed ...
{-# INLINE CONLIKE constByteStringF #-}
constByteStringF :: S.ByteString -> FixedEncoding ()
constByteStringF bs =
    FE len io
  where
    (S.PS fp off len) = bs
    io _ op = do
        copyBytes op (unsafeForeignPtrToPtr fp `plusPtr` off) len
        touchForeignPtr fp

-- | Encode a fixed-length prefix of a strict 'S.ByteString' as-is. We can use
-- this function to
{-# INLINE byteStringPrefixB #-}
byteStringTakeB :: Int  -- ^ Length of the prefix. It should be smaller than
                        -- 100 bytes, as otherwise
                -> BoundedEncoding S.ByteString
byteStringTakeB n0 =
    BE n io
  where
    n = max 0 n0 -- sanitize

    io (S.PS fp off len) op = do
        let !s = min len n
        copyBytes op (unsafeForeignPtrToPtr fp `plusPtr` off) s
        touchForeignPtr fp
        return $! op `plusPtr` s
-}

{-

httpChunkedTransfer :: Builder -> Builder
httpChunkedTransfer =
    encodeChunked 32 (word64HexFixedBound '0')
                     ((\_ -> ('\r',('\n',('\r','\n')))) >$< char8x4)
  where
    char8x4 = toB (char8 >*< char8 >*< char8 >*< char8)



chunked :: Builder -> Builder
chunked = encodeChunked 16 word64VarFixedBound emptyB

-}



