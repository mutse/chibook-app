import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:xml/xml.dart';

import '../core/models.dart';

class BookRepository {
  BookRepository({SharedPreferencesAsync? preferences})
    : _preferences = preferences ?? SharedPreferencesAsync();

  static const _booksKey = 'erdu.books.v1';
  static const _settingsKey = 'erdu.reader.settings.v1';
  final SharedPreferencesAsync _preferences;
  final _uuid = const Uuid();

  Future<List<Book>> loadBooks() async {
    final stored = await _preferences.getString(_booksKey);
    if (stored == null) return demoBooks;
    try {
      return decodeBooks(stored);
    } catch (_) {
      return demoBooks;
    }
  }

  Future<void> saveBooks(List<Book> books) =>
      _preferences.setString(_booksKey, encodeBooks(books));

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

  Future<Book?> importBook() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['txt', 'epub', 'pdf'],
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
      return Book(
        id: id,
        title: name,
        author: '本地文档',
        format: BookFormat.pdf,
        coverColor: 0xFF6B655C,
        chapters: const [],
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
    final packageDir = packagePath.contains('/')
        ? packagePath.substring(0, packagePath.lastIndexOf('/') + 1)
        : '';
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
      final raw = readEntry(
        '$packageDir${Uri.decodeComponent(href.split('#').first)}',
      );
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
