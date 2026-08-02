import 'dart:convert';

enum BookFormat { txt, epub, pdf }

enum ReaderTheme { light, dark, eye }

enum ReadingLocationKind { textOffset, pdfRegion }

class Chapter {
  const Chapter({required this.title, required this.content});

  final String title;
  final String content;

  Map<String, Object?> toJson() => {'title': title, 'content': content};

  factory Chapter.fromJson(Map<String, Object?> json) => Chapter(
    title: json['title']! as String,
    content: json['content']! as String,
  );
}

class Book {
  const Book({
    required this.id,
    required this.title,
    required this.author,
    required this.format,
    required this.coverColor,
    required this.chapters,
    this.filePath,
    this.chapterIndex = 0,
    this.progress = 0,
    this.isPinned = false,
    this.lastOpenedAt,
  });

  final String id;
  final String title;
  final String author;
  final BookFormat format;
  final int coverColor;
  final List<Chapter> chapters;
  final String? filePath;
  final int chapterIndex;
  final double progress;
  final bool isPinned;
  final DateTime? lastOpenedAt;

  Book copyWith({
    int? chapterIndex,
    double? progress,
    bool? isPinned,
    DateTime? lastOpenedAt,
  }) => Book(
    id: id,
    title: title,
    author: author,
    format: format,
    coverColor: coverColor,
    chapters: chapters,
    filePath: filePath,
    chapterIndex: chapterIndex ?? this.chapterIndex,
    progress: progress ?? this.progress,
    isPinned: isPinned ?? this.isPinned,
    lastOpenedAt: lastOpenedAt ?? this.lastOpenedAt,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'author': author,
    'format': format.name,
    'coverColor': coverColor,
    'chapters': chapters.map((e) => e.toJson()).toList(),
    'filePath': filePath,
    'chapterIndex': chapterIndex,
    'progress': progress,
    'isPinned': isPinned,
    'lastOpenedAt': lastOpenedAt?.toIso8601String(),
  };

  factory Book.fromJson(Map<String, Object?> json) => Book(
    id: json['id']! as String,
    title: json['title']! as String,
    author: json['author']! as String,
    format: BookFormat.values.byName(json['format']! as String),
    coverColor: json['coverColor']! as int,
    chapters: (json['chapters']! as List<Object?>)
        .map((e) => Chapter.fromJson((e! as Map).cast<String, Object?>()))
        .toList(),
    filePath: json['filePath'] as String?,
    chapterIndex: json['chapterIndex'] as int? ?? 0,
    progress: (json['progress'] as num?)?.toDouble() ?? 0,
    isPinned: json['isPinned'] as bool? ?? false,
    lastOpenedAt: json['lastOpenedAt'] == null
        ? null
        : DateTime.parse(json['lastOpenedAt']! as String),
  );
}

class ReadingLocation {
  const ReadingLocation.text({
    required this.chapterIndex,
    required this.startOffset,
    required this.endOffset,
  }) : kind = ReadingLocationKind.textOffset,
       pageNumber = null,
       normalizedRect = null;

  const ReadingLocation.pdf({
    required this.pageNumber,
    required this.normalizedRect,
  }) : kind = ReadingLocationKind.pdfRegion,
       chapterIndex = null,
       startOffset = null,
       endOffset = null;

  final ReadingLocationKind kind;
  final int? chapterIndex;
  final int? startOffset;
  final int? endOffset;
  final int? pageNumber;
  final List<double>? normalizedRect;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'chapterIndex': chapterIndex,
    'startOffset': startOffset,
    'endOffset': endOffset,
    'pageNumber': pageNumber,
    'normalizedRect': normalizedRect,
  };
}

class Highlight {
  const Highlight({
    required this.id,
    required this.bookId,
    required this.excerpt,
    required this.location,
    required this.createdAt,
    this.note,
  });

  final String id;
  final String bookId;
  final String excerpt;
  final ReadingLocation location;
  final DateTime createdAt;
  final String? note;
}

class ReaderSettings {
  const ReaderSettings({
    this.theme = ReaderTheme.light,
    this.fontSize = 17,
    this.lineHeight = 1.9,
    this.brightness = 1,
  });

  final ReaderTheme theme;
  final double fontSize;
  final double lineHeight;
  final double brightness;

  ReaderSettings copyWith({
    ReaderTheme? theme,
    double? fontSize,
    double? lineHeight,
    double? brightness,
  }) => ReaderSettings(
    theme: theme ?? this.theme,
    fontSize: fontSize ?? this.fontSize,
    lineHeight: lineHeight ?? this.lineHeight,
    brightness: brightness ?? this.brightness,
  );

  Map<String, Object?> toJson() => {
    'theme': theme.name,
    'fontSize': fontSize,
    'lineHeight': lineHeight,
    'brightness': brightness,
  };

  factory ReaderSettings.fromJson(Map<String, Object?> json) => ReaderSettings(
    theme: ReaderTheme.values.byName(json['theme'] as String? ?? 'light'),
    fontSize: (json['fontSize'] as num?)?.toDouble() ?? 17,
    lineHeight: (json['lineHeight'] as num?)?.toDouble() ?? 1.9,
    brightness: (json['brightness'] as num?)?.toDouble() ?? 1,
  );
}

String encodeBooks(List<Book> books) =>
    jsonEncode(books.map((e) => e.toJson()).toList());

List<Book> decodeBooks(String source) => (jsonDecode(source) as List<Object?>)
    .map((e) => Book.fromJson((e! as Map).cast<String, Object?>()))
    .toList();
