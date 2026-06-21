# vibe_code_sender（送信側 / sender）

スマホの振動でURLを送る「**バイブコード**」の**送信側**アプリ（Flutter）。短い振動と長い振動の組み合わせでパターンを出力し、受信側（別リポジトリ・PC/Python）がそれを検知してURLを開く。

URL本体は送らず、**Supabaseで割り当てた数値idだけを振動で送る**方式。受信側がidを復元してDBからURLを引く。同じ信号は**人間が「短/長」で打ち返しても、機械がセンサーで復調しても**読める（QRと同じことを振動でやる）。

## 構成

- **送信側（このリポジトリ）**: Flutter。数値id → 振動パターンに符号化して出力する。
- **受信側（別リポジトリ）**: PC/Python。マイク・加速度センサー等で振動を検知し、復号してURLを開く。

設計・方針は **`CLAUDE.md`**、プロトコル定数は **`PROTOCOL.md`**、作業タスクは **`docs/ISSUES.md`** を参照。

## 主な機能

- **URL登録・一覧（Supabase連携）**: URLを登録すると 0〜255 の空きidをランダムに発行。一覧から選んで演奏画面へ。
- **楽譜表示**: idを「●（短）/ ━（長）」の記号列で表示し、演奏位置をカーソルで追う。
- **手動演奏モード ★体験のコア**: 「短/長」ボタンで人間が1打ずつ打つ。各打は固定長で振動し、楽譜に対するミスも記録される（プリアンブルは開始時に自動送出）。
- **自動演奏モード**: プリアンブル込みのフル信号を機械精度で一括再生（デモ保険・受信側チューニングの基準）。
- **リズムゲーム**: 飛んでくるノーツをタイミングよく叩く演出付きモード（Perfect/Good/Miss 判定、オシロスコープ風UI）。

## ディレクトリ構成（lib/）

```text
lib/
  constants.dart         共有タイミング定数（150/450/150ms, プリアンブル[700,200]×2）
  encoder.dart           id(0..255) → モードマーカー + 8bit(MSB first) の Pulse 列
  pattern_builder.dart   Pulse 列 → 振動パターン配列、プリアンブル付与
  vibrator_service.dart  hasVibrator チェック + 生パターン再生 play()
  supabase_service.dart  urls テーブルへの登録 / id発行 / 一覧取得
  score_view.dart        楽譜表示（●/━・カーソル・ミス表示）
  game_logic.dart        リズムゲームの譜面生成・実時間クロック・判定（純粋ロジック）
  game_view.dart         リズムゲームの描画（ノーツ・波形ガイド）
  main.dart              URL一覧 / 演奏画面 / タブ結合
```

## セットアップ

必要なもの: Flutter SDK（stable）。Android実機（推奨）。iOSは Mac + Xcode。

```bash
flutter pub get
```

### Supabase 接続情報を渡す

キーはコミットしない。`env.example.json` をコピーして `env.json`（gitignore対象）を作り、anon key を記入する。

```bash
cp env.example.json env.json   # SUPABASE_URL / SUPABASE_ANON_KEY を記入
flutter run --dart-define-from-file=env.json   # Android実機を接続して実行
```

接続情報が未設定／初期化失敗のときは案内画面で起動を継続する（アプリは落ちない）。
> anon key のみ埋め込み可。service_role key は絶対に持ち込まない（`CLAUDE.md` セキュリティ方針）。

### プラットフォーム注意

- **Android**: `android/app/src/main/AndroidManifest.xml` に `VIBRATE` 権限が必要（設定済み）。
- **iOS**: Mac で `flutter run`（`pod install` は自動）。Xcode で署名設定（Apple ID）。振動に特別な権限は不要。
- **注意**: エミュレータ／シミュレータでは起動するが**物理的に振動しない**。実機で確認すること。

## テスト

DSP・符号化・判定などの純粋ロジックは実機なしでテストできる。

```bash
flutter test
```

`test/` に encoder / pattern_builder / vibrator_service / game_logic / supabase_service のユニットテストがある。

## プロトコル（共有仕様）

プロトコル定数の唯一の正は **`PROTOCOL.md`**。送信側・受信側・人間入力のすべてがこの1ファイルに合わせる。
定数（短長の意味・タイミング・プリアンブル・idビット長・MSB first 等）は README に二重に書かない。**`PROTOCOL.md` を見ること。**

## 関連

- プロトコル仕様（唯一の正）: `PROTOCOL.md`
- 設計憲法: `CLAUDE.md`
- タスク一覧（起票用）: `docs/ISSUES.md`
- 受信側リポジトリ: （URLを記載）
