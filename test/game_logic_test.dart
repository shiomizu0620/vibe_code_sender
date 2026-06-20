import 'package:flutter_test/flutter_test.dart';
import 'package:vibe_code_sender/constants.dart';
import 'package:vibe_code_sender/encoder.dart';
import 'package:vibe_code_sender/game_logic.dart';
import 'package:vibe_code_sender/pattern_builder.dart';

void main() {
  group('buildChartFromPulses（pulse列 → Note列）', () {
    test('回帰: buildChart(id) は buildChartFromPulses(encode(id)) と一致', () {
      expect(
        buildChart(42).toString(),
        buildChartFromPulses(encode(42)).toString(),
      );
    });

    test('X1 可変長 pulse 列も譜面化できる（プリアンブル + 各pulse）', () {
      final pulses = encodeUrl('github.com');
      final notes = buildChartFromPulses(pulses);
      expect(notes.length, preambleRepeat + pulses.length);
      // 先頭はプリアンブル、その後はデータ音
      expect(notes.first.isPreamble, isTrue);
      expect(notes[preambleRepeat].isPreamble, isFalse);
      // X1 先頭データ音は marker=long → bit=1
      expect(pulses.first, Pulse.long);
      expect(notes[preambleRepeat].bit, 1);
    });
  });

  group('buildChart（id → Note列）', () {
    test('音数 = プリアンブル2 + モードマーカー1 + id8 = 11', () {
      expect(buildChart(42).length, preambleRepeat + 9);
    });

    test('先頭2音はプリアンブル（700ms / hold / bit=null）', () {
      final notes = buildChart(0);
      for (var i = 0; i < preambleRepeat; i++) {
        expect(notes[i].isPreamble, isTrue);
        expect(notes[i].durationMs, preambleOnMs);
        expect(notes[i].type, NoteType.hold);
        expect(notes[i].bit, isNull);
      }
    });

    test('プリアンブルの hitTime は 0 と 900（700+200）', () {
      final notes = buildChart(0);
      expect(notes[0].hitTimeMs, 0);
      expect(notes[1].hitTimeMs, preambleOnMs + preambleOffMs); // 900
    });

    test('モードマーカー（index2）は短押し・bit0・hit=1800', () {
      final notes = buildChart(42);
      final marker = notes[preambleRepeat];
      expect(marker.isPreamble, isFalse);
      expect(marker.bit, 0);
      expect(marker.type, NoteType.tap);
      expect(marker.durationMs, shortMs);
      // プリアンブル全長 = (700+200)*2 = 1800
      expect(marker.hitTimeMs, (preambleOnMs + preambleOffMs) * preambleRepeat);
    });

    test('id=42 のデータビットが MSB first で正しい', () {
      // 42 = 0b00101010 → [0,0,1,0,1,0,1,0]
      final notes = buildChart(42);
      final dataBits = notes
          .where((n) => !n.isPreamble)
          .map((n) => n.bit)
          .toList();
      // モードマーカー0 + idビット
      expect(dataBits, [0, 0, 0, 1, 0, 1, 0, 1, 0]);
    });

    test('bit0→tap/150ms、bit1→hold/450ms', () {
      final notes = buildChart(42).where((n) => !n.isPreamble);
      for (final n in notes) {
        if (n.bit == 1) {
          expect(n.type, NoteType.hold);
          expect(n.durationMs, longMs);
        } else {
          expect(n.type, NoteType.tap);
          expect(n.durationMs, shortMs);
        }
      }
    });

    test('hitTime は単調増加し、各音 = 前音の hit + dur + 休符', () {
      final notes = buildChart(123);
      for (var i = 1; i < notes.length; i++) {
        expect(notes[i].hitTimeMs, greaterThan(notes[i - 1].hitTimeMs));
      }
      // プリアンブル直後のデータ先頭は短押し（モードマーカー）→ 次は +150+150
      final markerIdx = preambleRepeat;
      expect(
        notes[markerIdx + 1].hitTimeMs - notes[markerIdx].hitTimeMs,
        shortMs + gapMs,
      );
    });

    test('決定的: 同じ id は常に同じ譜面', () {
      expect(buildChart(200).toString(), buildChart(200).toString());
    });
  });

  group('judgeHit（判定窓の境界）', () {
    test('差0は Perfect', () {
      expect(judgeHit(1000, 1000), Judgement.perfect);
    });

    test('Perfect の境界 ±40ms は Perfect、±41ms は Good', () {
      expect(judgeHit(1000, 1000 + perfectWindowMs), Judgement.perfect); // +40
      expect(judgeHit(1000, 1000 - perfectWindowMs), Judgement.perfect); // -40
      expect(judgeHit(1000, 1000 + perfectWindowMs + 1), Judgement.good); // +41
      expect(judgeHit(1000, 1000 - perfectWindowMs - 1), Judgement.good); // -41
    });

    test('Good の境界 ±90ms は Good、±91ms は Miss', () {
      expect(judgeHit(1000, 1000 + goodWindowMs), Judgement.good); // +90
      expect(judgeHit(1000, 1000 - goodWindowMs), Judgement.good); // -90
      expect(judgeHit(1000, 1000 + goodWindowMs + 1), Judgement.miss); // +91
      expect(judgeHit(1000, 1000 - goodWindowMs - 1), Judgement.miss); // -91
    });
  });
}
