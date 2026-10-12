//! 共通のエラー型。
//!
//! 方針: 解析・検証の失敗はすべてエラーで通知し、署名フローはエラーを捕捉したら
//! **署名せずに理由を画面表示する**。エラーを握りつぶして処理を続行してはならない。

pub const Error = error{
    /// Base58 / Bech32 などの書式が不正
    InvalidEncoding,
    /// チェックサム不一致
    ChecksumMismatch,
    /// BIP39 mnemonic として不正（語数・語彙・チェックサム）
    InvalidMnemonic,
    /// 派生パスの書式が不正
    InvalidPath,
    /// 鍵として不正（範囲外・無限遠点など）
    InvalidKey,
    /// BIP32 の派生で無効な tweak（仕様により次の index へ進む）
    InvalidTweak,
    /// 出力バッファが足りない
    BufferTooSmall,
    /// 正規化（NFKD）が必要な非 ASCII 入力。v0.1 では未対応
    UnsupportedNormalization,
    /// 入力データが途中で終わっている
    Truncated,
    /// PSBT の構造・検証エラー（重複キー、マップ数の不一致など）
    InvalidPsbt,
    /// 未対応の sighash タイプ（NONE / SINGLE は安全性のため非対応）
    UnsupportedSighash,
    /// 署名に使える鍵が見つからない
    NoMatchingKey,
    /// 署名の検証に失敗した
    SignatureInvalid,
    /// メモリ確保に失敗した（解析層のみ。鍵を扱うコア処理では発生しない）
    OutOfMemory,
};

test "error set is constructible" {
    const e: Error = error.InvalidKey;
    try @import("std").testing.expect(e == error.InvalidKey);
}
