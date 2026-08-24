import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/models.dart';
import '../data/book_repository.dart';
import '../services/cloud_tts_service.dart';
import '../services/weread_service.dart';

final bookRepositoryProvider = Provider((ref) => BookRepository());
final weReadServiceProvider = Provider((ref) => WeReadService());

final appControllerProvider = NotifierProvider<AppController, AppState>(
  AppController.new,
);

class AppState {
  const AppState({
    this.books = const [],
    this.settings = const ReaderSettings(),
    this.ttsSettings = const TtsSettings(),
    this.initialized = false,
    this.isGrid = true,
    this.activeAudioBookId,
    this.highlights = const [],
    this.audioProgress = const [],
    this.listeningRecords = const [],
    this.recentSearches = const ['沈从文', '人间词话', '鲁迅', '瓦尔登湖'],
    this.weReadAccount,
    this.isWeReadSyncing = false,
    this.weReadError,
  });

  final List<Book> books;
  final ReaderSettings settings;
  final TtsSettings ttsSettings;
  final bool initialized;
  final bool isGrid;
  final String? activeAudioBookId;
  final List<Highlight> highlights;
  final List<AudioProgress> audioProgress;
  final List<ListeningRecord> listeningRecords;
  final List<String> recentSearches;
  final WeReadAccount? weReadAccount;
  final bool isWeReadSyncing;
  final String? weReadError;

  AppState copyWith({
    List<Book>? books,
    ReaderSettings? settings,
    TtsSettings? ttsSettings,
    bool? initialized,
    bool? isGrid,
    String? activeAudioBookId,
    bool clearActiveAudioBookId = false,
    List<Highlight>? highlights,
    List<AudioProgress>? audioProgress,
    List<ListeningRecord>? listeningRecords,
    List<String>? recentSearches,
    WeReadAccount? weReadAccount,
    bool clearWeReadAccount = false,
    bool? isWeReadSyncing,
    String? weReadError,
    bool clearWeReadError = false,
  }) => AppState(
    books: books ?? this.books,
    settings: settings ?? this.settings,
    ttsSettings: ttsSettings ?? this.ttsSettings,
    initialized: initialized ?? this.initialized,
    isGrid: isGrid ?? this.isGrid,
    activeAudioBookId: clearActiveAudioBookId
        ? null
        : (activeAudioBookId ?? this.activeAudioBookId),
    highlights: highlights ?? this.highlights,
    audioProgress: audioProgress ?? this.audioProgress,
    listeningRecords: listeningRecords ?? this.listeningRecords,
    recentSearches: recentSearches ?? this.recentSearches,
    weReadAccount: clearWeReadAccount
        ? null
        : (weReadAccount ?? this.weReadAccount),
    isWeReadSyncing: isWeReadSyncing ?? this.isWeReadSyncing,
    weReadError: clearWeReadError ? null : (weReadError ?? this.weReadError),
  );
}

class AppController extends Notifier<AppState> {
  static const _uuid = Uuid();
  final Map<String, DateTime> _listeningTicks = {};
  BookRepository get _repository => ref.read(bookRepositoryProvider);
  final _credentials = const TtsCredentialStore();
  final _cloudTts = CloudTtsService();
  final Map<String, Future<void>> _weReadCatalogLoads = {};
  final Map<String, Future<void>> _weReadChapterLoads = {};
  WeReadService get _weRead => ref.read(weReadServiceProvider);

  @override
  AppState build() {
    Future.microtask(_initialize);
    return const AppState();
  }

