import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:xml/xml.dart';

import '../core/book_file_path.dart';
import '../core/models.dart';
import '../core/pdf_text.dart';
import '../services/pdf_ocr_service.dart';

class BookRepository {
  BookRepository({SharedPreferencesAsync? preferences, PdfOcrService? ocr})
    : _preferences = preferences ?? SharedPreferencesAsync(),
      _ocr = ocr ?? PdfOcrService();

  static const _booksKey = 'erdu.books.v1';
  static const _settingsKey = 'erdu.reader.settings.v1';
  static const _highlightsKey = 'erdu.highlights.v1';
  static const _ttsSettingsKey = 'erdu.tts.settings.v1';
  static const _audioProgressKey = 'erdu.audio.progress.v1';
  static const _listeningRecordsKey = 'erdu.listening.records.v1';
  final SharedPreferencesAsync _preferences;
  final PdfOcrService _ocr;
  final _uuid = const Uuid();

  Future<List<Book>> loadBooks() async {
    final stored = await _preferences.getString(_booksKey);
    if (stored == null) return demoBooks;
    final List<Book> decoded;
    try {
      decoded = decodeBooks(stored);
    } catch (_) {
      return demoBooks;
    }
    try {
      final documents = await getApplicationDocumentsDirectory();
      final books = decoded
          .map(
            (book) => book.copyWith(
              filePath: resolveBookFilePath(book.filePath, documents.path),
            ),
          )
          .toList();
      final portable = books
          .map(
            (book) => book.copyWith(
              filePath: persistableBookFilePath(book.filePath, documents.path),
            ),
          )
          .toList();
      final migrated = encodeBooks(portable);
      if (migrated != stored) {
        try {
          await _preferences.setString(_booksKey, migrated);
        } catch (_) {
          // Migration persistence may be retried next launch; the repaired
          // runtime paths are still safe to use during this session.
        }
      }
      return books;
    } catch (_) {
      // A path-provider failure must not hide otherwise valid library data.
      return decoded;
    }
  }

  Future<void> saveBooks(List<Book> books) async {
    final documents = await getApplicationDocumentsDirectory();
    final portable = books
        .map(
          (book) => book.copyWith(
            filePath: persistableBookFilePath(book.filePath, documents.path),
          ),
        )
        .toList();
    await _preferences.setString(_booksKey, encodeBooks(portable));
  }

  Future<ReaderSettings> loadSettings() async {
    final stored = await _preferences.getString(_settingsKey);
    if (stored == null) return const ReaderSettings();
    try {
      return ReaderSettings.fromJson(
        (jsonDecode(stored) as Map).cast<String, Object?>(),
      );
    } catch (_) {
      return const ReaderSettings();
    }
  }

  Future<void> saveSettings(ReaderSettings settings) =>
      _preferences.setString(_settingsKey, jsonEncode(settings.toJson()));

