import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_state.dart';
import '../../core/adaptive.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import '../../services/tts_audio_handler.dart';

class ReadingHomePage extends ConsumerStatefulWidget {
  const ReadingHomePage({super.key});

  @override
  ConsumerState<ReadingHomePage> createState() => _ReadingHomePageState();
}

class _ReadingHomePageState extends ConsumerState<ReadingHomePage> {
  StreamSubscription<MediaItem?>? _mediaSubscription;
  StreamSubscription<PlaybackState>? _playbackSubscription;
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
  }

  @override
  void dispose() {
    _mediaSubscription?.cancel();
    _playbackSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appControllerProvider);
    if (!state.initialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (state.books.isEmpty) return const _EmptyReadingHome();

    final books = _recentBooks(state.books);
    final continueBook = books.first;
    final listening = _listeningBook(state);
    final lastHighlight = state.highlights.isEmpty
        ? null
        : (state.highlights.toList()
                ..sort((a, b) => b.createdAt.compareTo(a.createdAt)))
              .first;
    final totalListeningSeconds = state.listeningRecords.fold<int>(
      0,
      (sum, record) => sum + record.listenedSeconds,
    );

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Center(
          // 大屏限宽居中：首页是纵向信息流，铺满 iPad 宽度会让每行过长。
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: maxReadingColumnWidth),
            child: CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(18, 10, 18, 6),
                  sliver: SliverToBoxAdapter(
                    child: _Header(now: DateTime.now()),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(18, 6, 18, 28),
                  sliver: SliverList.list(
                    children: [
                      _ContinueCard(
                        book: continueBook,
                        onTap: () => context.push('/reader/${continueBook.id}'),
                      ),
                      const SizedBox(height: 20),
                      const _SectionHeader(title: '本机记录', trailing: '本地实时统计'),
                      const SizedBox(height: 9),
                      _StatsCard(
                        progress: continueBook.progress,
                        listeningSeconds: totalListeningSeconds,
                        highlights: state.highlights.length,
                      ),
                      const SizedBox(height: 20),
                      _SectionHeader(
                        title: '最近收听',
                        trailing: state.listeningRecords.isEmpty
                            ? null
                            : '听书历史',
                        onTap: state.listeningRecords.isEmpty
                            ? null
                            : () => context.go('/profile'),
                      ),
                      const SizedBox(height: 9),
                      if (listening == null)
                        const _QuietCard(
                          icon: Icons.headphones_outlined,
                          text: '还没有听书记录，从一本书开始吧',
                        )
                      else
                        _ListeningCard(
                          book: listening.$1,
                          chapterIndex: listening.$2,
                          playing: _playing && _activeBookId == listening.$1.id,
                          onOpen: () =>
                              context.push('/player/${listening.$1.id}'),
                          onToggle: () => _toggleListening(
                            listening.$1,
                            listening.$2,
                            state,
                          ),
                        ),
                      const SizedBox(height: 20),
                      _SectionHeader(
                        title: '最近阅读',
                        trailing: '书架',
                        onTap: () => context.go('/shelf'),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        height: 154,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: books.take(5).length,
                          separatorBuilder: (_, _) => const SizedBox(width: 12),
                          itemBuilder: (_, index) {
                            final book = books[index];
                            return _RecentBook(
                              book: book,
                              onTap: () => context.push('/reader/${book.id}'),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 18),
                      const _SectionHeader(title: '上次划线'),
                      const SizedBox(height: 9),
                      if (lastHighlight == null)
                        const _QuietCard(
                          icon: Icons.format_quote,
                          text: '阅读时长按文字即可添加划线和笔记',
                        )
                      else
                        _HighlightCard(
                          highlight: lastHighlight,
                          book: state.books
                              .where((book) => book.id == lastHighlight.bookId)
                              .firstOrNull,
                          onTap: () =>
                              _openHighlight(lastHighlight, state.books),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String? get _activeBookId => _mediaItem?.extras?['bookId'] as String?;

  List<Book> _recentBooks(List<Book> source) {
    final indexed = source.indexed.toList();
    indexed.sort((a, b) {
      final aTime = a.$2.lastOpenedAt;
      final bTime = b.$2.lastOpenedAt;
      if (aTime == null && bTime == null) return a.$1.compareTo(b.$1);
      if (aTime == null) return 1;
      if (bTime == null) return -1;
      return bTime.compareTo(aTime);
    });
    return indexed.map((value) => value.$2).toList();
  }

  (Book, int)? _listeningBook(AppState state) {
    final activeId = _activeBookId;
    final active = state.books.where((book) => book.id == activeId).firstOrNull;
    if (active != null) {
      return (active, ttsAudioHandler.currentChapter);
    }
    if (state.listeningRecords.isEmpty) return null;
    final records = state.listeningRecords.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    for (final record in records) {
      final book = state.books
          .where((value) => value.id == record.bookId)
          .firstOrNull;
      if (book != null) return (book, record.chapterIndex);
    }
    return null;
  }

  Future<void> _toggleListening(
    Book book,
    int chapterIndex,
    AppState state,
  ) async {
    if (_activeBookId == book.id) {
      if (_playing) {
        await ttsAudioHandler.pause();
      } else {
        await ttsAudioHandler.play();
      }
      return;
    }
    final saved = state.audioProgress
        .where((value) => value.bookId == book.id)
        .firstOrNull;
    await ttsAudioHandler.loadBook(
      book,
      chapterIndex: saved?.chapterIndex ?? chapterIndex,
      characterOffset: saved?.characterOffset ?? 0,
      mode: saved?.mode ?? PlaybackMode.sequential,
    );
    await ttsAudioHandler.applySettings(
      state.ttsSettings.copyWith(
        speed: saved?.speed ?? state.ttsSettings.speed,
      ),
    );
    ref.read(appControllerProvider.notifier).setActiveAudio(book.id);
    await ttsAudioHandler.play();
  }

  Future<void> _openHighlight(Highlight highlight, List<Book> books) async {
    final book = books
        .where((value) => value.id == highlight.bookId)
        .firstOrNull;
    if (book == null) return;
    if (book.chapters.isEmpty) {
      if (mounted) context.push('/reader/${book.id}');
      return;
    }
    final chapter =
        highlight.location.chapterIndex ??
        ((highlight.location.pageNumber ?? 1) - 1);
    await ref
        .read(appControllerProvider.notifier)
        .updateProgress(
          book.id,
          chapter.clamp(0, book.chapters.length - 1),
          (chapter + 1) / book.chapters.length,
        );
    if (mounted) context.push('/reader/${book.id}');
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.now});
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    const weekdays = ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'GOOD MORNING',
                style: TextStyle(
                  color: AppColors.seal,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.7,
                ),
              ),
              SizedBox(height: 4),
              Text(
                '继续阅读',
                style: TextStyle(fontSize: 25, fontWeight: FontWeight.w900),
              ),
            ],
          ),
        ),
        Text(
          '${now.month} 月 ${now.day} 日\n${weekdays[now.weekday - 1]}',
          textAlign: TextAlign.right,
          style: const TextStyle(
            color: AppColors.graphite,
            fontSize: 11,
            height: 1.5,
          ),
        ),
      ],
    );
  }
}