  Future<void> _initialize() async {
    try {
      final values = await Future.wait([
        _repository.loadBooks(),
        _repository.loadSettings(),
        _repository.loadHighlights(),
        _repository.loadTtsSettings(),
        _repository.loadAudioProgress(),
        _repository.loadListeningRecords(),
        _restoreWeReadAccountSafely(),
      ]);
      final books = values[0] as List<Book>;
      final bookIds = books.map((book) => book.id).toSet();
      final storedProgress = values[4] as List<AudioProgress>;
      final storedRecords = values[5] as List<ListeningRecord>;
      final audioProgress = storedProgress
          .where((value) => bookIds.contains(value.bookId))
          .toList();
      final listeningRecords = storedRecords
          .where((value) => bookIds.contains(value.bookId))
          .toList();
      var ttsSettings = values[3] as TtsSettings;
      if (ttsSettings.apiKey.isNotEmpty) {
        await _credentials.writeOpenAiKey(ttsSettings.apiKey);
        ttsSettings = ttsSettings.copyWith(clearApiKey: true);
        await _repository.saveTtsSettings(ttsSettings);
      }
      state = state.copyWith(
        books: books,
        settings: values[1] as ReaderSettings,
        highlights: values[2] as List<Highlight>,
        ttsSettings: ttsSettings,
        audioProgress: audioProgress,
        listeningRecords: listeningRecords,
        weReadAccount: values[6] as WeReadAccount?,
        initialized: true,
      );
      // 孤儿记录（书籍已删除）过滤后写回磁盘，否则只在内存生效，下次启动仍会读到。
      await Future.wait([
        if (audioProgress.length != storedProgress.length)
          _repository.saveAudioProgress(audioProgress),
        if (listeningRecords.length != storedRecords.length)
          _repository.saveListeningRecords(listeningRecords),
      ]);
    } catch (_) {
      // 初始化失败也必须让 UI 走出加载态，否则整个 App 卡在转圈。
      state = state.copyWith(initialized: true);
    }
  }

  void setGrid(bool value) => state = state.copyWith(isGrid: value);

  Future<WeReadAccount?> _restoreWeReadAccountSafely() async {
    try {
      return await _weRead.restoreAccount();
    } catch (_) {
      return null;
    }
  }

  Future<WeReadLoginSession> startWeReadLogin() => _weRead.startLogin();

  Future<void> completeWeReadLogin(
    WeReadLoginSession session, {
    String otp = '',
  }) async {
    final account = await _weRead.completeLogin(session, otp: otp);
    state = state.copyWith(weReadAccount: account, clearWeReadError: true);
    await syncWeReadShelf();
  }

  Future<void> syncWeReadShelf() async {
    if (state.isWeReadSyncing) return;
    state = state.copyWith(isWeReadSyncing: true, clearWeReadError: true);
    try {
      final incoming = await _weRead.syncShelf();
      final localBooks = state.books
          .where((book) => book.source == BookSource.local)
          .toList();
      final existing = {
        for (final book in state.books.where(
          (book) => book.source == BookSource.weread,
        ))
          book.remoteId: book,
      };
      final remoteBooks = incoming.map((fresh) {
        final previous = existing[fresh.remoteId];
        if (previous == null) return fresh;
        final newestOpened = switch ((
          fresh.lastOpenedAt,
          previous.lastOpenedAt,
        )) {
          (final DateTime freshTime, final DateTime previousTime) =>
            freshTime.isAfter(previousTime) ? freshTime : previousTime,
          (final DateTime freshTime, null) => freshTime,
          (null, final DateTime previousTime) => previousTime,
          _ => null,
        };
        return fresh.copyWith(
          chapters: previous.chapters,
          chapterIndex: previous.chapterIndex,
          progress: fresh.progress > previous.progress
              ? fresh.progress
              : previous.progress,
          isPinned: previous.isPinned,
          lastOpenedAt: newestOpened,
          remoteFormat: fresh.remoteFormat ?? previous.remoteFormat,
          coverUrl: fresh.coverUrl ?? previous.coverUrl,
        );
      }).toList();
      state = state.copyWith(
        books: [...remoteBooks, ...localBooks],
        isWeReadSyncing: false,
        clearWeReadError: true,
      );
      await _repository.saveBooks(state.books);
    } catch (error) {
      state = state.copyWith(
        isWeReadSyncing: false,
        weReadError: error.toString(),
      );
      rethrow;
    }
  }

