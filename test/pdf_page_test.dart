import 'package:chibook/core/pdf_page.dart';
import 'package:test/test.dart';

void main() {
  test('converts a valid zero-based chapter index to a viewer page', () {
    expect(initialPdfPageNumber(chapterIndex: 4, knownPageCount: 10), 5);
  });

  test('clamps stale progress beyond the last PDF page', () {
    expect(initialPdfPageNumber(chapterIndex: 99, knownPageCount: 10), 10);
  });

  test('uses the first page for negative or unknown progress', () {
    expect(initialPdfPageNumber(chapterIndex: -5, knownPageCount: 10), 1);
    expect(initialPdfPageNumber(chapterIndex: 8, knownPageCount: 0), 1);
  });
}
