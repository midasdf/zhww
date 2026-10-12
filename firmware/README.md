# firmware/ — ファームウェア（Zig）

> **⚠️ 実験的・開発中。実資金で使わないこと。**
> 本コードは第三者監査を受けていない。**署名機能は未実装**であり、ハードウェアウォレットとしては
> まだ動作しない。開発には **LLM をヘビーに使用**しており、生成コードには誤りが含まれ得る。
> 詳細は [../DISCLAIMER.md](../DISCLAIMER.md) を参照。

## 現状（v0.1 開発中）

| 項目 | 状態 |
|---|---|
| 言語 | **Zig**（0.17 以降） |
| 楕円曲線 | **libsecp256k1**（C ライブラリをリンク） |
| 実装済み | Base58 / Bech32・Bech32m / RIPEMD-160 / SHA-256 / HMAC-SHA512 / PBKDF2 / BIP39 / BIP32 / アドレス生成（P2PKH・P2SH-P2WPKH・P2WPKH・P2TR） |
| テスト | **51 件すべて成功**（BIP39 公式ベクタ 24 件、BIP32 テストベクタ、BIP49/84/86 公式ベクタを含む） |
| 未実装 | UI、QR 送受信、PSBT 解析、EVM 署名、開発用 CLI |

```bash
zig build test     # 公式テストベクタを含む全テスト
```

## 依存

| 依存 | 用途 | 入手方法 |
|---|---|---|
| **libsecp256k1** | 鍵導出・署名（唯一の暗号ライブラリ） | macOS: `brew install secp256k1` / Debian: `apt install libsecp256k1-dev` |
| Zig 標準ライブラリ | SHA-256 / SHA-512 / HMAC / PBKDF2 / Keccak | — |

> RIPEMD-160 は Zig 標準ライブラリに無く、ターゲット（Raspberry Pi OS + OpenSSL 3）でも
> 利用できないことがあるため **自前実装**している（`src/core/crypto/ripemd160.zig`）。
> 公式テストベクタで検証済み。

## モジュール構成

```
firmware/
├── build.zig
├── tests.zig                  テストのルート（コア + 公式ベクタ）
├── src/
│   ├── root.zig               公開 API
│   ├── core/                  チェーン非依存。鍵と表示の最終責任者
│   │   ├── errors.zig         エラー型（解析失敗は必ず署名拒否に繋げる）
│   │   ├── encoding/
│   │   │   ├── base58.zig     Base58 / Base58Check
│   │   │   └── bech32.zig     Bech32 / Bech32m（v0 と v1 の取り違え防止）
│   │   ├── crypto/
│   │   │   ├── ripemd160.zig  RIPEMD-160（自前実装・ストリーミング）
│   │   │   ├── hashes.zig     sha256d / hash160 / taggedHash
│   │   │   └── secp256k1.zig  libsecp256k1 への最小バインディング
│   │   ├── seed/bip39.zig     BIP39（単語リストはバイナリに埋め込み）
│   │   └── derive/bip32.zig   BIP32（CKDpriv / CKDpub / 拡張鍵の直列化）
│   └── apps/btc/address.zig   Bitcoin アドレス生成
└── tests/                     公式テストベクタによる統合テスト
```

## 実装上の不変条件

| ID | 内容 |
|---|---|
| I-1 | `core` はチェーンを知らない |
| I-2 | `apps` は鍵素材を保持しない（署名は「このパスで、この 32 バイトを」の形でのみ要求する） |
| I-3 | 署名対象ハッシュは `apps` と `core` が独立に計算し、一致しなければ署名しない |
| I-4 | 秘密情報をフラッシュ・SD・スワップに書かない |
| I-5 | リリースビルドでは USB データ通信を無効化する |

## 設計上の決定と理由

| 決定 | 理由 |
|---|---|
| **動的メモリを使わない**（コアは固定長バッファ＋スライス） | 断片化・確保失敗・解放漏れを構造的に排除する。組み込みでの挙動が予測可能になる |
| **libsecp256k1 のみを暗号プリミティブとして使う** | 純粋な Zig 実装はタイミング攻撃に耐えないため、秘密鍵を扱う演算には使わない |
| **C ヘッダを `@cImport` せず、必要な関数だけを extern 宣言** | 監査時に「どの C 関数に依存しているか」が一目で分かる |
| **RIPEMD-160 を自前実装** | 標準ライブラリにも OpenSSL にも依存できない環境があるため（公式ベクタで検証済み） |
| **BIP39 単語リストをバイナリに埋め込む**（`@embedFile`） | 実行時のファイルシステム依存を無くす。改ざん面も減る |
| **`derivePath` は絶対パス（`m/...`）をマスター鍵でのみ受け付ける** | 「m/0'/1」を非マスター鍵に与えると 1 階層余分に潜る事故が起きる。実際に本実装でこのバグをテストが検出したため、API で禁止した |
| **非 ASCII のパスフレーズを明示的に拒否** | NFKD 正規化が未実装のため。黙って異なる seed を作るより、エラーにする方が安全 |

## 開発用 CLI（未実装）

Zig 0.17 で標準出力が `std.Io` 経由に変わったため、`src/cli/main.zig` は Io の初期化方法を
確定させてから追加する。現時点の検証は `zig build test`（公式テストベクタ）で行う。

## 参考にする実装

| プロジェクト | 参照する点 |
|---|---|
| [SeedSigner](https://github.com/SeedSigner/seedsigner) | ダイス entropy、SeedQR、エアギャップ運用、[再現可能ビルド手順](https://github.com/SeedSigner/seedsigner-os/blob/main/docs/building.md) |
| [Krux](https://github.com/selfcustody/krux) | 画面設計、エントロピー実測、コード構成 |
| [Specter DIY](https://github.com/cryptoadvance/specter-diy) | セキュアブートローダ、[セキュリティモデルの書き方](https://github.com/cryptoadvance/specter-diy/blob/master/docs/security-model.md) |
| [libsecp256k1](https://github.com/bitcoin-core/secp256k1) | 唯一の暗号プリミティブ提供元 |

## ライセンス

**GPL-3.0-or-later**（[../LICENSE-POLICY.md](../LICENSE-POLICY.md)）