  Future<void> prepareWeReadBook(String id) {
    final running = _weReadCatalogLoads[id];
    if (running != null) return running;
    final future = _prepareWeReadBook(id);
    _weReadCatalogLoads[id] = future;
    future.then(
      (_) => _weReadCatalogLoads.remove(id),
      onError: (_, _) => _weReadCatalogLoads.remove(id),
    );
    return future;
  }

  Future<void> _prepareWeReadBook(String id) async {
    final book = state.books.where((value) => value.id == id).firstOrNull;
    if (book == null || book.source != BookSource.weread) return;
    if (book.chapters.isNotEmpty) return;
    final remoteId = book.remoteId;
    if (remoteId == null) throw const WeReadException('缺少微信读书书籍 ID');
    final catalog = await _weRead.loadCatalog(remoteId);
    final remoteChapterIndex = catalog.currentChapterUid == null
        ? -1
        : catalog.chapters.indexWhere(
            (chapter) => chapter.remoteUid == catalog.currentChapterUid,
          );
    final resumeChapter = remoteChapterIndex >= 0
        ? remoteChapterIndex
        : book.chapterIndex.clamp(0, catalog.chapters.length - 1);
    state = state.copyWith(
      books: state.books
          .map(
            (value) => value.id == id
                ? value.copyWith(
                    title: catalog.title,
                    author: catalog.author,
                    coverUrl: catalog.coverUrl,
                    remoteFormat: catalog.format,
                    chapters: catalog.chapters,
                    chapterIndex: resumeChapter,
                    progress: catalog.progress > value.progress
                        ? catalog.progress
                        : value.progress,
                  )
                : value,
          )
          .toList(),
    );
    await _repository.saveBooks(state.books);
  }

  Future<void> loadWeReadChapter(String id, int chapterIndex) {
    final key = '$id:$chapterIndex';
    final running = _weReadChapterLoads[key];
    if (running != null) return running;
    final future = _loadWeReadChapter(id, chapterIndex);
    _weReadChapterLoads[key] = future;
    future.then(
      (_) => _weReadChapterLoads.remove(key),
      onError: (_, _) => _weReadChapterLoads.remove(key),
    );
    return future;
  }

  Future<void> _loadWeReadChapter(String id, int chapterIndex) async {
    var book = state.books.where((value) => value.id == id).firstOrNull;
    if (book == null || book.source != BookSource.weread) return;
    if (book.chapters.isEmpty) {
      await prepareWeReadBook(id);
      book = state.books.where((value) => value.id == id).firstOrNull;
    }
    if (book == null ||
        chapterIndex < 0 ||
        chapterIndex >= book.chapters.length) {
      return;
    }
    final chapter = book.chapters[chapterIndex];
    if (chapter.isLoaded) return;
    final remoteId = book.remoteId;
    final remoteUid = chapter.remoteUid;
    if (remoteId == null || remoteUid == null) {
      throw const WeReadException('缺少微信读书章节信息');
    }
    final content = await _weRead.loadChapter(
      bookId: remoteId,
      chapterUid: remoteUid,
      format: book.remoteFormat,
    );
    if (content.trim().isEmpty) {
      throw const WeReadException('这一章没有可读取的文字内容');
    }
    final chapters = book.chapters.toList();
    chapters[chapterIndex] = chapter.copyWith(content: content, isLoaded: true);
    state = state.copyWith(
      books: state.books
          .map(
            (value) =>
                value.id == id ? value.copyWith(chapters: chapters) : value,
          )
          .toList(),
    );
  }

  Future<Book> prepareBookForTts(String id, {required int chapterIndex}) async {
    var book = state.books.where((value) => value.id == id).firstOrNull;
    if (book == null) throw StateError('书籍不存在');
    if (book.source == BookSource.weread) {
      if (book.chapters.isEmpty) {
        await prepareWeReadBook(id);
        book = state.books.where((value) => value.id == id).firstOrNull;
      }
      if (book == null || book.chapters.isEmpty) {
        throw const WeReadException('这本书暂时没有可朗读的文字章节');
      }
      final target = chapterIndex.clamp(0, book.chapters.length - 1);
      await loadWeReadChapter(id, target);
      book = state.books.where((value) => value.id == id).firstOrNull;
      if (book == null || !book.chapters[target].isLoaded) {
        throw const WeReadException('微信读书章节加载失败，请稍后重试');
      }
    }
    if (book.chapters.isEmpty) {
      throw StateError('此书暂无可用于 TTS 的文本');
    }
    return book;
  }

