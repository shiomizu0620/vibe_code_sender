import 'package:flutter_test/flutter_test.dart';
import 'package:vibe_code_sender/supabase_service.dart';

void main() {
  group('UrlEntry.fromMap', () {
    test('id / url / created_at を正しくパースする', () {
      final entry = UrlEntry.fromMap({
        'id': 42,
        'url': 'https://example.com',
        'created_at': '2026-06-19T12:34:56.000Z',
      });
      expect(entry.id, 42);
      expect(entry.url, 'https://example.com');
      expect(entry.createdAt, DateTime.parse('2026-06-19T12:34:56.000Z'));
    });

    test('created_at が null でも読める', () {
      final entry = UrlEntry.fromMap({
        'id': 0,
        'url': 'https://example.org',
        'created_at': null,
      });
      expect(entry.id, 0);
      expect(entry.createdAt, isNull);
    });
  });
}
