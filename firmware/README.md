# firmware/ — ファームウェア（Zig）

> **⚠️ 実験的・開発中。実資金で使わないこと。**
> 本コードは第三者監査を受けていない。**画面 UI と QR 送受信は未実装**であり、
> ハードウェアウォレットとして完成していない。開発には **LLM をヘビーに使用**しており、
> 生成コードには誤りが含まれ得る。詳細は [../DISCLAIMER.md](../DISCLAIMER.md) を参照。

## 現状（v0.1 開発中）

| 項目 | 状態 |
|---|---|
| 言語 | **Zig**（0.17 以降） |
| 楕円曲線 | **libsecp256k1**（C ライブラリをリンク） |
| 実装済み（暗号・エンコード） | Base58 / Bech32・Bech32m / RIPEMD-160 / SHA-256 / HMAC-SHA512 / PBKDF2 / HKDF-SHA256 / Keccak-256 / ECDSA 署名と検証（RFC6979・low-s・DER・recoverable） |
| 実装済み（Bitcoin） | BIP39（ダイス・カメラ等の entropy 結合を含む） / BIP32 / アドレス生成（P2PKH・P2SH-P2WPKH・P2WPKH・P2TR） / トランザクション解析・直列化 / Legacy・BIP143 sighash / **BIP341（Taproot）の鍵パス署名** / PSBT の解析・検証・書き出し（BIP174） / PSBT からの署名と最終化（P2WPKH・P2PKH・P2SH-P2WPKH・P2PK） / **2-of-3 マルチシグ（P2WSH）** / 手数料計算とお釣り判定 / バイト列入出力のワークフロー（`signPsbtBytes`） |
| 実装済み（CLI） | `address` / `sign` / `show`（署名前の確認表示） / `mnemonic`（ダイス検証） / `ur` / `ur-decode` / `evm-sign` / `evm-show` |
| 実装済み（転送層） | **BC-UR**（Bytewords の standard/uri/minimal、CRC-32、単一パート・マルチパートのエンコード/デコード、順不同・重複ありの再構成） |
| 実装済み（EVM） | RLP のエンコード・デコード / EIP-55 チェックサム付きアドレス / **EIP-155（legacy）と EIP-1559（type 2）の署名**（両方とも署名して検証まで行う） / EIP-191 `personal_sign` / **EIP-712 型付きデータ**（encodeType の依存型ソート・配列・入れ子・ドメイン推論） / **ABI デコード**（正準形のみ受理） / **ERC-7730 clear signing**（記述子の解析・関数の照合・人間可読な表示項目の生成・危険パターンの警告） |
| テスト | **203 件すべて成功**（BTC: BIP39 24 件・BIP32・BIP49/84/86・**BIP143 の署名がバイト単位で一致**・BIP174 の PSBT 不正 20 件/妥当 27 件・統合テスト・**Bitcoin Core が単一署名・2-of-3 マルチシグ・Taproot の署名を受理することの確認** / EVM: RLP 公式ベクタ・**EIP-155 の公式例とバイト一致**・EIP-55・EIP-191・EIP-712（仕様の既知値と一致し、署名も独立実装と一致）・ABI（ethers.js が生成した calldata と一致）・ERC-7730（実際のレジストリの記述子） / 転送層: BC-UR の仕様・参照実装の文字列と一致） |
| 未実装 | 画面 UI、実機（signet）での送金、MUR（ファウンテン符号の冗長パート） |

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
│   │   ├── seed/
│   │   │   ├── bip39.zig      BIP39（単語リストはバイナリに埋め込み）
│   │   │   └── entropy.zig    ダイス・カメラ・TRNG の結合（HKDF-SHA256）
│   │   └── derive/bip32.zig   BIP32（CKDpriv / CKDpub / 拡張鍵の直列化）
│   ├── apps/btc/              Bitcoin
│   │   ├── address.zig        アドレス生成（P2PKH / P2SH-P2WPKH / P2WPKH / P2TR）
│   │   ├── cursor.zig         ネットワーク直列化のカーソル
│   │   ├── transaction.zig    トランザクションの解析・直列化
│   │   ├── sighash.zig        Legacy / BIP143 の署名対象ハッシュ
│   │   ├── psbt.zig           PSBT の解析・検証・書き出し（BIP174）
│   │   ├── sign.zig           鍵探索・署名・最終化・手数料・お釣り判定
│   │   ├── multisig.zig       2-of-3 マルチシグ（P2WSH）の構築と署名
│   │   └── taproot.zig        Taproot（BIP341）の鍵パス署名
│   ├── transport/             エアギャップの転送層
│   │   ├── bytewords.zig      Bytewords（standard / uri / minimal）
│   │   ├── cbor.zig           UR に必要な CBOR
│   │   └── ur.zig             BC-UR（単一パート・マルチパート）
│   └── apps/evm/              EVM
│       ├── rlp.zig            RLP のエンコード・デコード
│       ├── address.zig        EIP-55 チェックサム付きアドレス
│       ├── transaction.zig    EIP-155 / EIP-1559 の署名
│       ├── eip191.zig         personal_sign
│       ├── eip712.zig         型付きデータ
│       ├── abi.zig            ABI デコード（calldata の解析）
│       └── clear_signing.zig  ERC-7730 記述子による人間可読な表示
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