class _ContinueCard extends StatelessWidget {
  const _ContinueCard({required this.book, required this.onTap});
  final Book book;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final chapter = book.chapters.isEmpty
        ? '暂无可阅读章节'
        : book
              .chapters[book.chapterIndex.clamp(0, book.chapters.length - 1)]
              .title;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Ink(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF31483C), Color(0xFF17241E)],
          ),
          borderRadius: BorderRadius.circular(20),
          boxShadow: const [
            BoxShadow(
              color: Color(0x403F5B4E),
              blurRadius: 22,
              offset: Offset(0, 12),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '上次读到',
              style: TextStyle(
                color: Color(0xFFBFD0C5),
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 13),
            Row(
              children: [
                _BookCover(book: book, width: 64, height: 88),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        book.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFF5F0E5),
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        chapter,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFC9D3CC),
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(height: 14),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: book.progress.clamp(0, 1),
                          minHeight: 4,
                          color: const Color(0xFFE9BFA9),
                          backgroundColor: Colors.white12,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '已读 ${(book.progress * 100).round()}%',
                            style: const TextStyle(
                              color: Color(0xFFAEBEB4),
                              fontSize: 10,
                            ),
                          ),
                          const Text(
                            '继续阅读  ›',
                            style: TextStyle(
                              color: Color(0xFFF3E9D8),
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.trailing, this.onTap});
  final String title;
  final String? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(
          title,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
        ),
      ),
      if (trailing != null)
        InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              '$trailing ›',
              style: const TextStyle(color: AppColors.graphite, fontSize: 11),
            ),
          ),
        ),
    ],
  );
}

class _StatsCard extends StatelessWidget {
  const _StatsCard({
    required this.progress,
    required this.listeningSeconds,
    required this.highlights,
  });
  final double progress;
  final int listeningSeconds;
  final int highlights;

