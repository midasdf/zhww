//! Shared error type.
//!
//! Policy: every parse/validation failure is reported as an error, and when the signing flow
//! catches an error it **shows the reason on screen without signing**. Never swallow an error
//! and carry on regardless.
// SPDX-License-Identifier: GPL-3.0-or-later

pub const Error = error{
    /// Invalid format such as Base58 / Bech32
    InvalidEncoding,
    /// Checksum mismatch
    ChecksumMismatch,
    /// Not a valid BIP39 mnemonic (word count, vocabulary, checksum)
    InvalidMnemonic,
    /// Invalid derivation path format
    InvalidPath,
    /// Invalid key (out of range, point at infinity, etc.)
    InvalidKey,
    /// Fatal context abandonment is terminal; never reconstruct or resume C.
    ContextFaulted,
    /// Invalid tweak during BIP32 derivation (the spec says to move on to the next index)
    InvalidTweak,
    /// Output buffer is too small
    BufferTooSmall,
    /// Non-ASCII input that would need normalization (NFKD). Unsupported in v0.1
    UnsupportedNormalization,
    /// Input data ends prematurely
    Truncated,
    /// PSBT structure/validation error (duplicate keys, map count mismatch, etc.)
    InvalidPsbt,
    /// Unsupported sighash type (NONE / SINGLE are unsupported for safety)
    UnsupportedSighash,
    /// No key available for signing was found
    NoMatchingKey,
    /// Signature verification failed
    SignatureInvalid,
    /// Independently prepared messages disagree with primary signer computation.
    SigningPlanMismatch,
    /// Memory allocation failed (parsing layer only; never happens in key-handling core code)
    OutOfMemory,
};

test "error set is constructible" {
    const e: Error = error.InvalidKey;
    try @import("std").testing.expect(e == error.InvalidKey);
}