## Pico 系（RP2040 / RP2350）への移植可能性

Linux を前提にしない Pico 系へコアを載せられるかを、毎回コンパイルで確認している
（詳細と検討結果は [docs/03-hardware-bom.md](../docs/03-hardware-bom.md) の 2.3 節）。

```bash
zig build pico     # RP2040（Cortex-M0+）と RP2350（Cortex-M33）の両方を確認
```

コア（BIP39/32・アドレス生成・PSBT 解析・署名経路・EVM 解析・UR）は両ターゲットで
コンパイルが通る。libsecp256k1 も両ターゲットでビルドできることを確認済み。
未実装は HAL（LCD・ボタン・SD・乱数）とカメラ/QR の方式。

## 開発用 CLI

画面 UI を作る前でも、ターミナルから操作できる（実機ではこれで動作確認する）。

```bash
zig build                      # zig-out/bin/zhww ができる
cd firmware

# アドレス（結果は標準出力、診断は標準エラー）
./zig-out/bin/zhww address --mnemonic "abandon abandon … about"
./zig-out/bin/zhww address --mnemonic "…" --path "m/86'/0'/0'/0/0" --kind p2tr
./zig-out/bin/zhww address --mnemonic "…" --network signet --kind p2wpkh

# PSBT に署名（base64 を標準入力から読む）
cat psbt.txt | ./zig-out/bin/zhww sign --mnemonic "…"
#   → SIGNED_PSBT=<base64> と FINAL_TX=<hex> を標準出力へ
#   → 署名数・手数料・お釣り・警告を標準エラーへ

# ダイスの記録から mnemonic を再計算（記録の検証用）
./zig-out/bin/zhww mnemonic --dice "123456123456…" --words 12
./zig-out/bin/zhww mnemonic --dice "…" --words 24 --camera aabbccdd

# EVM のトランザクションに署名する（JSON を標準入力から）
echo '{"chainId":1,"nonce":7,"gasLimit":21000,"maxFeePerGas":30000000000,
       "maxPriorityFeePerGas":1000000000,"to":"0x…","value":123456789,"data":"0x"}' \
  | ./zig-out/bin/zhww evm-sign --mnemonic "…"
#   → 署名済み raw tx を標準出力へ（送信元アドレスと種別は標準エラーへ）

# EVM のトランザクションを表示する（raw hex。署名は行わない）
./zig-out/bin/zhww evm-show < raw_tx.hex
#   → 種別・チェーン ID・送金先（EIP-55）・金額・手数料・calldata の関数名を表示し、
#     知らない関数や危険な操作（approve 等）は警告する

# 署名の前に「何に署名しようとしているか」を確認する（画面の代わり）
cat psbt.txt | ./zig-out/bin/zhww show --network regtest --mnemonic "…"
#   → 入力（金額・アドレス）・出力（送金/お釣り）・手数料を表示する

# PSBT を UR（QR 転送用）にして、1 行 1 パートで表示する
cat psbt.txt | ./zig-out/bin/zhww ur --fragment 40
#   → ur:crypto-psbt/1-4/… のように出力される（アニメーション QR の各コマ）

# UR のパートを読み取って PSBT に戻す
./zig-out/bin/zhww ur-decode < parts.txt
```

**出力の方針**: 結果は標準出力、診断（手数料・警告）は標準エラー。
そのため `zhww sign < psbt.txt > signed.txt` のようにそのまま繋げられる。

## 参考にする実装

| プロジェクト | 参照する点 |
|---|---|
| [SeedSigner](https://github.com/SeedSigner/seedsigner) | ダイス entropy、SeedQR、エアギャップ運用、[再現可能ビルド手順](https://github.com/SeedSigner/seedsigner-os/blob/main/docs/building.md) |
| [Krux](https://github.com/selfcustody/krux) | 画面設計、エントロピー実測、コード構成 |
| [Specter DIY](https://github.com/cryptoadvance/specter-diy) | セキュアブートローダ、[セキュリティモデルの書き方](https://github.com/cryptoadvance/specter-diy/blob/master/docs/security-model.md) |
| [libsecp256k1](https://github.com/bitcoin-core/secp256k1) | 唯一の暗号プリミティブ提供元 |

## ライセンス

**GPL-3.0-or-later**（[../LICENSE-POLICY.md](../LICENSE-POLICY.md)）
