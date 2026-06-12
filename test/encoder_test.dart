import 'package:flutter_test/flutter_test.dart';
import 'package:vibe_code_sender/encoder.dart';
import 'package:vibe_code_sender/pattern_builder.dart';

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
        Pulse.long,  // bit5: 1
        Pulse.short, // bit4: 0
        Pulse.long,  // bit3: 1
        Pulse.short, // bit2: 0
        Pulse.long,  // bit1: 1
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
}
