import 'package:flutter_test/flutter_test.dart';
import 'package:cortex_ai_agent/services/search_service.dart';

void main() {
  group('ErrorSignatureDetector', () {
    test('detects missing package import', () {
      const stderr = "Error: Target of URI doesn't exist: 'package:foo/foo.dart'";
      final query = ErrorSignatureDetector.extractQueryFromStderr(stderr);
      expect(query, isNotNull);
      expect(query, contains('foo'));
    });

    test('returns null for unrelated stderr', () {
      const stderr = 'All tests passed!';
      final query = ErrorSignatureDetector.extractQueryFromStderr(stderr);
      expect(query, isNull);
    });
  });
}
