# firmware/tests/ — テストと公式テストベクタ

- **最終更新**: 2026-10-12

```bash
cd firmware && zig build test
```

実装のユニットテスト（`src/` 内の `test` ブロック）と、公式テストベクタによる統合テスト
（本ディレクトリ）を `firmware/tests.zig` がまとめて実行する。

**現在: 304 件すべて成功。**（Debug / ReleaseSafe / ReleaseFast / ReleaseSmall の
4 モードすべてで成功することを確認済み。GitHub Actions でも Linux 上で毎回検証している）

## 最も強い検証: Bitcoin Core が署名を受理する

`core_interop_test.zig` は、**実際の Bitcoin Core（v31.1.0）と相互運用できること**を検証する。

1. Core の `createpsbt` + `utxoupdatepsbt` で作った PSBT を本実装で署名する
2. Core の `finalizepsbt` が `complete: true` を返し、その出力 hex が本実装の
   最終トランザクションと**バイト単位で一致**する
3. Core の `testmempoolaccept` が `allowed: true` を返す

他のテストは「仕様どおり実装できているか」を見るが、このテストは
「**Core が我々の署名を有効と判断するか**」を見る。実装・エンコード・鍵探索・最終化の
すべてが噛み合っていなければ通らない。検証に使った PSBT と期待値は
`tests/vectors/core_psbt.json` に固定してある（再現手順は同ファイルの説明を参照）。

## 最適化モードを変えても結果が変わらないこと

整数オーバーフローや未定義動作の検査は Debug と ReleaseSafe では有効、ReleaseFast と
ReleaseSmall では無効になる。**モードによって結果が変わらないこと**を確認する。

macOS では pkg-config からフラグが得られる（`brew install secp256k1` 済み）。

```bash
cd firmware
for mode in Debug ReleaseSafe ReleaseFast ReleaseSmall; do
  echo "== $mode =="
  zig test tests.zig -O$mode $(pkg-config --cflags --libs libsecp256k1) -lc | tail -1
done
```

## ディレクトリ構成

