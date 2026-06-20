# Claude Code 指示書: 演奏UI（maimai版）のGitHub issueを起票

## ゴール
リポジトリ **`shiomizu0620/vibe_code_sender`**（Flutter送信側）に、演奏UIゲーム化のissueを
**A-G, F10, F11, F12, F13** の5本、下記の内容で起票する。

## やること / やらないこと
- やる: `gh issue create` でissueを作るだけ。ラベルが無ければ作る。最後に作成したissueのURLを一覧で出す。
- やらない: コードの変更・ブランチ作成・PR・push は一切しない。issue起票のみ。

## 事前確認
1. `gh auth status` と `gh repo view shiomizu0620/vibe_code_sender` で認証と対象repoを確認。
2. 以下のラベルを `gh label list -R shiomizu0620/vibe_code_sender` で確認し、無いものだけ `gh label create` で作成:

| label | color | 用途 |
|---|---|---|
| `rhythm-game` | 8957e5 | 演奏UIエピック共通 |
| `UI` | 0969da | 表示・描画 |
| `logic` | 1a7f37 | ロジック・判定・振動制御 |
| `animation` | bf8700 | アニメーション |
| `stretch` | 6e7781 | 余裕があれば |
| `Lv1` | cf222e | デモ必須 |
| `Lv2` | bc4c00 | 音ゲーらしさ |
| `Lv3` | 9a6700 | 受信連動 |

## 起票の順番と依存
依存解決のため **A-G → F10 → F11 → F12 → F13** の順で作る。
各bodyの「依存」は F番号で書いてある。作成後、可能なら実際のissue番号（#N）をbody末尾に追記してクロスリンクする（任意）。

## assignee について
A・BのGitHubハンドルが不明なので、デフォルトでは assignee を付けない（bodyの「担当」で示す）。
もしユーザーがハンドルを指定したら `--assignee <handle>` を付ける。

---

## 起票するissue（タイトル / ラベル / body）

### ① A-G
- title: `A-G: [Logic] 譜面生成・ゲームクロック・判定・振動タイマ`
- labels: `rhythm-game,logic,Lv2`
- body:
```
担当: A（ロジック）
触ってよい: lib/game_logic.dart(新規), lib/main.dart（配線は最小限、B/Aで調整）

## 概要
演奏ゲームの心臓部。UIから独立した、譜面・クロック・判定・振動制御を担う。
★鉄則: 振動の正確さが最優先。描画フレームに依存させず、実時間タイマで固定長を出す。

## 実装内容
- pulse列（プリアンブル=長2連 → モードマーカー1bit → id 8bit, MSB first）→ Note列を生成。
  各Noteは type(tap/hold), bit, hitTimeMs, durationMs, angle を持ち、**シンボル間にOFF(休符)を必ず入れる**。
- ゲームクロック（Ticker/AnimationController で時刻を進める。再生/一時停止/リセット）。
- 判定: 入力down/upの時刻と hitTime/duration の差で Perfect/Good/Miss。判定窓は定数化（例 Perfect±40ms / Good±90ms）。
- 振動トリガ: 判定OK時に固定長(短150ms/長450ms)をタイマで一発。**描画と独立**。
- モード切替トグル: ハイブリッド（実入力が振動を出す）/ オート（譜面通りに振動）。オートはデモ保険。

## 受け入れ
- ユニットテスト: id→正しいNote列が生成される / 判定窓の境界で Perfect↔Good↔Miss が切り替わる。
- 実機で短/長が正確な長さ(150/450ms)で振動する。

## 依存
F2, F3（譜面=pulse列の生成元）／ F1（振動の基盤＝固定長タイマ）
```

### ② F10
- title: `F10: [UI] maimai風ゲーム画面の静的レイアウト構築`
- labels: `rhythm-game,UI,Lv2`
- body:
```
担当: B（UI）
触ってよい: lib/game_view.dart(新規), lib/main.dart

## 概要
動きや判定はまだ入れず、音ゲー画面の「ガワ（背景＋判定リング）」だけを作る。

## 実装内容
- 画面中央に大きな円（判定リング）を描画。
- 既存のシンプルな演奏画面と新ゲーム画面を切り替え可能にする（タブ/トグル等）。
- 世界観はダーク&ネオン。受信側オシロとトーンを合わせる。

## 受け入れ
アプリ起動→id入力で「中心に大きな円があるだけの画面」が表示される。

## 依存
F4
```

