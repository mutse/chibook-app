/// Convert the persisted zero-based PDF chapter index into a safe one-based
/// viewer page number.
///
/// Older progress may point beyond the current document after migration or a
/// failed import. pdfrx accepts the initial page before the document is ready;
/// an out-of-range value can therefore position the viewport on empty space.
int initialPdfPageNumber({
  required int chapterIndex,
  required int knownPageCount,
}) {
  final pageCount = knownPageCount < 1 ? 1 : knownPageCount;
  return (chapterIndex + 1).clamp(1, pageCount);
}
