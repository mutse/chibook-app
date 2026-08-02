import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../data/book_repository.dart';

final bookRepositoryProvider = Provider((ref) => BookRepository());

final appControllerProvider = NotifierProvider<AppController, AppState>(
  AppController.new,
);

class AppState {
  const AppState({
    this.books = const [],
    this.settings = const ReaderSettings(),
    this.initialized = false,
    this.isGrid = true,
    this.activeAudioBookId,
    this.recentSearches = const ['沈从文', '人间词话', '鲁迅', '瓦尔登湖'],
  });

  final List<Book> books;
  final ReaderSettings settings;
  final bool initialized;
  final bool isGrid;
  final String? activeAudioBookId;
  final List<String> recentSearches;

  AppState copyWith({
    List<Book>? books,
    ReaderSettings? settings,
    bool? initialized,
    bool? isGrid,
    String? activeAudioBookId,
    List<String>? recentSearches,
  }) => AppState(
    books: books ?? this.books,
    settings: settings ?? this.settings,
    initialized: initialized ?? this.initialized,
    isGrid: isGrid ?? this.isGrid,
    activeAudioBookId: activeAudioBookId ?? this.activeAudioBookId,
    recentSearches: recentSearches ?? this.recentSearches,
  );
}

class AppController extends Notifier<AppState> {
  BookRepository get _repository => ref.read(bookRepositoryProvider);

  @override
  AppState build() {
    Future.microtask(_initialize);
    return const AppState();
  }

  Future<void> _initialize() async {
    final values = await Future.wait([
      _repository.loadBooks(),
      _repository.loadSettings(),
    ]);
    state = state.copyWith(
      books: values[0] as List<Book>,
      settings: values[1] as ReaderSettings,
      initialized: true,
    );
  }

  void setGrid(bool value) => state = state.copyWith(isGrid: value);

  Future<bool> importBook() async {
    final book = await _repository.importBook();
    if (book == null) return false;
    state = state.copyWith(books: [book, ...state.books]);
    await _repository.saveBooks(state.books);
    return true;
  }

  Future<void> removeBook(String id) async {
    state = state.copyWith(
      books: state.books.where((e) => e.id != id).toList(),
    );
    await _repository.saveBooks(state.books);
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

  void setActiveAudio(String id) =>
      state = state.copyWith(activeAudioBookId: id);

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
}
