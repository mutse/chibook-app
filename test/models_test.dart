import 'package:erdu/core/models.dart';
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
  });
}
