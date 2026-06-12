import 'package:flutter_test/flutter_test.dart';
import 'package:vibe_code_sender/constants.dart';
import 'package:vibe_code_sender/pattern_builder.dart';

void main() {
  group('buildPattern（データ音のみ）', () {
    test('空の Pulse 列は初期待機0のみ', () {
      expect(buildPattern([]), [0]);
    });

    test('単発: short は [0, 150]', () {
      expect(buildPattern([Pulse.short]), [0, shortMs]);
    });

    test('単発: long は [0, 450]', () {
      expect(buildPattern([Pulse.long]), [0, longMs]);
    });

    test('F2受け入れ例: [short, long, short]', () {
      // 初期待機0 / 短150 / gap150 / 長450 / gap150 / 短150
      expect(buildPattern([Pulse.short, Pulse.long, Pulse.short]), [
        0,
        150,
        150,
        450,
        150,
        150,
      ]);
    });

    test('決定的: 同じ入力は常に同じ配列', () {
      final a = buildPattern([Pulse.long, Pulse.short]);
      final b = buildPattern([Pulse.long, Pulse.short]);
      expect(a, b);
    });
  });

  group('buildPreamble', () {
    test('[700,200]×2 を生成（末尾はOFF）', () {
      expect(buildPreamble(), [0, 700, 200, 700, 200]);
    });

    test('constants と整合している', () {
      expect(buildPreamble(), [
        0,
        preambleOnMs,
        preambleOffMs,
        preambleOnMs,
        preambleOffMs,
      ]);
    });
  });

  group('buildSignal（プリアンブル + データ音）', () {
    test('F2受け入れ例: [short, long, short] にプリアンブルが付く', () {
      expect(buildSignal([Pulse.short, Pulse.long, Pulse.short]), [
        0,
        700,
        200,
        700,
        200,
        150,
        150,
        450,
        150,
        150,
      ]);
    });

    test('プリアンブル直後にデータ音が続き、待ちが二重にならない', () {
      final signal = buildSignal([Pulse.short]);
      // [0, 700, 200, 700, 200, 150]
      expect(signal, [
        0,
        preambleOnMs,
        preambleOffMs,
        preambleOnMs,
        preambleOffMs,
        shortMs,
      ]);
    });

    test('プリアンブル部分は buildPreamble と一致する', () {
      final signal = buildSignal([Pulse.long, Pulse.short]);
      expect(signal.sublist(0, buildPreamble().length), buildPreamble());
    });
  });
}
