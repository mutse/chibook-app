import 'package:chibook/core/book_file_path.dart';
import 'package:test/test.dart';

void main() {
  const currentDocuments =
      '/var/mobile/Containers/Data/Application/NEW/Documents';

  test('relative library path resolves inside the current container', () {
    expect(
      resolveBookFilePath('library/book.pdf', currentDocuments),
      '$currentDocuments/library/book.pdf',
    );
  });

  test('legacy iOS absolute path migrates to the current container', () {
    const oldPath =
        '/var/mobile/Containers/Data/Application/OLD/Documents/library/book.pdf';

    expect(
      resolveBookFilePath(oldPath, currentDocuments),
      '$currentDocuments/library/book.pdf',
    );
  });

  test('current app-owned path is persisted as a portable relative path', () {
    expect(
      persistableBookFilePath(
        '$currentDocuments/library/book.pdf',
        currentDocuments,
      ),
      'library/book.pdf',
    );
  });

  test('unmanaged paths remain unchanged', () {
    const external = '/private/tmp/book.pdf';
    expect(resolveBookFilePath(external, currentDocuments), external);
    expect(persistableBookFilePath(external, currentDocuments), external);
  });
}