  @override
  Widget build(BuildContext context) => Card(
    elevation: 0,
    margin: EdgeInsets.zero,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(15),
      side: BorderSide(color: Theme.of(context).dividerColor),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 15),
      child: Row(
        children: [
          _Stat(value: '${(progress * 100).round()}%', label: '当前进度'),
          _Stat(value: _duration(listeningSeconds), label: '累计听书'),
          _Stat(value: '$highlights', label: '划线笔记'),
        ],
      ),
    ),
  );

  static String _duration(int seconds) {
    if (seconds < 60) return '${seconds}s';
    if (seconds < 3600) return '${seconds ~/ 60}m';
    return '${(seconds / 3600).toStringAsFixed(1)}h';
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            color: AppColors.bamboo,
            fontSize: 20,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          style: const TextStyle(color: AppColors.graphite, fontSize: 10),
        ),
      ],
    ),
  );
}

class _ListeningCard extends StatelessWidget {
  const _ListeningCard({
    required this.book,
    required this.chapterIndex,
    required this.playing,
    required this.onOpen,
    required this.onToggle,
  });
  final Book book;
  final int chapterIndex;
  final bool playing;
  final VoidCallback onOpen;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final chapter = book.chapters.isEmpty
        ? '暂无章节'
        : book.chapters[chapterIndex.clamp(0, book.chapters.length - 1)].title;
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(15),
        side: BorderSide(color: Theme.of(context).dividerColor),
      ),
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(15),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Color(book.coverColor),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Text(
                  book.title.characters.first,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      book.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      chapter,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.graphite,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton.filled(
                tooltip: playing ? '暂停' : '继续播放',
                onPressed: onToggle,
                style: IconButton.styleFrom(
                  backgroundColor: AppColors.bamboo,
                  foregroundColor: Colors.white,
                ),
                icon: Icon(
                  playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecentBook extends StatelessWidget {
  const _RecentBook({required this.book, required this.onTap});
  final Book book;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 78,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _BookCover(book: book, width: 78, height: 112),
          const SizedBox(height: 6),
          Text(
            book.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    ),
  );
}

class _BookCover extends StatelessWidget {
  const _BookCover({
    required this.book,
    required this.width,
    required this.height,
  });
  final Book book;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    alignment: Alignment.bottomLeft,
    padding: const EdgeInsets.all(9),
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color(book.coverColor),
          Color(book.coverColor).withValues(alpha: .68),
        ],
      ),
      borderRadius: BorderRadius.circular(7),
      boxShadow: const [
        BoxShadow(color: Colors.black26, blurRadius: 10, offset: Offset(0, 6)),
      ],
    ),
    child: Text(
      book.title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: Colors.white,
        fontSize: width < 70 ? 11 : 12,
        fontWeight: FontWeight.w900,
      ),
    ),
  );
}

class _HighlightCard extends StatelessWidget {
  const _HighlightCard({
    required this.highlight,
    required this.book,
    required this.onTap,
  });
  final Highlight highlight;
  final Book? book;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(14),
    child: Ink(
      padding: const EdgeInsets.fromLTRB(18, 15, 16, 14),
      decoration: BoxDecoration(
        color: AppColors.bambooSoft.withValues(alpha: .78),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '“ ${highlight.excerpt}',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.eyeInk,
              fontSize: 14,
              height: 1.7,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              book == null ? '本地划线' : '《${book!.title}》',
              style: const TextStyle(color: AppColors.graphite, fontSize: 10),
            ),
          ),
        ],
      ),
    ),
  );
}

class _QuietCard extends StatelessWidget {
  const _QuietCard({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Theme.of(context).cardColor,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: Theme.of(context).dividerColor),
    ),
    child: Row(
      children: [
        Icon(icon, color: AppColors.graphite),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(color: AppColors.graphite, fontSize: 12),
          ),
        ),
      ],
    ),
  );
}

class _EmptyReadingHome extends StatelessWidget {
  const _EmptyReadingHome();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.menu_book_outlined,
              size: 54,
              color: AppColors.graphite,
            ),
            const SizedBox(height: 14),
            const Text(
              '从一本本地书开始',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 7),
            const Text(
              '导入 TXT、EPUB 或 PDF 后，这里会显示继续阅读、最近收听和划线。',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.graphite, height: 1.6),
            ),
            const SizedBox(height: 18),
            FilledButton(
              onPressed: () => context.go('/shelf'),
              child: const Text('前往书架'),
            ),
          ],
        ),
      ),
    ),
  );
}