  Future<void> logoutWeRead() async {
    await _weRead.logout();
    final removedIds = state.books
        .where((book) => book.source == BookSource.weread)
        .map((book) => book.id)
        .toSet();
    state = state.copyWith(
      books: state.books
          .where((book) => book.source == BookSource.local)
          .toList(),
      highlights: state.highlights
          .where((item) => !removedIds.contains(item.bookId))
          .toList(),
      audioProgress: state.audioProgress
          .where((item) => !removedIds.contains(item.bookId))
          .toList(),
      listeningRecords: state.listeningRecords
          .where((item) => !removedIds.contains(item.bookId))
          .toList(),
      clearWeReadAccount: true,
      clearWeReadError: true,
    );
    await Future.wait([
      _repository.saveBooks(state.books),
      _repository.saveHighlights(state.highlights),
      _repository.saveAudioProgress(state.audioProgress),
      _repository.saveListeningRecords(state.listeningRecords),
    ]);
  }

  Future<bool> importBook({BookFormat? format}) async {
    final book = await _repository.importBook(format: format);
    if (book == null) return false;
    state = state.copyWith(books: [book, ...state.books]);
    await _repository.saveBooks(state.books);
    return true;
  }

  Future<void> removeBook(String id) async {
    final removed = state.books.where((book) => book.id == id).firstOrNull;
    _listeningTicks.remove(id);
    state = state.copyWith(
      books: state.books.where((e) => e.id != id).toList(),
      clearActiveAudioBookId: state.activeAudioBookId == id,
      highlights: state.highlights
          .where((highlight) => highlight.bookId != id)
          .toList(),
      audioProgress: state.audioProgress
          .where((progress) => progress.bookId != id)
          .toList(),
      listeningRecords: state.listeningRecords
          .where((record) => record.bookId != id)
          .toList(),
    );
    await Future.wait([
      _repository.saveBooks(state.books),
      _repository.saveHighlights(state.highlights),
      _repository.saveAudioProgress(state.audioProgress),
      _repository.saveListeningRecords(state.listeningRecords),
      if (removed != null) _repository.deleteBookFile(removed),
      if (removed != null) _cloudTts.clearCache(bookId: removed.id),
    ]);
  }

  Future<void> removeBooks(Set<String> ids) async {
    final removed = state.books.where((book) => ids.contains(book.id)).toList();
    for (final id in ids) {
      _listeningTicks.remove(id);
    }
    state = state.copyWith(
      books: state.books.where((book) => !ids.contains(book.id)).toList(),
      clearActiveAudioBookId: ids.contains(state.activeAudioBookId),
      highlights: state.highlights
          .where((highlight) => !ids.contains(highlight.bookId))
          .toList(),
      audioProgress: state.audioProgress
          .where((progress) => !ids.contains(progress.bookId))
          .toList(),
      listeningRecords: state.listeningRecords
          .where((record) => !ids.contains(record.bookId))
          .toList(),
    );
    await Future.wait([
      _repository.saveBooks(state.books),
      _repository.saveHighlights(state.highlights),
      _repository.saveAudioProgress(state.audioProgress),
      _repository.saveListeningRecords(state.listeningRecords),
      ...removed.map(_repository.deleteBookFile),
      ...removed.map((book) => _cloudTts.clearCache(bookId: book.id)),
    ]);
  }

  Future<void> togglePinned(String id) async {
    state = state.copyWith(
      books:
          state.books
              .map((e) => e.id == id ? e.copyWith(isPinned: !e.isPinned) : e)
              .toList()
            ..sort(
              (a, b) => a.isPinned == b.isPinned ? 0 : (a.isPinned ? -1 : 1),
            ),
    );
    await _repository.saveBooks(state.books);
  }

