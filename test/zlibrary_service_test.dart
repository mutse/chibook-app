import 'package:chibook/core/models.dart';
import 'package:chibook/services/zlibrary_service.dart';
import 'package:test/test.dart';

/// Shape of a real `POST /eapi/book/search` response for “西游记”, trimmed to
/// the fields the decoder reads. The value types matter more than the values:
/// `id`, `year` and `filesize` arrive as JSON numbers, and the readable size
/// label lives in `filesizeString`, not in `filesize`.
Map<String, Object?> _xiyoujiPayload() => {
  'success': 1,
  'exactBooksCount': 3,
  'books': [
    {
      'id': 5625807,
      'title': '西游记',
      'author': '吴承恩',
      'year': 2010,
      'publisher': '人民文学出版社',
      'language': 'Chinese',
      'pages': 1198,
      'cover': 'https://s3proxy-alp2-covers.cdn-zlib.sk/covers299/a.jpg',
      'filesize': 2330919,
      'filesizeString': '2.22 MB',
      'extension': 'epub',
      'hash': '02a9c0',
    },
    {
      'id': 3915044,
      'title': '西游记研究 第1辑',
      'author': '',
      'year': 1988,
      'language': 'Chinese',
      'filesize': 51458500,
      'extension': 'PDF',
      'hash': 'e41f7b',
    },
    {
      'id': 1180934,
      'title': '西游记（未支持格式）',
      'author': '吴承恩',
      'filesize': 900000,
      'filesizeString': '878 KB',
      'extension': 'mobi',
      'hash': 'aa11bb',
    },
    {'id': 7788, 'title': '缺少 hash 的条目', 'filesize': 1024, 'extension': 'txt'},
  ],
};

void main() {
  group('parseZLibrarySearchResults', () {
    test('decodes a “西游记” search response into openable books', () {
      final books = parseZLibrarySearchResults(_xiyoujiPayload());

      // The mobi entry and the one without a hash are dropped; everything the
      // readers can open survives.
      expect(books, hasLength(2));

      final first = books.first;
      expect(first.id, '5625807');
      expect(first.hash, '02a9c0');
      expect(first.title, '西游记');
      expect(first.author, '吴承恩');
      expect(first.format, BookFormat.epub);
      expect(first.year, '2010');
      expect(first.language, 'Chinese');
      expect(first.fileSize, '2.22 MB');
      expect(
        first.coverUrl,
        'https://s3proxy-alp2-covers.cdn-zlib.sk/covers299/a.jpg',
      );

      final second = books.last;
      expect(second.title, '西游记研究 第1辑');
      expect(second.format, BookFormat.pdf, reason: 'extension is uppercase');
      expect(second.author, '未知作者', reason: 'blank author gets a placeholder');
      expect(second.coverUrl, isNull);
    });

    test('a numeric filesize must not discard the result', () {
      // Regression: `filesize` was cast to String, so every live result threw
      // and got swallowed as "no matches" — the search looked permanently empty.
      final books = parseZLibrarySearchResults({
        'success': 1,
        'books': [
          {
            'id': 1,
            'hash': 'h1',
            'title': '西游记',
            'extension': 'epub',
            'filesize': 2330919,
          },
        ],
      });

      expect(books, hasLength(1));
      expect(books.single.title, '西游记');
      expect(books.single.fileSize, '2.22 MB', reason: 'bytes are formatted');
    });

    test('formats byte counts and keeps legacy size labels', () {
      String sizeOf(Object? filesize, {Object? label}) =>
          parseZLibrarySearchResults({
            'books': [
              {
                'id': 1,
                'hash': 'h',
                'extension': 'txt',
                'filesize': filesize,
                'filesizeString': ?label,
              },
            ],
          }).single.fileSize;

      expect(sizeOf(900), '900 B');
      expect(sizeOf(2048), '2.00 KB');
      expect(sizeOf(54809783), '52.27 MB');
      expect(sizeOf(2147483648), '2.00 GB');
      expect(sizeOf('2330919'), '2.22 MB', reason: 'numeric string');
      expect(sizeOf('1.5 MB'), '1.5 MB', reason: 'legacy label in filesize');
      expect(sizeOf(2330919, label: '2.22 MB'), '2.22 MB');
      expect(sizeOf(0), '');
      expect(sizeOf(null), '');
    });

    test('degrades on payloads without a usable book list', () {
      expect(parseZLibrarySearchResults(const {}), isEmpty);
      expect(parseZLibrarySearchResults(const {'books': null}), isEmpty);
      expect(parseZLibrarySearchResults(const {'books': 'nope'}), isEmpty);
      expect(
        parseZLibrarySearchResults(const {
          'books': ['nope', 42, null],
        }),
        isEmpty,
      );
    });
  });

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
        'filesizeString': '1.2 MB',
        'cover': 'https://example.com/cover.jpg',
      });

      expect(book.id, '42');
      expect(book.hash, 'abc123');
      expect(book.format, BookFormat.epub);
      expect(book.year, '1920');
      expect(book.fileSize, '1.2 MB');
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

    test('tolerates non-string scalars in text fields', () {
      final book = ZLibraryBook.fromJson({
        'id': 7,
        'hash': 12345,
        'title': 2024,
        'author': null,
        'extension': 'txt',
        'language': false,
      });

      expect(book.id, '7');
      expect(book.hash, '12345');
      expect(book.title, '2024');
      expect(book.author, '未知作者');
      expect(book.language, 'false');
    });
  });
}
