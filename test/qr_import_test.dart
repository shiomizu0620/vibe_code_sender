import 'package:flutter_test/flutter_test.dart';
import 'package:vibe_code_sender/constants.dart';
import 'package:vibe_code_sender/qr_import_view.dart';

void main() {
  group('classifyScannedText', () {
    test('短い小文字URLは X1（自己完結）に振り分ける', () {
      final r = classifyScannedText('https://github.com');
      expect(r, isA<QrX1>());
      expect((r as QrX1).url, 'https://github.com');
    });

    test('スキーム省略のドメインも X1 として許容する', () {
      expect(classifyScannedText('github.com/a'), isA<QrX1>());
    });

    test('前後の空白は trim される', () {
      final r = classifyScannedText('  github.com  ');
      expect(r, isA<QrX1>());
      expect((r as QrX1).url, 'github.com');
    });

    test('X1上限を超える長URLは id方式に振り分ける', () {
      // 本体（https:// 除く）が x1MaxLength 超なら X1不可 → id方式。
      final longBody = 'a' * (x1MaxLength + 5);
      final r = classifyScannedText('https://$longBody.com');
      expect(r, isA<QrIdMode>());
    });

    test('大文字を含むURL（X1非対応文字）は id方式に振り分ける', () {
      expect(classifyScannedText('https://GitHub.com'), isA<QrIdMode>());
    });

    test('空文字は弾く', () {
      expect(classifyScannedText('   '), isA<QrRejected>());
    });

    test('URLでないプレーンテキストは弾く', () {
      expect(classifyScannedText('hello world'), isA<QrRejected>());
      expect(classifyScannedText('just-some-text'), isA<QrRejected>());
    });
  });
}
