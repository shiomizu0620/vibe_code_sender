import 'package:flutter_test/flutter_test.dart';
import 'package:vibe_code_sender/constants.dart';
import 'package:vibe_code_sender/encoder.dart';
import 'package:vibe_code_sender/pattern_builder.dart';

/// Pulse 列を 0/1 ビット列に戻す（long=1 / short=0）。
List<int> _pulsesToBits(List<Pulse> pulses) => [
  for (final p in pulses) p == Pulse.long ? 1 : 0,
];

/// bits[start..start+width) を MSB first で整数に読む。
int _readBits(List<int> bits, int start, int width) {
  var v = 0;
  for (var i = 0; i < width; i++) {
    v = (v << 1) | bits[start + i];
  }
  return v;
}

/// テスト用の X1 ミニデコーダ（受信側仕様の独立実装）。round-trip 検証に使う。
({int scheme, int length, List<int> indices, int checksum, String url})
_decodeX1(List<Pulse> pulses) {
  final bits = _pulsesToBits(pulses);
  expect(bits[0], 1, reason: 'marker は 1（long）であるべき');
  var pos = 1;
  final scheme = _readBits(bits, pos, 1);
  pos += 1;
  final length = _readBits(bits, pos, 6);
  pos += 6;
  final indices = <int>[];
  for (var i = 0; i < length; i++) {
    indices.add(_readBits(bits, pos, 6));
    pos += 6;
  }
  final checksum = _readBits(bits, pos, 8);
  pos += 8;
  expect(pos, bits.length, reason: 'フレーム長がぴったり一致するべき');
  final body = indices.map((i) => x1CharTable[i]).join();
  final prefix = scheme == 0 ? 'https://' : 'http://';
  return (
    scheme: scheme,
    length: length,
    indices: indices,
    checksum: checksum,
    url: prefix + body,
  );
}

void main() {
  group('encode', () {
    test('F3受け入れ: encode(42) は9個の Pulse を返す', () {
      final pulses = encode(42);
      expect(pulses.length, 9);
    });

    test('encode(42) の内容（モードマーカー0 + 00101010 MSB first）', () {
      // 42 = 0b00101010
      expect(encode(42), [
        Pulse.short, // モードマーカー 0 = idモード
        Pulse.short, // bit7: 0
        Pulse.short, // bit6: 0
        Pulse.long, // bit5: 1
        Pulse.short, // bit4: 0
        Pulse.long, // bit3: 1
        Pulse.short, // bit2: 0
        Pulse.long, // bit1: 1
        Pulse.short, // bit0: 0
      ]);
    });

    test('encode(0) = short × 9（全ビット0）', () {
      expect(encode(0), List.filled(9, Pulse.short));
    });

    test('encode(255) = short + long × 8（全ビット1）', () {
      expect(encode(255), [Pulse.short, ...List.filled(8, Pulse.long)]);
    });

    test('encode(128) = short + long + short × 7（MSBのみ1）', () {
      // 128 = 0b10000000
      expect(encode(128), [
        Pulse.short,
        Pulse.long,
        Pulse.short,
        Pulse.short,
        Pulse.short,
        Pulse.short,
        Pulse.short,
        Pulse.short,
        Pulse.short,
      ]);
    });

    test('決定的: 同じ入力は常に同じ Pulse 列', () {
      expect(encode(42), encode(42));
    });

    test('id = -1 で RangeError を投げる', () {
      expect(() => encode(-1), throwsRangeError);
    });

    test('id = 256 で RangeError を投げる', () {
      expect(() => encode(256), throwsRangeError);
    });

    test('境界値: encode(0) はエラーにならない', () {
      expect(() => encode(0), returnsNormally);
    });

    test('境界値: encode(255) はエラーにならない', () {
      expect(() => encode(255), returnsNormally);
    });
  });

  group('crc8（poly=0x07 / init=0x00 / 無反転 / xorout無し）', () {
    test('空入力は 0', () {
      expect(crc8(const []), 0x00);
    });

    test('0x00 1バイトは 0', () {
      expect(crc8(const [0x00]), 0x00);
    });

    test('既知ベクタ "123456789"（ASCII）= 0xF4', () {
      // CRC-8/SMBUS の標準チェック値。
      final bytes = '123456789'.codeUnits;
      expect(crc8(bytes), 0xF4);
    });

    test('決定的: 同じ入力は常に同じ値', () {
      expect(crc8(const [6, 8, 19, 7]), crc8(const [6, 8, 19, 7]));
    });
  });

  group('encodeUrl / X1（marker=1 直接符号化）', () {
    test('先頭は marker=long（マーカー1=URL直接モード）', () {
      expect(encodeUrl('github.com').first, Pulse.long);
    });

    test('encodeUrl("github.com") のビット列が仕様通り', () {
      final pulses = encodeUrl('github.com');
      final decoded = _decodeX1(pulses);
      // g i t h u b . c o m → テーブルインデックス
      const expectedIndices = [6, 8, 19, 7, 20, 1, 36, 2, 14, 12];
      expect(decoded.scheme, 0, reason: '接頭辞なしは https(0) 既定');
      expect(decoded.length, 10);
      expect(decoded.indices, expectedIndices);
      expect(decoded.checksum, crc8(expectedIndices));
      // フレーム長 = marker(1)+scheme(1)+length(6)+chars(6*10)+checksum(8) = 76 pulse
      expect(pulses.length, 1 + 1 + 6 + 6 * 10 + 8);
    });

    test('round-trip: encodeUrl → デコードで元URLを復元（https既定）', () {
      final decoded = _decodeX1(encodeUrl('github.com'));
      expect(decoded.url, 'https://github.com');
      expect(decoded.checksum, crc8(decoded.indices)); // CRC整合
    });

    test('round-trip: https:// 接頭は scheme=0・本体のみ符号化', () {
      final decoded = _decodeX1(encodeUrl('https://example.com'));
      expect(decoded.scheme, 0);
      expect(decoded.url, 'https://example.com');
    });

    test('round-trip: http:// 接頭は scheme=1', () {
      final decoded = _decodeX1(encodeUrl('http://example.com'));
      expect(decoded.scheme, 1);
      expect(decoded.url, 'http://example.com');
    });

    test('記号入りURL（a-b.co/x_y）も round-trip する', () {
      final decoded = _decodeX1(encodeUrl('a-b.co/x_y'));
      expect(decoded.url, 'https://a-b.co/x_y');
      expect(decoded.checksum, crc8(decoded.indices));
    });

    test('決定的: 同じURLは常に同じ Pulse 列', () {
      expect(encodeUrl('github.com'), encodeUrl('github.com'));
    });

    test('未対応文字（大文字）は FormatException', () {
      expect(() => encodeUrl('Github.com'), throwsFormatException);
    });

    test('本体63文字超は ArgumentError', () {
      final tooLong = 'a' * (x1MaxLength + 1);
      expect(() => encodeUrl(tooLong), throwsArgumentError);
    });

    test('本体ちょうど63文字は OK', () {
      final maxBody = 'a' * x1MaxLength;
      expect(() => encodeUrl(maxBody), returnsNormally);
      expect(_decodeX1(encodeUrl(maxBody)).length, x1MaxLength);
    });

    test('回帰: marker=0（idモード）の出力は従来と完全一致', () {
      // X1追加で encode(id) が壊れていないこと。
      expect(encode(42).first, Pulse.short);
      expect(encode(42), [
        Pulse.short,
        Pulse.short,
        Pulse.short,
        Pulse.long,
        Pulse.short,
        Pulse.long,
        Pulse.short,
        Pulse.long,
        Pulse.short,
      ]);
    });
  });
}
