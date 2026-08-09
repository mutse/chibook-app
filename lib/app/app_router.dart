import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/models.dart';
import '../features/home/reading_home_page.dart';
import '../features/player/player_page.dart';
import '../features/profile/profile_page.dart';
import '../features/profile/tts_settings_page.dart';
import '../features/reader/reader_page.dart';
import '../features/search/search_page.dart';
import '../features/shelf/shelf_page.dart';
import '../services/tts_audio_handler.dart';
import 'app_state.dart';
import 'splash_page.dart';

final _rootNavigatorKey = GlobalKey<NavigatorState>();

final appRouter = GoRouter(
  navigatorKey: _rootNavigatorKey,
  initialLocation: '/splash',
  routes: [
    GoRoute(path: '/splash', builder: (_, _) => const SplashPage()),
    StatefulShellRoute.indexedStack(
      builder: (context, state, shell) => AppShell(shell: shell),
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/reading',
              builder: (_, _) => const ReadingHomePage(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/shelf',
              builder: (_, _) => const ShelfPage(),
              routes: [
                GoRoute(path: 'search', builder: (_, _) => const SearchPage()),
              ],
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(path: '/profile', builder: (_, _) => const ProfilePage()),
          ],
        ),
      ],
    ),
    GoRoute(
      path: '/reader/:id',
      parentNavigatorKey: _rootNavigatorKey,
      builder: (_, state) => ReaderPage(bookId: state.pathParameters['id']!),
    ),
    GoRoute(
      path: '/player/:id',
      parentNavigatorKey: _rootNavigatorKey,
      builder: (_, state) => PlayerPage(bookId: state.pathParameters['id']!),
    ),
    GoRoute(
      path: '/settings/tts',
      parentNavigatorKey: _rootNavigatorKey,
      builder: (_, _) => const TtsSettingsPage(),
    ),
  ],
);

class AppShell extends ConsumerStatefulWidget {
  const AppShell({required this.shell, super.key});
  final StatefulNavigationShell shell;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  StreamSubscription<MediaItem?>? _mediaSubscription;
  StreamSubscription<PlaybackState>? _playbackSubscription;
  StreamSubscription<dynamic>? _eventSubscription;
  Timer? _positionSaveTimer;
  MediaItem? _mediaItem;
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    _mediaItem = ttsAudioHandler.mediaItem.value;
    _playing = ttsAudioHandler.playbackState.value.playing;
    _mediaSubscription = ttsAudioHandler.mediaItem.listen((item) {
      if (mounted) setState(() => _mediaItem = item);
    });
    _playbackSubscription = ttsAudioHandler.playbackState.listen((state) {
      if (mounted) setState(() => _playing = state.playing);
    });
    _eventSubscription = ttsAudioHandler.customEvent.listen((event) {
      if (event is! Map || event['bookId'] == null) return;
      if (!{'progress', 'chapter', 'mode'}.contains(event['type'])) return;
      if (_positionSaveTimer != null) return;
      _positionSaveTimer = Timer(const Duration(seconds: 1), () {
        _positionSaveTimer = null;
        _saveCurrentPosition();
      });
    });
  }

  @override
  void dispose() {
    _saveCurrentPosition();
    _mediaSubscription?.cancel();
    _playbackSubscription?.cancel();
    _eventSubscription?.cancel();
    _positionSaveTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = _mediaItem;
    final bookId = item?.extras?['bookId'] as String?;
    final progress = bookId == null
        ? null
        : ref.watch(
            appControllerProvider.select(
              (state) => state.audioProgress
                  .where((value) => value.bookId == bookId)
                  .firstOrNull,
            ),
          );
    return Scaffold(
      body: widget.shell,
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (item != null && bookId != null)
            Material(
              color: Theme.of(context).cardColor,
              child: InkWell(
                onTap: () => context.push('/player/$bookId'),
                child: Column(
                  children: [
                    if (progress != null)
                      LinearProgressIndicator(
                        value: _chapterProgress(bookId, progress),
                        minHeight: 2,
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 7, 8, 7),
                      child: Row(
                        children: [
                          const CircleAvatar(
                            radius: 18,
                            child: Icon(Icons.headphones, size: 18),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.album ?? '正在收听',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                Text(
                                  item.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: _playing ? '暂停' : '继续播放',
                            onPressed: _playing
                                ? ttsAudioHandler.pause
                                : ttsAudioHandler.play,
                            icon: Icon(
                              _playing
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          NavigationBar(
            selectedIndex: widget.shell.currentIndex,
            onDestinationSelected: (index) => widget.shell.goBranch(index),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.menu_book_outlined),
                selectedIcon: Icon(Icons.menu_book_rounded),
                label: '阅读',
              ),
              NavigationDestination(
                icon: Icon(Icons.auto_stories_outlined),
                selectedIcon: Icon(Icons.auto_stories),
                label: '书架',
              ),
              NavigationDestination(
                icon: Icon(Icons.person_outline),
                selectedIcon: Icon(Icons.person),
                label: '我的',
              ),
            ],
          ),
        ],
      ),
    );
  }

  double _chapterProgress(String bookId, AudioProgress progress) {
    final books = ref
        .read(appControllerProvider)
        .books
        .where((book) => book.id == bookId);
    if (books.isEmpty || books.first.chapters.isEmpty) return 0;
    final book = books.first;
    final chapterIndex = progress.chapterIndex.clamp(
      0,
      book.chapters.length - 1,
    );
    final length = book.chapters[chapterIndex].content.length;
    final fraction = length == 0 ? 0.0 : progress.characterOffset / length;
    return ((chapterIndex + fraction) / book.chapters.length).clamp(0, 1);
  }

  void _saveCurrentPosition() {
    final bookId = ttsAudioHandler.currentBookId;
    if (bookId == null) return;
    final books = ref
        .read(appControllerProvider)
        .books
        .where((book) => book.id == bookId);
    if (books.isEmpty || books.first.chapters.isEmpty) return;
    final book = books.first;
    final chapter = ttsAudioHandler.currentChapter.clamp(
      0,
      book.chapters.length - 1,
    );
    final length = book.chapters[chapter].content.length;
    final offset = ttsAudioHandler.characterOffset.clamp(0, length);
    final fraction = length == 0 ? 0.0 : offset / length;
    final overall = ((chapter + fraction) / book.chapters.length)
        .clamp(0, 1)
        .toDouble();
    final controller = ref.read(appControllerProvider.notifier);
    unawaited(controller.updateProgress(bookId, chapter, overall));
    unawaited(
      controller.saveAudioPosition(
        bookId: bookId,
        chapterIndex: chapter,
        characterOffset: offset,
        speed: ttsAudioHandler.speed,
        mode: ttsAudioHandler.mode,
        countListening: _playing,
      ),
    );
  }
}