  Future<List<Highlight>> loadHighlights() async {
    final stored = await _preferences.getString(_highlightsKey);
    if (stored == null) return const [];
    try {
      return decodeHighlights(stored);
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveHighlights(List<Highlight> highlights) =>
      _preferences.setString(_highlightsKey, encodeHighlights(highlights));

  Future<TtsSettings> loadTtsSettings() async {
    final stored = await _preferences.getString(_ttsSettingsKey);
    if (stored == null) return const TtsSettings();
    try {
      return TtsSettings.fromJson(
        (jsonDecode(stored) as Map).cast<String, Object?>(),
      );
    } catch (_) {
      return const TtsSettings();
    }
  }

  Future<void> saveTtsSettings(TtsSettings settings) =>
      _preferences.setString(_ttsSettingsKey, jsonEncode(settings.toJson()));

  Future<List<AudioProgress>> loadAudioProgress() async {
    final stored = await _preferences.getString(_audioProgressKey);
    if (stored == null) return const [];
    try {
      return decodeAudioProgress(stored);
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveAudioProgress(List<AudioProgress> values) =>
      _preferences.setString(_audioProgressKey, encodeAudioProgress(values));

  Future<List<ListeningRecord>> loadListeningRecords() async {
    final stored = await _preferences.getString(_listeningRecordsKey);
    if (stored == null) return const [];
    try {
      return decodeListeningRecords(stored);
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveListeningRecords(List<ListeningRecord> values) =>
      _preferences.setString(
        _listeningRecordsKey,
        encodeListeningRecords(values),
      );

  Future<Book?> importBook({BookFormat? format}) async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: format == null
          ? const ['txt', 'epub', 'pdf']
          : [format.name],
      withData: false,
    );
    final sourcePath = result?.files.single.path;
    if (sourcePath == null) return null;

    final source = File(sourcePath);
    final extension = sourcePath.split('.').last.toLowerCase();
    final documents = await getApplicationDocumentsDirectory();
    final library = Directory('${documents.path}/library');
    await library.create(recursive: true);
    final id = _uuid.v4();
    final storedPath = '${library.path}/$id.$extension';
    await source.copy(storedPath);
    final name = result!.files.single.name.replaceFirst(
      RegExp(r'\.[^.]+$'),
      '',
    );

    if (extension == 'pdf') {
      final chapters = await _extractPdfText(storedPath);
      return Book(
        id: id,
        title: name,
        author: '本地文档',
        format: BookFormat.pdf,
        coverColor: 0xFF6B655C,
        chapters: chapters,
        filePath: storedPath,
      );
    }

    if (extension == 'epub') {
      return _readEpub(id: id, path: storedPath, fallbackTitle: name);
    }

    final bytes = await File(storedPath).readAsBytes();
    final text = _decodeText(bytes);
    return Book(
      id: id,
      title: name,
      author: '本地文档',
      format: BookFormat.txt,
      coverColor: 0xFF3F5B4E,
      chapters: _splitText(text),
      filePath: storedPath,
    );
  }

  Future<void> deleteBookFile(Book book) async {
    final path = book.filePath;
    if (path == null) return;
    final documents = await getApplicationDocumentsDirectory();
    final libraryPath = '${documents.path}/library/';
    if (!path.startsWith(libraryPath)) return;
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  Future<List<Chapter>> _extractPdfText(String path) async {
    PdfDocument? document;
    try {
      // The imported copy is already complete on disk. Progressive loading is
      // intended for sparse/range-backed documents and may leave a local page
      // in a pending state after text extraction, which later appears as a
      // blank page in PdfViewer.
      document = await PdfDocument.openFile(path, useProgressiveLoading: false);
      final chapters = <Chapter>[];
      var hasText = false;
      for (final page in document.pages) {
        final raw = (await page.loadText())?.fullText ?? '';
        // 字体缺 ToUnicode 时提取结果非空却全是乱码，必须和空页一样退回 OCR；
        // 直接存下来会让播放页和 TTS 拿到垃圾内容。
        var text = isGarbledPdfText(raw) ? '' : cleanPdfPageText(raw);
        if (text.isEmpty) {
          try {
            text = cleanPdfPageText(await _ocr.recognizePage(page) ?? '');
          } catch (_) {
            text = '';
          }
        }
        // OCR 也没救回来时保持空白：标为“无文本”并禁用听书，比朗读乱码诚实。
        hasText = hasText || text.isNotEmpty;
        chapters.add(Chapter(title: '第 ${page.pageNumber} 页', content: text));
      }
      return hasText ? chapters : const [];
    } catch (_) {
      return const [];
    } finally {
      await document?.dispose();
    }
  }

  Future<Book> _readEpub({
    required String id,
    required String path,
    required String fallbackTitle,
  }) async {
    final archive = ZipDecoder().decodeBytes(await File(path).readAsBytes());
    String readEntry(String name) {
      final normalized = name.replaceAll('\\', '/');
      final entry = archive.files
          .where((file) => file.name == normalized)
          .firstOrNull;
      if (entry == null || !entry.isFile) return '';
      return utf8.decode(entry.content as List<int>, allowMalformed: true);
    }

    final container = XmlDocument.parse(readEntry('META-INF/container.xml'));
    final packagePath = container.descendants
        .whereType<XmlElement>()
        .firstWhere((element) => element.localName == 'rootfile')
        .getAttribute('full-path');
    if (packagePath == null) throw const FormatException('EPUB 缺少 OPF 路径');
    final package = XmlDocument.parse(readEntry(packagePath));
    String metadataValue(String name) => package.descendants
        .whereType<XmlElement>()
        .where((element) => element.localName == name)
        .map((element) => element.innerText.trim())
        .firstWhere((value) => value.isNotEmpty, orElse: () => '');
    final manifest = <String, String>{};
    for (final item in package.descendants.whereType<XmlElement>().where(
      (e) => e.localName == 'item',
    )) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      if (id != null && href != null) manifest[id] = href;
    }
    final chapters = <Chapter>[];
    for (final itemRef in package.descendants.whereType<XmlElement>().where(
      (e) => e.localName == 'itemref',
    )) {
      final href = manifest[itemRef.getAttribute('idref')];
      if (href == null) continue;
      final packageUri = Uri(path: packagePath);
      final resolvedPath = packageUri.resolve(href).path;
      final raw = readEntry(Uri.decodeComponent(resolvedPath));
      if (raw.isEmpty) continue;
      final document = html_parser.parse(raw);
      final plain =
          document.body?.text.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';
      if (plain.isEmpty) continue;
      final heading = document.querySelector('h1, h2, h3, title')?.text.trim();
      chapters.add(
        Chapter(
          title: heading?.isNotEmpty == true
              ? heading!
              : '第 ${chapters.length + 1} 章',
          content: plain,
        ),
      );
    }
    final epubTitle = metadataValue('title');
    final epubAuthor = metadataValue('creator');
    return Book(
      id: id,
      title: epubTitle.isNotEmpty ? epubTitle : fallbackTitle,
      author: epubAuthor.isNotEmpty ? epubAuthor : '未知作者',
      format: BookFormat.epub,
      coverColor: 0xFF8B5E3C,
      chapters: chapters.isEmpty
          ? const [Chapter(title: '正文', content: '未能从此 EPUB 提取可重排文本。')]
          : chapters,
      filePath: path,
    );
  }

  String _decodeText(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return latin1.decode(bytes);
    }
  }

  List<Chapter> _splitText(String source) {
    final heading = RegExp(
      r'(?=^\s*(?:第[一二三四五六七八九十百千万0-9]+[章节回]|Chapter\s+\d+).*$)',
      multiLine: true,
      caseSensitive: false,
    );
    final parts = source
        .split(heading)
        .where((e) => e.trim().isNotEmpty)
        .toList();
    if (parts.length <= 1) {
      return [Chapter(title: '正文', content: source.trim())];
    }
    return parts.map((part) {
      final lines = part.trim().split('\n');
      return Chapter(
        title: lines.first.trim(),
        content: lines.skip(1).join('\n').trim(),
      );
    }).toList();
  }
}

const demoBooks = <Book>[
  Book(
    id: 'hongloumeng',
    title: '红楼梦',
    author: '曹雪芹',
    format: BookFormat.epub,
    coverColor: 0xFF3F5B4E,
    chapterIndex: 0,
    progress: .62,
    chapters: [
      Chapter(
        title: '第三回　贾雨村夤缘复旧职',
        content:
            '那一年江南的雨下得格外久，檐角滴水的声音像是数不尽的更漏。院中的海棠开得静默，无人问起，也无人叹惜。\n\n他在灯下坐了许久，将旧稿又翻了一遍，字迹早已模糊，唯有那句批注还依稀可辨，像是提醒着什么，却怎么也想不真切。\n\n窗外忽然起了风，吹得帘子轻轻作响。远处传来更夫敲梆子的声音，一下，又一下，将这寂静的夜切成了细碎的片段。\n\n他起身添了灯油，重新坐回案前，心想：往事纵有千般滋味，落笔时也只余这几行墨色。',
      ),
      Chapter(
        title: '第四回　薄命女偏逢薄命郎',
        content: '晨光照进窗棂时，昨夜的雨已经停了。青石阶上积着浅浅的水，倒映着一方淡青色的天。',
      ),
    ],
  ),
  Book(
    id: 'biancheng',
    title: '边城',
    author: '沈从文',
    format: BookFormat.txt,
    coverColor: 0xFF8B5E3C,
    progress: .38,
    chapters: [
      Chapter(
        title: '第一章　小溪与渡船',
        content:
            '溪边的白塔静静立着，渡船随水波轻轻晃动，像是在等一个迟迟未归的人。\n\n茶峒地方凭水依山筑城，近山的一面，城墙俨然如一条长蛇。',
      ),
    ],
  ),
  Book(
    id: 'renjiancihua',
    title: '人间词话',
    author: '王国维',
    format: BookFormat.txt,
    coverColor: 0xFF6B655C,
    progress: .18,
    chapters: [Chapter(title: '人间词话', content: '词以境界为最上。有境界则自成高格，自有名句。')],
  ),
  Book(
    id: 'nahan',
    title: '呐喊',
    author: '鲁迅',
    format: BookFormat.txt,
    coverColor: 0xFFC1442D,
    progress: .03,
    chapters: [Chapter(title: '自序', content: '我在年青时候也曾经做过许多梦，后来大半忘却了。')],
  ),
  Book(
    id: 'walden',
    title: '瓦尔登湖',
    author: '梭罗',
    format: BookFormat.epub,
    coverColor: 0xFF29483D,
    progress: .91,
    chapters: [Chapter(title: '经济篇', content: '我到林中去，因为我希望活得从容，只面对生活的基本事实。')],
  ),
  Book(
    id: 'xiangtu',
    title: '乡土中国',
    author: '费孝通',
    format: BookFormat.txt,
    coverColor: 0xFF8B8378,
    progress: .45,
    chapters: [Chapter(title: '乡土本色', content: '从基层上看去，中国社会是乡土性的。')],
  ),
];
