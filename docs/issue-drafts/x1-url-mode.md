# Claude Code 指示書: X1（URL直接モード / "純QR"）のGitHub issue起票

## ゴール
プロトコル v1.1 として **X1＝URL直接符号化モード** を入れる。
issueを2本起票する：
- **X1-send** → `shiomizu0620/vibe_code_sender`（送信encoder・担当A）
- **X1-recv** → `shiomizu0620/vibe-receiver`（受信decoder＋運命サイト・担当 自分）

## やること / やらないこと
- やる: `gh issue create` でissueを作るだけ。ラベルが無ければ作る。最後にURLを出す。
- やらない: コード変更・PR・push は一切しない。起票のみ。

## ラベル（無ければ作成）
| label | color | 用途 |
|---|---|---|
| `X1` | e8590c | URL直接モード |
| `protocol` | 5f3dc4 | プロトコル変更(v1.1) |
| `logic` | 1a7f37 | ロジック |
| `receiver` | 0969da | 受信側 |
| `stretch` | 6e7781 | 余裕があれば |

---

## 共有仕様（PROTOCOL v1.1 / X1）※両issueが参照
フレーム（マーカー=1のとき）。各フィールド MSB first：

```
[プリアンブル 長×2] [marker=1] [scheme 1bit] [length 6bit] [chars: length×6bit] [checksum 8bit]
```

- **marker=1** … URL直接モード（marker=0 は従来のid方式＝無変更）
- **scheme** … 0=https / 1=http
- **length** … 文字数（最大63。X1は短URL専用）
- **chars** … 1文字=6bit。下記64種テーブルのインデックス
- **checksum** … 本体(chars)に対する **CRC-8**（poly 0x07）。※sum mod 256 でも可。**検出のみ・訂正はしない**

**6bit文字テーブル（送受信で完全一致させる）**
- idx 0–25 = `a`–`z`
- idx 26–35 = `0`–`9`
- idx 36–58 = `. - _ ~ : / ? # [ ] @ ! $ & ' ( ) * + , ; = %`（この順で23個）
- idx 59–63 = 予約
- 対応外文字（大文字・レア記号）はデモURLで避ける（小文字前提）。シフト符号は後回し。

**失敗時の挙動（方針b・確定）**
- checksum OK → `scheme://` ＋ 復元文字列 を開く
- checksum NG → 「ミスったので運命のサイトへ🎲」表示 ＋ **FUN_SITES** からランダムで1つ開く
  - FUN_SITES＝安全で笑える定番サイトを5〜10個、チームで選定（受信側に定数リスト）

**演奏方法**
- 自動演奏X1 … 機械が完璧に弾く＝必ず成功（確実な見せ方）
- 人間演奏X1 … 音ゲーで長い曲として叩く＝たまに失敗→運命サイトが発動（ネタの見せ場）
- F11は注入式なので、可変長のX1パルス列もそのまま流せる

---

## 起票するissue

### ① X1-send  （repo: shiomizu0620/vibe_code_sender）
- title: `X1-send: [Encoder] URL直接モード（v1.1・マーカー=1）`
- labels: `X1,protocol,logic`
- body:
```
担当: A（ロジック）
触ってよい: lib/encoder.dart（拡張）, lib/constants.dart（6bitテーブル）, lib/main.dart（モード選択UI最小）

## 概要
URL文字列を直接ビット列に符号化するX1モードを追加（マーカー=1）。
従来のid方式（マーカー=0）は一切壊さない。誤り訂正はやらない／チェックサム(検出)のみ。

## 実装内容
- PROTOCOL.md を v1.1 に更新（上の共有仕様のX1フレームを追記）
- lib/constants.dart に 6bit文字テーブル（a-z,0-9,記号23種）
- encoder拡張: URL文字列 → scheme(1)+length(6)+chars(6×n)+CRC-8(8) → パルス列、marker=1
- モード選択（id方式 ↔ URL直接）をUIに最小で追加
- 自動演奏／音ゲー(F11注入式) 両対応で出力

## 受け入れ
- 短URL（例 "github.com"）を入力 → X1フレーム生成 → 自動演奏で受信側が同じURLを復元
- encode→decode の round-trip ユニットテスト（少なくとも送信側のencode結果がビット列として仕様通り）
- marker=0（id方式）の出力は従来と完全一致（回帰なし）

## 依存
既存 encoder（id方式）, F11（注入式・可変長対応）, X1-recv とフレーム形式を一致
```

### ② X1-recv  （repo: shiomizu0620/vibe-receiver）
- title: `X1-recv: [Decoder] URL直接モードの復号＋運命サイト`
- labels: `X1,protocol,receiver`
- body:
```
担当: 自分（受信）
触ってよい: src/ のdecoder（X1分岐追加）, src/main.py（オープン処理）, fun_sites 定数

## 概要
マーカー=1のとき可変長X1ペイロードを復号。checksumを検証し、
OKならURLを開く／NGなら「運命のサイト🎲」をランダムで開く（方針b）。

## 実装内容
- マーカー分岐: 0=既存id方式（無変更）, 1=X1
- X1復号: scheme(1)+length(6)+chars(length×6, 6bitテーブル逆引き)+CRC-8(8) を読み出し
- checksum検証:
  - OK → `scheme://`＋復元文字列 をブラウザで開く
  - NG → 「ミスったので運命のサイトへ🎲」表示 ＋ FUN_SITES からランダムで1つ開く
- FUN_SITES: 安全で笑える定番サイト 5〜10個の定数リスト（チームで選定）
- 既存の演出（オシロ/rich）にも乗せる

## 受け入れ
- 正しいX1フレーム → 該当URLが開く
- わざとビットを数個反転 → checksum NG → 運命サイトが開く（誤り注入テスト）
- marker=0（id方式）の復号は従来と完全一致（回帰なし）

## 依存
既存 decoder（id方式）, X1-send とフレーム形式を一致
```

---

## 仕上げ
- 2本作成後、それぞれの repo で `gh issue list --label X1` を確認し、作成URLを一覧で出力。