### ③ F11
- title: `F11: [Animation] ノーツ移動アニメ（譜面は注入式 / 見るだけ）`
- labels: `rhythm-game,animation,UI,Lv2`
- body:
```
担当: B（UI）
触ってよい: lib/game_view.dart

## 概要
F10の画面上で、ノーツが中心→外周リングへ飛んでくる動きを作る。ユーザー操作はまだ不要。
※ 譜面（ノーツ列）は**外から渡す注入式**にする。今は `_pulses`(F2/F3) ＋ 簡易クロックで先行してよい。
　後でA-Gの譜面に差し替えるだけにすれば、F12で判定/振動と同じ時計に乗り、手戻りが出ない。

## 実装内容
- AnimationController を導入。
- 短=丸(アンバー)/長=星＋尾(シアン) を、中心から外周リングへ一定速度で移動させる。
- 角度バリエーションでmaimai感を出す。
- 【Lv1必須をここで満たす】下部に演奏ガイド＋波形プレビュー（短/長が積み上がる、受信側オシロと同色）を表示。

## 受け入れ
- 演奏開始ボタンで、idに応じた数のノーツが中心→リングへ次々飛び、リング外へ消える様子が見える。
- 波形プレビューが演奏内容に対応して表示される。

## 依存
F10（譜面は注入式。`_pulses`=F2/F3 で先行可、後でA-Gに差し替え）
```

### ④ F12
- title: `F12: [Interaction] タップ/ホールド判定と振動の結合（短・長コア）`
- labels: `rhythm-game,UI,logic,Lv2`
- body:
```
担当: B（入力/描画）＋ A（判定/振動）
触ってよい: lib/game_view.dart, lib/game_logic.dart, lib/main.dart

## 概要
飛んでくるノーツに合わせて操作し、実際に振動させてゲームとして成立させる。
**短(0)も長(1)もここでコア完成**（プリアンブルが長2連なので、長を後回しにすると送信列が作れない）。

## 実装内容
- B: GestureDetector でタップ(down/up)・長押しを検知し、A-Gの onInput に渡す。判定OKでノーツを消す（Missは通過）。
- A: 受け取った入力を判定し、**固定長の振動(150/450ms)をタイマで発火**（★描画/ジェスチャ保持時間に依存させない）。

## 受け入れ
- 短(●)ノーツがリングに来た瞬間にタップ→短振動が出てノーツが消える。
- 長(━)ノーツでホールド→長振動(450ms固定)が出てノーツが消える。
- 一通り正確に演奏すると、受信側で復号できる正しいpulse列になる。

## 依存
F11, F5, A-G
```

### ⑤ F13
- title: `F13: [Stretch/UX] スライド軌跡と演出強化（見た目のみ）`
- labels: `rhythm-game,UI,stretch,Lv3`
- body:
```
担当: B（UI）
触ってよい: lib/game_view.dart

## 概要
アーケードライクな「なぞる」軌跡と、気持ちいい演出を追加する。**capabilityはF12で完成済み。ここは見た目の強化のみ。**
※ 振動の長さはF12の固定長タイマのまま。なぞり時間で振動長を変えない（受信精度を守る）。

## 実装内容
- 長パルス用のスライド軌跡（光る帯）を CustomPaint で描画。
- タップ成功時「PERFECT!」表示、コンボ数のカウント＆表示。

## 受け入れ
- スライドノーツの軌跡演出が見え、プレイ中にコンボ数などの演出が表示される。

## 依存
F12
```

---

## 仕上げ
- 5本作成後、`gh issue list -R shiomizu0620/vibe_code_sender --label rhythm-game` で確認し、作成URLを一覧で出力する。
- （任意）`rhythm-game` を束ねる親issueやmilestone「演奏UI」を作りたい場合は提案してから作る。
