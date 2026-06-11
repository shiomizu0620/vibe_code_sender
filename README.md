# vibe_code_sender（送信側 / sender）

スマホの振動でURLを送る「**バイブコード**」の**送信側**アプリ（Flutter）。短い振動と長い振動の組み合わせでパターンを出力し、受信側（別リポジトリ・PC/Python）がそれを検知してURLを開く。

URL本体は送らず、**Supabaseで割り当てた数値idだけを振動で送る**方式。受信側がidを復元してDBからURLを引く。同じ信号は**人間が「短/長」で打ち返しても、機械がセンサーで復調しても**読める（QRと同じことを振動でやる）。

## 構成
- **送信側（このリポジトリ）**: Flutter。振動パターンを出力する。
- **受信側（別リポジトリ）**: PC/Python。マイク・加速度センサー等で振動を検知し、復号してURLを開く。

設計・方針は **`CLAUDE.md`**、プロトコル定数は **`PROTOCOL.md`**、各作業タスクは **`docs/INSTRUCTIONS_*.md`** を参照。

## セットアップ
必要なもの: Flutter SDK（stable）。Android実機（推奨）。iOSは Mac + Xcode。

```bash
flutter pub get
flutter run        # Android実機を接続して実行
```

- **Android**: `android/app/src/main/AndroidManifest.xml` に `VIBRATE` 権限が必要（設定済み）。
- **iOS**: Mac で `flutter run`（`pod install` は自動）。Xcode で署名設定（Apple ID）。振動に特別な権限は不要。
- **注意**: エミュレータ／シミュレータでは起動するが**物理的に振動しない**。実機で確認すること。

## 現在の状況（STATUS）
進行に合わせて更新する。現在の作業対象は `docs/INSTRUCTIONS_*.md` を参照。

- [x] リポジトリ初期化・環境構築（VIBRATE権限追加済み）
- [ ] **M1**: 短/長の振動を任意の並びで出力（テストUI）
- [ ] **M2**: encoder 実装（数値id → ビット列 → 振動パターン、プリアンブル付与）
- [ ] **M3**: Supabase連携（URL登録→id発行、id→URL逆引き）・受信側との結合

## プロトコル（共有仕様）
プロトコル定数の唯一の正は **`PROTOCOL.md`**。送信側・受信側・人間入力のすべてがこの1ファイルに合わせる。
定数（短長の意味・タイミング・プリアンブル・idビット長・MSB first 等）は README に二重に書かない。**`PROTOCOL.md` を見ること。**

## 関連
- プロトコル仕様（唯一の正）: `PROTOCOL.md`
- 設計憲法: `CLAUDE.md`
- タスク指示: `docs/INSTRUCTIONS_milestone*.md`
- 受信側リポジトリ: （URLを記載）
