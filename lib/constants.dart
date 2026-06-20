/// 送受信で厳密に一致させる共有タイミング定数（ミリ秒）。
///
/// 受信側（別リポジトリ・PC/Python）と必ず同じ値を共有すること。
/// ここを変更したら受信側のデコード閾値も合わせて見直すこと。
library;

/// 短い振動の長さ。符号上は 0 を表す。
const int shortMs = 150;

/// 長い振動の長さ。符号上は 1 を表す。
const int longMs = 450;

/// 音と音の間（無振動）の長さ。
const int gapMs = 150;

/// プリアンブル1発の振動長（ON）。
///
/// 長(450ms)との混同を避けるため、データ音より明確に長くしてある。
/// 受信側はこの 700ms 級の ON を信号開始の目印にする。
const int preambleOnMs = 700;

/// プリアンブルの振動と振動の間（無振動・OFF）の長さ。
const int preambleOffMs = 200;

/// プリアンブルの繰り返し回数。
///
/// `[preambleOnMs ON, preambleOffMs OFF]` をこの回数だけ繰り返す
/// （PROTOCOL.md v1.0: `[700ms ON, 200ms OFF] × 2`）。
const int preambleRepeat = 2;

/// X1（URL直接符号化モード）の6bit文字テーブル。【受信側と完全一致させること】
///
/// PROTOCOL.md v1.1。文字 → このテーブル内の位置（0〜58）が 6bit インデックス。
///   idx 0–25  = a–z
///   idx 26–35 = 0–9
///   idx 36–58 = `. - _ ~ : / ? # [ ] @ ! $ & ' ( ) * + , ; = %`（この順で23個）
///   idx 59–63 = 予約（このテーブルには含めない）
///
/// 対応外文字（大文字・レア記号）はデモURLで避ける（小文字前提）。
const String x1CharTable =
    "abcdefghijklmnopqrstuvwxyz0123456789.-_~:/?#[]@!\$&'()*+,;=%";

/// X1 checksum に用いる CRC-8 の生成多項式（poly=0x07, init=0x00, 無反転, xorout無し）。
const int x1CrcPoly = 0x07;

/// X1 の chars 最大文字数（length フィールドは 6bit のため 63 まで）。
const int x1MaxLength = 63;
