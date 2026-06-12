import 'package:flutter_test/flutter_test.dart';
import 'package:vibe_code_sender/vibrator_service.dart';

void main() {
  group('VibratorService コンストラクタの amplitude 範囲検証', () {
    test('既定値（255）で生成できる', () {
      expect(VibratorService().amplitude, 255);
    });

    test('範囲内（1〜255）は許容', () {
      expect(VibratorService(amplitude: 1).amplitude, 1);
      expect(VibratorService(amplitude: 128).amplitude, 128);
      expect(VibratorService(amplitude: 255).amplitude, 255);
    });

    test('0 は ArgumentError', () {
      expect(() => VibratorService(amplitude: 0), throwsArgumentError);
    });

    test('負数は ArgumentError', () {
      expect(() => VibratorService(amplitude: -1), throwsArgumentError);
    });

    test('256 以上は ArgumentError', () {
      expect(() => VibratorService(amplitude: 256), throwsArgumentError);
      expect(() => VibratorService(amplitude: 1000), throwsArgumentError);
    });
  });
}
