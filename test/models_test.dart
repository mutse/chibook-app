import 'package:chibook/core/models.dart';
import 'package:test/test.dart';

void main() {
  test('book persistence keeps format, chapter and progress', () {
    const book = Book(
      id: 'local-1',
      title: '测试书籍',
      author: '作者',
      format: BookFormat.epub,
      coverColor: 0xFF3F5B4E,
      chapters: [Chapter(title: '第一章', content: '正文')],
      chapterIndex: 0,
      progress: .5,
    );

    final decoded = decodeBooks(encodeBooks([book])).single;

    expect(decoded.title, book.title);
    expect(decoded.format, BookFormat.epub);
    expect(decoded.chapters.single.content, '正文');
    expect(decoded.progress, .5);
  });

  test('reading location supports text and PDF coordinates', () {
    const text = ReadingLocation.text(
      chapterIndex: 2,
      startOffset: 10,
      endOffset: 20,
    );
    const pdf = ReadingLocation.pdf(
      pageNumber: 3,
      normalizedRect: [.1, .2, .3, .4],
    );

    expect(text.kind, ReadingLocationKind.textOffset);
    expect(pdf.kind, ReadingLocationKind.pdfRegion);
    expect(pdf.toJson()['pageNumber'], 3);

    final decodedText = ReadingLocation.fromJson(text.toJson());
    final decodedPdf = ReadingLocation.fromJson(pdf.toJson());
    expect(decodedText.startOffset, 10);
    expect(decodedPdf.normalizedRect, [.1, .2, .3, .4]);
  });

  test('highlight persistence keeps excerpt, location and note', () {
    final highlight = Highlight(
      id: 'highlight-1',
      bookId: 'local-1',
      excerpt: '一段正文',
      location: const ReadingLocation.text(
        chapterIndex: 1,
        startOffset: 3,
        endOffset: 7,
      ),
      createdAt: DateTime.utc(2026, 8, 3),
      note: '我的笔记',
    );

    final decoded = decodeHighlights(encodeHighlights([highlight])).single;

    expect(decoded.bookId, 'local-1');
    expect(decoded.excerpt, '一段正文');
    expect(decoded.location.chapterIndex, 1);
    expect(decoded.note, '我的笔记');
  });

  test('TTS settings persist provider but never persist API key', () {
    const settings = TtsSettings(
      provider: TtsProvider.azure,
      voiceName: '温润男声',
      speed: 1.5,
      endpoint: 'eastasia',
      apiKey: 'test-key',
    );

    final decoded = TtsSettings.fromJson(settings.toJson());

    expect(decoded.provider, TtsProvider.azure);
    expect(decoded.voiceName, '温润男声');
    expect(decoded.speed, 1.5);
    expect(decoded.endpoint, 'eastasia');
    expect(decoded.apiKey, isEmpty);
  });

  test('audio progress round-trip keeps character position and mode', () {
    final value = AudioProgress(
      bookId: 'local-1',
      chapterIndex: 3,
      characterOffset: 128,
      speed: 1.5,
      updatedAt: DateTime.utc(2026, 8, 8, 10),
      mode: PlaybackMode.repeatOne,
    );

    final decoded = decodeAudioProgress(encodeAudioProgress([value])).single;

    expect(decoded.bookId, 'local-1');
    expect(decoded.chapterIndex, 3);
    expect(decoded.characterOffset, 128);
    expect(decoded.speed, 1.5);
    expect(decoded.mode, PlaybackMode.repeatOne);
    expect(decoded.updatedAt, DateTime.utc(2026, 8, 8, 10));
  });

  test('audio progress accepts missing fields from older JSON', () {
    final decoded = AudioProgress.fromJson(const {
      'bookId': 'legacy-book',
      'chapterIndex': 2,
    });

    expect(decoded.characterOffset, 0);
    expect(decoded.speed, 1);
    expect(decoded.mode, PlaybackMode.sequential);
  });

  test('listening record round-trip keeps duration', () {
    final value = ListeningRecord(
      bookId: 'local-1',
      chapterIndex: 1,
      characterOffset: 80,
      listenedSeconds: 360,
      updatedAt: DateTime.utc(2026, 8, 8, 11),
    );

    final decoded = decodeListeningRecords(
      encodeListeningRecords([value]),
    ).single;

    expect(decoded.listenedSeconds, 360);
    expect(decoded.characterOffset, 80);
  });
}
