import 'constants.dart';
import 'pattern_builder.dart';

/// id(0..255) を [Pulse] 列に変換する（モードマーカー + 8bit MSB first）。
///
/// フレーム構成（PROTOCOL.md v1.0 idモード）:
///   [モードマーカー 0=short] + [id 8bit MSB first] → 計9打
///
/// id が 0〜255 の範囲外の場合は [RangeError] を投げる。
List<Pulse> encode(int id) {
  if (id < 0 || id > 255) {
    throw RangeError.range(id, 0, 255, 'id');
  }
  return [
    Pulse.short, // モードマーカー 0 = idモード
    for (var i = 7; i >= 0; i--) (id >> i) & 1 == 1 ? Pulse.long : Pulse.short,
  ];
}

/// URL文字列を X1（直接符号化モード, marker=1）の [Pulse] 列に変換する。
///
/// フレーム構成（PROTOCOL.md v1.1 X1モード, 各フィールド MSB first）:
///   [marker=1=long] [scheme 1bit] [length 6bit] [chars: length×6bit] [checksum 8bit]
///   - scheme   : 0=https / 1=http
///   - length   : chars 文字数（最大 [x1MaxLength]=63）
///   - chars    : 1文字=6bit。[x1CharTable] のインデックス
///   - checksum : chars のインデックスバイト列に対する CRC-8（[crc8]）。検出のみ
///
/// [url] が `https://` / `http://` で始まる場合は scheme を判定して接頭辞を取り除く。
/// それ以外は scheme=0（https）扱いで全体を本体とする。
///
/// [x1CharTable] に無い文字（大文字・レア記号など）が含まれる場合は [FormatException]、
/// 本体長が [x1MaxLength] を超える場合は [ArgumentError] を投げる。
List<Pulse> encodeUrl(String url) {
  // 1. スキーム判定 → 本体を取り出す。
  int scheme;
  String body;
  if (url.startsWith('https://')) {
    scheme = 0;
    body = url.substring('https://'.length);
  } else if (url.startsWith('http://')) {
    scheme = 1;
    body = url.substring('http://'.length);
  } else {
    scheme = 0; // 既定は https
    body = url;
  }

  // 2. 本体各文字 → 6bit インデックス。
  final indices = <int>[];
  for (var i = 0; i < body.length; i++) {
    final ch = body[i];
    final idx = x1CharTable.indexOf(ch);
    if (idx < 0) {
      throw FormatException('X1で符号化できない文字: "$ch"（小文字URLのみ対応）', url, i);
    }
    indices.add(idx);
  }

  // 3. 長さチェック（length は 6bit）。
  if (indices.length > x1MaxLength) {
    throw ArgumentError.value(
      indices.length,
      'url',
      'X1の本体長は最大 $x1MaxLength 文字（6bit length）',
    );
  }

  // 4. checksum = chars インデックスバイト列の CRC-8。
  final checksum = crc8(indices);

  // 5. ビット列を MSB first で Pulse 列に組み立てる。
  final pulses = <Pulse>[Pulse.long]; // marker=1 = URL直接モード
  _appendBits(pulses, scheme, 1);
  _appendBits(pulses, indices.length, 6);
  for (final idx in indices) {
    _appendBits(pulses, idx, 6);
  }
  _appendBits(pulses, checksum, 8);
  return pulses;
}

/// CRC-8（poly=[x1CrcPoly]=0x07 / init=0x00 / 無反転 / xorout無し）。
///
/// [bytes] の各要素を1バイト（下位8bit）として MSB first で処理する。
/// X1 では chars の6bitインデックス値（0〜63）を1バイトずつ通す。
int crc8(List<int> bytes) {
  var crc = 0;
  for (final b in bytes) {
    crc ^= b & 0xFF;
    for (var i = 0; i < 8; i++) {
      if (crc & 0x80 != 0) {
        crc = ((crc << 1) ^ x1CrcPoly) & 0xFF;
      } else {
        crc = (crc << 1) & 0xFF;
      }
    }
  }
  return crc;
}

/// [value] の下位 [width] bit を MSB first で [out] に Pulse として追加する。
/// bit=1 → [Pulse.long] / bit=0 → [Pulse.short]。
void _appendBits(List<Pulse> out, int value, int width) {
  for (var i = width - 1; i >= 0; i--) {
    out.add((value >> i) & 1 == 1 ? Pulse.long : Pulse.short);
  }
}