  Future<void> updateProgress(String id, int chapter, double progress) async {
    state = state.copyWith(
      books: state.books
          .map(
            (e) => e.id == id
                ? e.copyWith(
                    chapterIndex: chapter,
                    progress: progress,
                    lastOpenedAt: DateTime.now(),
                  )
                : e,
          )
          .toList(),
    );
    await _repository.saveBooks(state.books);
  }

  Future<void> setSettings(ReaderSettings value) async {
    state = state.copyWith(settings: value);
    await _repository.saveSettings(value);
  }

  Future<void> setTtsSettings(TtsSettings value) async {
    if (value.provider == TtsProvider.openai || value.apiKey.isNotEmpty) {
      await _credentials.writeOpenAiKey(value.apiKey);
    }
    final safeValue = value.copyWith(clearApiKey: true);
    state = state.copyWith(ttsSettings: safeValue);
    await _repository.saveTtsSettings(safeValue);
  }

  void setActiveAudio(String id) =>
      state = state.copyWith(activeAudioBookId: id);

  AudioProgress? audioProgressFor(String bookId) =>
      state.audioProgress.where((value) => value.bookId == bookId).firstOrNull;

  Future<void> saveAudioPosition({
    required String bookId,
    required int chapterIndex,
    required int characterOffset,
    required double speed,
    required PlaybackMode mode,
    bool countListening = false,
  }) async {
    final now = DateTime.now();
    final progress = AudioProgress(
      bookId: bookId,
      chapterIndex: chapterIndex,
      characterOffset: characterOffset,
      speed: speed,
      updatedAt: now,
      mode: mode,
    );
    final progressValues = [
      progress,
      ...state.audioProgress.where((value) => value.bookId != bookId),
    ];
    var records = state.listeningRecords;
    if (countListening) {
      final previousTick = _listeningTicks[bookId];
      _listeningTicks[bookId] = now;
      final added = previousTick == null
          ? 0
          : now.difference(previousTick).inSeconds.clamp(0, 10);
      final existing = records
          .where((value) => value.bookId == bookId)
          .firstOrNull;
      final record = ListeningRecord(
        bookId: bookId,
        chapterIndex: chapterIndex,
        characterOffset: characterOffset,
        listenedSeconds: (existing?.listenedSeconds ?? 0) + added,
        updatedAt: now,
      );
      records = [record, ...records.where((value) => value.bookId != bookId)];
    } else {
      // 暂停/中断时丢弃计时起点：否则来电或拔耳机后恢复播放，中断期间的
      // 时长会被算作有效收听（10 秒的 clamp 只能兜住短暂停顿）。
      _listeningTicks.remove(bookId);
    }
    state = state.copyWith(
      audioProgress: progressValues,
      listeningRecords: records,
    );
    await Future.wait([
      _repository.saveAudioProgress(progressValues),
      if (countListening) _repository.saveListeningRecords(records),
    ]);
  }

  Future<void> clearListeningHistory() async {
    _listeningTicks.clear();
    state = state.copyWith(listeningRecords: const []);
    await _repository.saveListeningRecords(const []);
  }

  void addSearch(String query) {
    final value = query.trim();
    if (value.isEmpty) return;
    state = state.copyWith(
      recentSearches: [
        value,
        ...state.recentSearches.where((e) => e != value),
      ].take(6).toList(),
    );
  }

  Future<void> addHighlight({
    required String bookId,
    required String excerpt,
    required ReadingLocation location,
    String? note,
  }) async {
    final highlight = Highlight(
      id: _uuid.v4(),
      bookId: bookId,
      excerpt: excerpt,
      location: location,
      createdAt: DateTime.now(),
      note: note,
    );
    state = state.copyWith(highlights: [highlight, ...state.highlights]);
    await _repository.saveHighlights(state.highlights);
  }

  Future<void> removeHighlight(String id) async {
    state = state.copyWith(
      highlights: state.highlights.where((item) => item.id != id).toList(),
    );
    await _repository.saveHighlights(state.highlights);
  }
}
