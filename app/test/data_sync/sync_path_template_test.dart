import 'package:flutter_test/flutter_test.dart';
import 'package:totals/services/data_sync/sync_models.dart';

void main() {
  group('SyncPathTemplate.resolve', () {
    test('substitutes placeholders and joins base + path', () {
      final uri = SyncPathTemplate.resolve(
        'https://api.example.com',
        '/txns/{reference}',
        {'reference': 'ABC123'},
      );
      expect(uri.toString(), 'https://api.example.com/txns/ABC123');
    });

    test('handles trailing slash on base and missing leading slash on path', () {
      final uri = SyncPathTemplate.resolve(
        'https://api.example.com/',
        'txns',
        const {},
      );
      expect(uri.toString(), 'https://api.example.com/txns');
    });

    test('percent-encodes placeholder values', () {
      final uri = SyncPathTemplate.resolve(
        'https://api.example.com',
        '/p/{reference}',
        {'reference': 'a b/c?d'},
      );
      expect(uri.toString(), 'https://api.example.com/p/a%20b%2Fc%3Fd');
    });

    test('empty path returns the base', () {
      final uri = SyncPathTemplate.resolve('https://api.example.com', '', const {});
      expect(uri.toString(), 'https://api.example.com');
    });

    test('throws when a placeholder has no value', () {
      expect(
        () => SyncPathTemplate.resolve('https://x.io', '/t/{reference}', const {}),
        throwsA(isA<SyncTemplateException>()),
      );
      expect(
        () => SyncPathTemplate.resolve('https://x.io', '/t/{reference}', {'reference': null}),
        throwsA(isA<SyncTemplateException>()),
      );
    });

    test('absolute path on the destination origin is honored', () {
      final uri = SyncPathTemplate.resolve(
        'https://api.example.com/v1',
        'https://api.example.com/v2/txns/{reference}',
        {'reference': 'ABC'},
      );
      expect(uri.toString(), 'https://api.example.com/v2/txns/ABC');
    });

    test('absolute path cannot leave the destination origin', () {
      for (final template in [
        'http://api.example.com/txns',
        'https://evil.example.net/txns',
        'https://api.example.com:8443/txns',
      ]) {
        expect(
          () => SyncPathTemplate.resolve(
            'https://api.example.com',
            template,
            const {},
          ),
          throwsA(isA<SyncTemplateException>()),
          reason: template,
        );
      }
    });

    test('numeric placeholder values stringify', () {
      final uri = SyncPathTemplate.resolve(
        'https://x.io',
        '/b/{id}',
        {'id': 42},
      );
      expect(uri.toString(), 'https://x.io/b/42');
    });
  });
}
