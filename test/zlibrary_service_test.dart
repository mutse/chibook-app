import 'package:chibook/core/models.dart';
import 'package:chibook/services/zlibrary_service.dart';
import 'package:test/test.dart';

void main() {
  group('ZLibraryBook', () {
    test('decodes supported search result metadata', () {
      final book = ZLibraryBook.fromJson({
        'id': 42,
        'hash': 'abc123',
        'title': 'A Public Domain Book',
        'author': 'Example Author',
        'extension': 'EPUB',
        'year': 1920,
        'language': 'Chinese',
        'filesize': '1.2 MB',
        'cover': 'https://example.com/cover.jpg',
      });

      expect(book.id, '42');
      expect(book.hash, 'abc123');
      expect(book.format, BookFormat.epub);
      expect(book.year, '1920');
      expect(book.coverUrl, 'https://example.com/cover.jpg');
    });

    test('rejects unsupported formats and insecure covers', () {
      expect(
        () => ZLibraryBook.fromJson({
          'id': '1',
          'hash': 'hash',
          'extension': 'mobi',
        }),
        throwsFormatException,
      );

      final book = ZLibraryBook.fromJson({
        'id': '1',
        'hash': 'hash',
        'extension': 'pdf',
        'cover': 'http://example.com/cover.jpg',
      });
      expect(book.coverUrl, isNull);
    });
  });
}