```
firmware/tests/
├── README.md                 ← 本ファイル
├── vectors/
│   ├── bip39.json            BIP39 公式ベクタ 24 件（entropy / mnemonic / seed / xprv）
│   ├── bip32.json            BIP32 テストベクタ 1 の派生チェーン（seed / path / xprv / xpub）
│   ├── bip49.json            BIP49 P2SH-P2WPKH（testnet・uprv/upub・WIF・アドレス）
│   ├── bip84.json            BIP84 P2WPKH（mainnet・zprv/zpub・WIF・公開鍵・アドレス）
│   ├── bip86.json            BIP86 P2TR（内部鍵・出力鍵・アドレス）
│   ├── bip143.json           BIP143 Native P2WPKH（未署名 tx / sighash / DER 署名 / 署名済み tx）
│   ├── bip174.json           BIP174 PSBT（不正 20 件 / 妥当 27 件・Base64）
│   ├── core_psbt.json        Bitcoin Core が作った PSBT と、Core の最終化結果（単一署名）
│   ├── core_multisig.json    2-of-3 マルチシグ（Core が作った UTXO と、Core の最終化結果）
│   └── core_taproot.json     Taproot 鍵パス署名（Core が作った P2TR の UTXO と、Core の最終化結果）
├── bip39_vectors_test.zig
├── bip32_vectors_test.zig
├── address_vectors_test.zig
├── bip143_test.zig
├── bip174_test.zig
├── fuzz_test.zig             壊れた入力への堅牢性（変異テスト）
├── sign_test.zig             署名と最終化の統合テスト（外部ベクタが無い経路）
│                             ※ 画面 UI（font / framebuffer / screen）と PNG 出力の
│                               テストは各モジュール内にあり、root.zig 経由で実行される
├── core_interop_test.zig     Bitcoin Core との相互運用（Core が署名を受理する）
├── multisig_test.zig         2-of-3 マルチシグ（Core が署名を受理する）
└── taproot_test.zig          Taproot 鍵パス署名（Core が署名を受理する）

EVM のテストは実装ファイル内（`src/apps/evm/*.zig` の `test` ブロック）にあり、
RLP 公式ベクタ・EIP-155 の公式例・EIP-55・EIP-191 を検証する。
```

## ベクタの出典（自前の期待値は使わない）

| ファイル | 出典 |
|---|---|
| `bip39.json` | https://github.com/trezor/python-mnemonic （公式ベクタ） |
| `bip32.json` | https://github.com/bitcoin/bips/blob/master/bip-0032.mediawiki |
| `bip49.json` | https://github.com/bitcoin/bips/blob/master/bip-0049.mediawiki |
| `bip84.json` | https://github.com/bitcoin/bips/blob/master/bip-0084.mediawiki |
| `bip86.json` | https://github.com/bitcoin/bips/blob/master/bip-0086.mediawiki |
| `bip143.json` | https://github.com/bitcoin/bips/blob/master/bip-0143.mediawiki |
| `bip174.json` | https://github.com/bitcoin/bips/blob/master/bip-0174.mediawiki |
| `core_psbt.json` | Bitcoin Core v31.1.0（regtest で実際に作成。`createpsbt` + `utxoupdatepsbt` の出力） |
| `core_multisig.json` | Bitcoin Core v31.1.0（regtest。`createmultisig` のアドレスへ送金し、`createpsbt` で作ったトランザクション） |
| `core_taproot.json` | Bitcoin Core v31.1.0（regtest。BIP86 の P2TR アドレスへ送金し、`createpsbt` で作ったトランザクション） |

> **注意**: `bip39.json` の seed はパスフレーズ **"TREZOR"** で導出された値である
> （空のパスフレーズでは一致しない）。

## 最も強いテスト: 署名のバイト単位一致

`bip143_test.zig` は BIP143 の Native P2WPKH ベクタを使い、以下を **同時に** 検証する。

1. トランザクションの解析と直列化
2. Legacy sighash（input 0 は P2PK）
3. BIP143 sighash（input 1 は P2WPKH）
4. ECDSA 署名（RFC6979 の決定論的 nonce・low-s・DER 符号化）
5. 署名済みトランザクションの再現（**バイト単位で完全一致**）

RFC6979 は決定論的なので、同じ鍵と同じメッセージからは必ず同じ署名になる。
したがって「署名が一致する」ことは実装全体の正しさの強い証拠になる。

## テストが実際に検出したバグ（記録）

LLM が生成したコードに対して、テストが実際に誤りを検出した記録。

| # | 検出したバグ | 内容 |
|---|---|---|
| 1 | **エントロピーのバイト順の逆転** | BIP39 の entropy 抽出が逆順になっていた。`7f7f7f...` のような同一バイトが並ぶ公式ベクタでは露見しなかった |
| 2 | **誤階層からの派生** | 非マスター鍵に `m/0'/1` を与えると 1 階層余分に潜っていた。API 側で「絶対パスはマスター鍵のみ」と制約して修正 |
| 3 | **scriptCode が 1 バイト短い** | P2WPKH の scriptCode を `19 76 a9 14 … 88`（25 バイト）と誤って実装し、`88` が `ac` に上書きされていた。BIP143 の sighash 不一致として検出 |
| 4 | **P2PK の scriptSig に push opcode が無い** | テスト側の組み立てミス。P2PK の scriptSig は「署名を push する」必要があり、`<push 72> || DER || 0x01` が正しい。署名済みトランザクションの 1 バイト不一致として検出 |
| 5 | **P2SH-P2WPKH を witness 入力として扱っていない** | `witness_utxo` を持つ P2SH 入力を「非 witness 入力」と判定し、`non_witness_utxo` を要求して署名できなくなっていた。redeemScript が P2WPKH なら witness 入力として扱うよう修正 |
| 6 | **ダングリングポインタ** | 最終化で `witness[1] = &key.public_key`（ループ内のローカル変数のアドレス）を保持していた。署名は正しいのに公開鍵だけ別の値になるという形で検出。**メモリ安全性のバグ**であり、統合テストが無ければ本番で初めて気づく類 |
| 7 | **`EcdsaSignature.data` は `r‖s` ではない** | libsecp256k1 の内部表現（この環境ではリトルエンディアン）で、`r‖s` のビッグエンディアンではない。EVM 側の実装時に気づき、`core` に `signRecoverable` を追加して extern 宣言を集約した |
| 8 | **固定長配列をハッシュしていなかった** | EIP-712 では**固定長配列も動的配列と同じく** `keccak256(要素の連結)` にする（`SomeType[5]` は 5 要素の構造体と同じ）。仕様書の該当文を確認して修正。サブケースに分割してオラクルと比較することで特定した |
| 9 | **値渡しの構造体へのスライスを返していた** | `slice(self: ParsedScript)` が値渡しのコピー（関数フレーム内）へのスライスを返しており、呼び出し元では不正な参照になっていた。**#6 と同じクラスのメモリ安全性のバグ**で、パース結果の 2 番目以降が不定値になる形で検出。`*const` 受け取りに変更して修正 |

| 10 | **オラクル（segno 1.6.6）側のパディングのバグ**（本実装のバグではない） | QR のバイトモードで、ターミネータ直後がコードワード境界のとき規格が要求しないパディングを足し、パッドコードワード `0xEC` を `0x00` に置換していた。独立実装（qrcodegen 1.8.0）と突き合わせると**本実装は一致し、segno だけが不一致**になる。上流の未修正 issue [heuer/segno#123](https://github.com/heuer/segno/issues/123) として報告されている。**オラクルが常に正しいとは限らない**ことの実例 |

| 11 | **乱数器を指すポインタを構造体に保存して返していた**（テスト側のバグ） | `std.Random` は乱数器を指すポインタを持つ。`Fuzz.init` が「乱数器＋その `Random`」を持つ構造体を**値で返して**いたため、指し先（関数内のローカル）が死に、呼び出し側では**ダングリング**していた。変異テストが TRAP で検出。**#6 / #9 と同じクラス**（一時的な値への参照を保持）で、3 回目。`Random` は使うたびに作る形に変更 |

**オラクルについて**: 独立実装との突き合わせは強力だが、#10 のように**参照側が間違っている**こともある。1 つの実装だけでなく複数（qrcodegen / python-qrcode / segno）と比較し、規格の付属資料（ISO/IEC 18004 Annex I.2 の例）でも確認する。

**メモリ安全性について**: #6 と #9 はどちらも「一時的な値への参照を保持してしまう」バグである。
Zig は値渡しが基本なので、**構造体の内部を指すスライスを返す関数は `*const` で受ける**こと、
**ループ内のローカル変数のアドレスを長生きする構造へ入れない**ことを徹底する。

**教訓**:
- 「公式ベクタが通った」だけでは不十分。同じ値が並ぶベクタは順序のバグを隠す。
- 部分的な一致（署名だけ、sighash だけ）ではなく、**最終成果物をバイト単位で比較する** テストが最も強い。
- テストが落ちたときは「実装が悪い」と決めつけず、**テスト側の前提も疑う**（#4 はテスト側の誤りだった）。
- 外部ベクタが存在しない経路（P2PKH/P2SH の最終化、手数料、お釣り判定）は、**自己整合的なデータを組み立てて** 検証する。実際に #5 と #6 はこの方法で見つかった。

## 必須テスト（今後の追加分）

| 分類 | 内容 | 合格条件 |
|---|---|---|
| PSBT 署名 | witness_utxo / non_witness_utxo からの署名 | Bitcoin Core で署名検証が通る |
| お釣り判定 | 出力が自分の鍵に属するかの判定 | 誤判定ケースで正しく拒否する |
| EVM 署名 | Legacy / EIP-1559 | viem / ethers.js の署名と**バイト単位一致** |
| EIP-712 | `domainSeparator` / `hashStruct` | 既知サンプルとの一致。未知 `verifyingContract` で警告 |
| clear signing | ERC-7730 記述子の適用 | 期待表示のスナップショット一致。chainId 不一致は拒否 |
| 異常系 | 長大な配列・深いネスト・未知セレクタ・欠落 UTXO | すべて署名拒否し、理由を画面表示 |
| 秘密の残存 | 電源断後の SD / フラッシュ | mnemonic / seed / xprv のバイト列が存在しない |
| 再現性 | イメージビルド | 2 環境で同一ハッシュ |

## 表示の回帰テスト

セキュリティ上重要なのは「正しくデコードできること」より「**警告すべきものを警告し続けること**」。
承認画面のスナップショットを固定し、以下のケースで赤警告が消えていないことを検証する。

- 無制限 `approve`（`2^256-1`）
- `setApprovalForAll`
- `permit`（EIP-2612）
- 未知コントラクト・未知セレクタ
- `to` が空（コントラクト作成）
- 過大な手数料（BTC）
- `decimals` 不明のトークン
