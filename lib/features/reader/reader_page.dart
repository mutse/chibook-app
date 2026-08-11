import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../app/app_state.dart';
import '../../core/adaptive.dart';
import '../../core/models.dart';
import '../../core/sentence_bounds.dart';
import '../../core/theme.dart';
import '../../services/tts_audio_handler.dart';

class ReaderPage extends ConsumerWidget {
  const ReaderPage({required this.bookId, super.key});
  final String bookId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final books = ref.watch(appControllerProvider.select((s) => s.books));
    final matches = books.where((e) => e.id == bookId);
    if (matches.isEmpty) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final book = matches.first;
    if (book.format == BookFormat.pdf) return PdfReaderPage(book: book);
    return ReflowReaderPage(book: book);
  }
}

class ReflowReaderPage extends ConsumerStatefulWidget {
  const ReflowReaderPage({required this.book, super.key});
  final Book book;

  @override
  ConsumerState<ReflowReaderPage> createState() => _ReflowReaderPageState();
}

class _ReflowReaderPageState extends ConsumerState<ReflowReaderPage> {
  late final PageController _pages;
  late int _chapter;
  bool _chrome = false;
  bool _playing = false;
  int? _spokenChapter;
  int _spokenStart = 0;
  int _spokenEnd = 0;
  int? _targetChapter;
  DateTime? _followHoldUntil;
  StreamSubscription? _playbackSubscription;
  StreamSubscription? _eventSubscription;

  /// 用户手动翻页/跳章后，自动跟随暂停一小段时间，避免与用户抢夺位置。
  bool get _followHeld =>
      _followHoldUntil != null && DateTime.now().isBefore(_followHoldUntil!);

  void _holdFollow() =>
      _followHoldUntil = DateTime.now().add(const Duration(seconds: 4));

  @override
  void initState() {
    super.initState();
    _chapter = widget.book.chapterIndex.clamp(
      0,
      widget.book.chapters.length - 1,
    );
    _pages = PageController(initialPage: _chapter);
    if (ttsAudioHandler.currentBookId == widget.book.id) {
      _spokenChapter = ttsAudioHandler.currentChapter;
      _spokenStart = _spokenEnd = ttsAudioHandler.characterOffset;
      _playing = ttsAudioHandler.playbackState.value.playing;
    }
    _playbackSubscription = ttsAudioHandler.playbackState.listen((state) {
      if (mounted) setState(() => _playing = state.playing);
    });
    _eventSubscription = ttsAudioHandler.customEvent.listen(_handleAudioEvent);
  }

  @override
  void dispose() {
    _playbackSubscription?.cancel();
    _eventSubscription?.cancel();
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appControllerProvider.select((s) => s.settings));
    final background = switch (settings.theme) {
      ReaderTheme.dark => const Color(0xFF1B1A17),
      ReaderTheme.eye => AppColors.eye,
      ReaderTheme.light => AppColors.paper,
    };
    final foreground = switch (settings.theme) {
      ReaderTheme.dark => const Color(0xFFD8D0BE),
      ReaderTheme.eye => AppColors.eyeInk,
      ReaderTheme.light => AppColors.ink,
    };
    return Scaffold(
      backgroundColor: background,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final form = formFactorOf(constraints.maxWidth);
          final reader = _buildReadingSurface(
            settings: settings,
            foreground: foreground,
            form: form,
          );
          if (!form.hasSidebar) return reader;
          // 大屏常驻侧栏：目录与本书划线。
          return Row(
            children: [
              SizedBox(
                width: 296,
                child: _ReaderSidebar(
                  book: widget.book,
                  currentChapter: _chapter,
                  foreground: foreground,
                  onSelectChapter: _jumpToChapter,
                  onSpeakHighlight: _speakFrom,
                ),
              ),
              const VerticalDivider(width: 1, thickness: 1),
              Expanded(child: reader),
            ],
          );
        },
      ),
    );
  }

  Widget _buildReadingSurface({
    required ReaderSettings settings,
    required Color foreground,
    required FormFactor form,
  }) => LayoutBuilder(
    builder: (context, constraints) {
      // 正文限宽后左右会留出页边距；翻页热区必须按正文列的实际边界划分，
      // 否则大屏上点击页边距（甚至侧栏一侧）会误触翻页。
      final columnWidth = readingColumnWidth(constraints.maxWidth);
      final margin = (constraints.maxWidth - columnWidth) / 2;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) {
          final dx = details.localPosition.dx - margin;
          if (dx < columnWidth * .25 && _pages.hasClients) {
            _holdFollow();
            _pages.previousPage(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOut,
            );
          } else if (dx > columnWidth * .75 && _pages.hasClients) {
            _holdFollow();
            _pages.nextPage(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOut,
            );
          } else {
            setState(() => _chrome = !_chrome);
          }
        },
        child: Stack(
          children: [
            SafeArea(
              child: Center(
                child: SizedBox(
                  width: columnWidth,
                  child: PageView.builder(
                    controller: _pages,
                    itemCount: widget.book.chapters.length,
                    onPageChanged: (index) {
                      setState(() {
                        _chapter = index;
                        if (_targetChapter == index) {
                          // 自动跟随到达目标章，不算用户操作。
                          _targetChapter = null;
                        } else if (_targetChapter == null &&
                            _playing &&
                            _spokenChapter != null &&
                            index != _spokenChapter) {
                          // 播放中用户手动划走：暂停自动翻章，别立刻拽回来。
                          // 跨多章的自动动画会途经中间页，此时 _targetChapter
                          // 仍非空，不能被误判成用户操作。
                          _holdFollow();
                        }
                      });
                      ref
                          .read(appControllerProvider.notifier)
                          .updateProgress(
                            widget.book.id,
                            index,
                            (index + 1) / widget.book.chapters.length,
                          );
                    },
                    itemBuilder: (_, index) => _ChapterPage(
                      bookId: widget.book.id,
                      chapter: widget.book.chapters[index],
                      chapterIndex: index,
                      settings: settings,
                      color: foreground,
                      page: index + 1,
                      count: widget.book.chapters.length,
                      spokenStart: _spokenChapter == index
                          ? _spokenStart
                          : null,
                      spokenEnd: _spokenChapter == index ? _spokenEnd : null,
                      autoFollow: _playing && _spokenChapter == index,
                      onSpeakFrom: (offset) => _speakFrom(index, offset),
                      onUserScroll: _holdFollow,
                    ),
                  ),
                ),
              ),
            ),
            if (settings.brightness < 1)
              Positioned.fill(
                child: IgnorePointer(
                  child: ColoredBox(
                    color: Colors.black.withValues(
                      alpha: (1 - settings.brightness) * .62,
                    ),
                  ),
                ),
              ),
            _ReaderTopBar(
              visible: _chrome,
              title: widget.book.chapters[_chapter].title,
              onBack: () => context.pop(),
              onContents: _showContents,
              // 大屏侧栏已常驻，顶栏不再重复提供目录入口。
              showContentsAction: !form.hasSidebar,
            ),
            _ReaderBottomBar(
              visible: _chrome,
              onContents: _showContents,
              onSettings: _showSettings,
              showContents: !form.hasSidebar,
            ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 240),
              right: 16,
              bottom: _chrome ? 104 : 30,
              child: FloatingActionButton.extended(
                heroTag: 'listen-${widget.book.id}',
                onPressed: () => context.push('/player/${widget.book.id}'),
                backgroundColor: AppColors.bamboo,
                foregroundColor: Colors.white,
                icon: const Icon(Icons.play_arrow_rounded, size: 19),
                label: const Text('听书'),
              ),
            ),
            if (_playing && _spokenChapter != null)
              Positioned(
                top: MediaQuery.paddingOf(context).top + 10,
                right: 16,
                child: const IgnorePointer(child: _FollowingBadge()),
              ),
          ],
        ),
      );
    },
  );

  /// 跳章统一入口：侧栏与目录弹层共用，避免出现两套跳转逻辑。
  void _jumpToChapter(int index) {
    if (!_pages.hasClients) return;
    _holdFollow();
    _pages.animateToPage(
      index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  /// 「选中跟读」统一入口：正文选中菜单与侧栏划线共用。
  ///
  /// 与播放页共用同一 [ttsAudioHandler] 和同一份「章节 + 字符偏移」位置，
  /// 不新建播放通道；本书未加载时按已保存的听书进度补齐倍速与模式。
  Future<void> _speakFrom(int chapterIndex, int offset) async {
    final book = widget.book;
    if (book.chapters.isEmpty) return;
    final controller = ref.read(appControllerProvider.notifier);
    final ttsSettings = ref.read(appControllerProvider).ttsSettings;
    final clampedChapter = chapterIndex.clamp(0, book.chapters.length - 1);
    final clampedOffset = offset.clamp(
      0,
      book.chapters[clampedChapter].content.length,
    );
    // 明确的播放意图：清除手动翻页的让位窗口，立即恢复自动跟随。
    _followHoldUntil = null;
    controller.setActiveAudio(book.id);
    if (ttsAudioHandler.currentBookId != book.id) {
      final saved = controller.audioProgressFor(book.id);
      await ttsAudioHandler.loadBook(
        book,
        chapterIndex: clampedChapter,
        characterOffset: clampedOffset,
        mode: saved?.mode ?? PlaybackMode.sequential,
      );
      await ttsAudioHandler.applySettings(
        ttsSettings.copyWith(speed: saved?.speed ?? ttsSettings.speed),
      );
      await ttsAudioHandler.play();
    } else if (ttsAudioHandler.currentChapter != clampedChapter) {
      await ttsAudioHandler.loadBook(
        book,
        chapterIndex: clampedChapter,
        characterOffset: clampedOffset,
        mode: ttsAudioHandler.mode,
      );
      await ttsAudioHandler.play();
    } else {
      await ttsAudioHandler.seekToCharacter(clampedOffset);
    }
  }

  void _handleAudioEvent(dynamic event) {
    if (!mounted || event is! Map || event['bookId'] != widget.book.id) return;
    if (event['type'] == 'error') {
      // 阅读页也能发起朗读（选中「朗读」），失败必须明确提示，不能静默。
      // 播放页在栈顶时由它负责提示，避免重复弹两条。
      if (ModalRoute.of(context)?.isCurrent ?? true) {
        final message = event['message']?.toString() ?? '播放失败';
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
      return;
    }
    if (!{'progress', 'chapter'}.contains(event['type'])) return;
    final chapter = (event['chapter'] as int? ?? _spokenChapter ?? 0).clamp(
      0,
      widget.book.chapters.length - 1,
    );
    setState(() {
      _spokenChapter = chapter;
      _spokenStart = event['start'] as int? ?? _spokenStart;
      _spokenEnd = event['end'] as int? ?? _spokenEnd;
    });
    if (_playing &&
        chapter != _chapter &&
        chapter != _targetChapter &&
        !_followHeld) {
      _targetChapter = chapter;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!_pages.hasClients || !_playing || _followHeld) {
          // 本次翻章被放弃时必须清除目标章，否则后续同章事件会被
          // `chapter != _targetChapter` 一直挡住，自动翻页再也不会恢复。
          _targetChapter = null;
          return;
        }
        _pages
            .animateToPage(
              chapter,
              duration: const Duration(milliseconds: 360),
              curve: Curves.easeInOutCubic,
            )
            // 动画结束（含被用户手势打断）后清除目标章；否则打断后
            // `chapter != _targetChapter` 会一直挡住后续自动翻页。
            .whenComplete(() => _targetChapter = null);
      });
    }
  }

  void _showContents() {
    showAdaptiveSheet<void>(
      context: context,
      scrollable: true,
      builder: (context) => SafeArea(
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: widget.book.chapters.length,
          itemBuilder: (_, index) => ListTile(
            selected: index == _chapter,
            selectedColor: AppColors.seal,
            leading: Text('${index + 1}'.padLeft(2, '0')),
            title: Text(widget.book.chapters[index].title),
            trailing: index == _chapter
                ? const Icon(Icons.bookmark, color: AppColors.seal)
                : null,
            onTap: () {
              Navigator.pop(context);
              _jumpToChapter(index);
            },
          ),
        ),
      ),
    );
  }

  void _showSettings() {
    showAdaptiveSheet<void>(
      context: context,
      builder: (_) => const _ReaderSettingsSheet(),
    );
  }
}

class _ChapterPage extends StatefulWidget {
  const _ChapterPage({
    required this.bookId,
    required this.chapter,
    required this.chapterIndex,
    required this.settings,
    required this.color,
    required this.page,
    required this.count,
    required this.spokenStart,
    required this.spokenEnd,
    required this.autoFollow,
    required this.onSpeakFrom,
    required this.onUserScroll,
  });
  final String bookId;
  final Chapter chapter;
  final int chapterIndex;
  final ReaderSettings settings;
  final Color color;
  final int page;
  final int count;
  final int? spokenStart;
  final int? spokenEnd;
  final bool autoFollow;

  /// 选中「朗读」时回调选区起点字符偏移，由上层负责驱动 handler。
  final ValueChanged<int> onSpeakFrom;

  /// 用户拖动正文时通知上层，让章节级自动翻页一并让位。
  final VoidCallback onUserScroll;

  @override
  State<_ChapterPage> createState() => _ChapterPageState();
}

class _ChapterPageState extends State<_ChapterPage> {
  final ScrollController _scroll = ScrollController();
  Timer? _followTimer;
  DateTime? _userScrollHoldUntil;

  /// 用户拖动正文后暂停自动跟随滚动，避免和用户抢夺滚动位置。
  bool get _userScrollHeld =>
      _userScrollHoldUntil != null &&
      DateTime.now().isBefore(_userScrollHoldUntil!);

  @override
  void initState() {
    super.initState();
    if (widget.autoFollow) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleFollow());
    }
  }

  @override
  void didUpdateWidget(covariant _ChapterPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.autoFollow &&
        (widget.spokenEnd != oldWidget.spokenEnd || !oldWidget.autoFollow)) {
      _scheduleFollow();
    }
  }

  @override
  void dispose() {
    _followTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(25, 58, 25, 22),
    child: Column(
      children: [
        Text(
          widget.chapter.title,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: widget.color,
            fontWeight: FontWeight.w800,
            fontSize: widget.settings.fontSize + 2,
          ),
        ),
        const SizedBox(height: 24),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              // dragDetails 非空才是用户手指拖动；自动跟随的 animateTo
              // 不带 dragDetails，不会误触发让位。
              final isUserDrag = switch (notification) {
                ScrollStartNotification(:final dragDetails) =>
                  dragDetails != null,
                ScrollUpdateNotification(:final dragDetails) =>
                  dragDetails != null,
                _ => false,
              };
              if (isUserDrag) {
                _userScrollHoldUntil = DateTime.now().add(
                  const Duration(seconds: 4),
                );
                widget.onUserScroll();
              }
              return false;
            },
            child: SingleChildScrollView(
              controller: _scroll,
              child: SelectableText.rich(
                _textSpan(),
                contextMenuBuilder: (context, editableState) {
                  final selection = editableState.textEditingValue.selection;
                  Future<void> save({required bool withNote}) async {
                    if (!selection.isValid || selection.isCollapsed) return;
                    final start = selection.start.clamp(
                      0,
                      widget.chapter.content.length,
                    );
                    final end = selection.end.clamp(
                      start,
                      widget.chapter.content.length,
                    );
                    final excerpt = widget.chapter.content.substring(
                      start,
                      end,
                    );
                    String? note;
                    if (withNote) {
                      note = await _requestNote(context);
                      if (note == null || !context.mounted) return;
                    }
                    await ProviderScope.containerOf(context)
                        .read(appControllerProvider.notifier)
                        .addHighlight(
                          bookId: widget.bookId,
                          excerpt: excerpt,
                          location: ReadingLocation.text(
                            chapterIndex: widget.chapterIndex,
                            startOffset: start,
                            endOffset: end,
                          ),
                          note: note,
                        );
                    editableState.hideToolbar();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(withNote ? '笔记已保存' : '划线已保存')),
                      );
                    }
                  }

                  return AdaptiveTextSelectionToolbar.buttonItems(
                    anchors: editableState.contextMenuAnchors,
                    buttonItems: [
                      ...editableState.contextMenuButtonItems,
                      ContextMenuButtonItem(
                        label: '朗读',
                        onPressed: () {
                          if (!selection.isValid) return;
                          final start = selection.start.clamp(
                            0,
                            widget.chapter.content.length,
                          );
                          editableState.hideToolbar();
                          widget.onSpeakFrom(start);
                        },
                      ),
                      ContextMenuButtonItem(
                        label: '划线',
                        onPressed: () => save(withNote: false),
                      ),
                      ContextMenuButtonItem(
                        label: '笔记',
                        onPressed: () => save(withNote: true),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
        Text(
          '${widget.page} / ${widget.count}',
          style: TextStyle(
            color: widget.color.withValues(alpha: .52),
            fontSize: 10,
          ),
        ),
      ],
    ),
  );

  TextSpan _textSpan() {
    final text = widget.chapter.content;
    final baseStyle = TextStyle(
      color: widget.color,
      fontSize: widget.settings.fontSize,
      height: widget.settings.lineHeight,
      letterSpacing: .35,
    );
    final rawStart = (widget.spokenStart ?? 0).clamp(0, text.length);
    final rawEnd = (widget.spokenEnd ?? rawStart).clamp(rawStart, text.length);
    if (rawEnd <= rawStart) return TextSpan(text: text, style: baseStyle);
    // 高亮按句对齐：TTS 回调粒度不稳定（逐词甚至逐字），直接高亮原始
    // 区间会闪烁；扩展到整句后，同一句内的连续回调不再改变高亮范围。
    final (:start, :end) = sentenceBoundsFor(text, rawStart, rawEnd);
    if (end <= start) return TextSpan(text: text, style: baseStyle);
    return TextSpan(
      style: baseStyle,
      children: [
        if (start > 0) TextSpan(text: text.substring(0, start)),
        TextSpan(
          text: text.substring(start, end),
          style: TextStyle(
            backgroundColor: AppColors.seal.withValues(alpha: .32),
            fontWeight: FontWeight.w800,
          ),
        ),
        if (end < text.length) TextSpan(text: text.substring(end)),
      ],
    );
  }

  void _scheduleFollow() {
    _followTimer?.cancel();
    _followTimer = Timer(const Duration(milliseconds: 80), () {
      if (!mounted || !_scroll.hasClients || !widget.autoFollow) return;
      // 用户刚拖动过正文：让位窗口内不自动滚动，窗口结束后
      // 下一次朗读进度回调会重新触发跟随。
      if (_userScrollHeld) return;
      final length = widget.chapter.content.length;
      if (length == 0) return;
      final fraction = ((widget.spokenEnd ?? 0) / length).clamp(0.0, 1.0);
      final position = _scroll.position;
      final target =
          (position.maxScrollExtent * fraction -
                  position.viewportDimension * .32)
              .clamp(0.0, position.maxScrollExtent);
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
  }
}

/// 大屏常驻侧栏：目录 + 本书划线。
///
/// 选章走与目录弹层相同的 [_ReflowReaderPageState._jumpToChapter]，
/// 不新增第二套跳转逻辑；朗读跟随翻章时选中项随 currentChapter 同步。
class _ReaderSidebar extends ConsumerStatefulWidget {
  const _ReaderSidebar({
    required this.book,
    required this.currentChapter,
    required this.foreground,
    required this.onSelectChapter,
    required this.onSpeakHighlight,
  });
  final Book book;
  final int currentChapter;
  final Color foreground;
  final ValueChanged<int> onSelectChapter;

  /// 划线条目的「朗读」入口：参数为（章节索引，字符偏移）。
  final void Function(int chapterIndex, int offset) onSpeakHighlight;

  @override
  ConsumerState<_ReaderSidebar> createState() => _ReaderSidebarState();
}

class _ReaderSidebarState extends ConsumerState<_ReaderSidebar> {
  bool _showNotes = false;
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final highlights = ref.watch(
      appControllerProvider.select(
        (state) => state.highlights
            .where((item) => item.bookId == widget.book.id)
            .toList(),
      ),
    );
    return Column(
      children: [
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: SegmentedButton<bool>(
              segments: [
                const ButtonSegment(value: false, label: Text('目录')),
                ButtonSegment(
                  value: true,
                  label: Text(
                    '划线 ${highlights.isEmpty ? '' : highlights.length}',
                  ),
                ),
              ],
              selected: {_showNotes},
              showSelectedIcon: false,
              onSelectionChanged: (value) =>
                  setState(() => _showNotes = value.first),
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _showNotes ? _buildNotes(highlights) : _buildChapters(),
        ),
      ],
    );
  }

  Widget _buildChapters() => ListView.builder(
    controller: _scroll,
    itemCount: widget.book.chapters.length,
    itemBuilder: (_, index) => ListTile(
      dense: true,
      selected: index == widget.currentChapter,
      selectedColor: AppColors.seal,
      leading: Text('${index + 1}'.padLeft(2, '0')),
      title: Text(
        widget.book.chapters[index].title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: index == widget.currentChapter
          ? const Icon(Icons.bookmark, size: 18, color: AppColors.seal)
          : null,
      onTap: () => widget.onSelectChapter(index),
    ),
  );

  Widget _buildNotes(List<Highlight> highlights) {
    if (highlights.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Text(
            '本书还没有划线\n长按正文选择文字即可添加',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.graphite, fontSize: 12),
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: highlights.length,
      separatorBuilder: (_, _) => const Divider(height: 12),
      itemBuilder: (_, index) {
        final item = highlights[index];
        final chapterIndex = item.location.chapterIndex;
        return ListTile(
          dense: true,
          title: Text(
            '“${item.excerpt}”',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12.5),
          ),
          subtitle: item.note == null
              ? null
              : Text(
                  '笔记：${item.note}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11),
                ),
          trailing: chapterIndex == null
              ? null
              : IconButton(
                  tooltip: '从此处朗读',
                  icon: const Icon(Icons.headphones_outlined, size: 18),
                  onPressed: () => widget.onSpeakHighlight(
                    chapterIndex.clamp(0, widget.book.chapters.length - 1),
                    item.location.startOffset ?? 0,
                  ),
                ),
          onTap: chapterIndex == null
              ? null
              : () => widget.onSelectChapter(
                  chapterIndex.clamp(0, widget.book.chapters.length - 1),
                ),
        );
      },
    );
  }
}

class _FollowingBadge extends StatelessWidget {
  const _FollowingBadge();

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: AppColors.bamboo.withValues(alpha: .92),
      borderRadius: BorderRadius.circular(20),
    ),
    child: const Padding(
      padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.graphic_eq, size: 15, color: Colors.white),
          SizedBox(width: 5),
          Text(
            '自动跟读',
            style: TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    ),
  );
}

class _ReaderTopBar extends StatelessWidget {
  const _ReaderTopBar({
    required this.visible,
    required this.title,
    required this.onBack,
    required this.onContents,
    this.showContentsAction = true,
  });
  final bool visible;
  final String title;
  final VoidCallback onBack;
  final VoidCallback onContents;
  final bool showContentsAction;

  @override
  Widget build(BuildContext context) => AnimatedPositioned(
    duration: const Duration(milliseconds: 240),
    left: 0,
    right: 0,
    top: visible ? 0 : -110,
    child: Material(
      color: Theme.of(context).scaffoldBackgroundColor.withValues(alpha: .97),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 58,
          child: Row(
            children: [
              IconButton(
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back_ios_new, size: 19),
              ),
              Expanded(
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              if (showContentsAction)
                IconButton(
                  onPressed: onContents,
                  icon: const Icon(Icons.more_horiz),
                )
              else
                const SizedBox(width: 48),
            ],
          ),
        ),
      ),
    ),
  );
}

class _ReaderBottomBar extends StatelessWidget {
  const _ReaderBottomBar({
    required this.visible,
    required this.onContents,
    required this.onSettings,
    this.showContents = true,
  });
  final bool visible;
  final VoidCallback onContents;
  final VoidCallback onSettings;
  final bool showContents;

  @override
  Widget build(BuildContext context) => AnimatedPositioned(
    duration: const Duration(milliseconds: 240),
    left: 0,
    right: 0,
    bottom: visible ? 0 : -130,
    child: Material(
      color: Theme.of(context).cardColor,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 78,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              if (showContents)
                _ReaderAction(
                  icon: Icons.format_list_bulleted,
                  label: '目录',
                  onTap: onContents,
                ),
              _ReaderAction(
                icon: Icons.brightness_6_outlined,
                label: '亮度',
                onTap: onSettings,
              ),
              _ReaderAction(
                icon: Icons.text_fields,
                label: '设置',
                onTap: onSettings,
              ),
              _ReaderAction(
                icon: Icons.brightness_2_outlined,
                label: '主题',
                onTap: onSettings,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _ReaderAction extends StatelessWidget {
  const _ReaderAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkResponse(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 21),
          const SizedBox(height: 5),
          Text(label, style: const TextStyle(fontSize: 10)),
        ],
      ),
    ),
  );
}

class _ReaderSettingsSheet extends ConsumerWidget {
  const _ReaderSettingsSheet();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appControllerProvider.select((s) => s.settings));
    final controller = ref.read(appControllerProvider.notifier);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('字号', style: TextStyle(fontWeight: FontWeight.w700)),
            Row(
              children: [
                const Text('A', style: TextStyle(fontSize: 13)),
                Expanded(
                  child: Slider(
                    value: settings.fontSize,
                    min: 14,
                    max: 24,
                    onChanged: (v) =>
                        controller.setSettings(settings.copyWith(fontSize: v)),
                  ),
                ),
                const Text('A', style: TextStyle(fontSize: 23)),
              ],
            ),
            const SizedBox(height: 8),
            const Text('亮度', style: TextStyle(fontWeight: FontWeight.w700)),
            Row(
              children: [
                const Icon(Icons.brightness_low_outlined, size: 18),
                Expanded(
                  child: Slider(
                    value: settings.brightness,
                    min: .35,
                    max: 1,
                    onChanged: (value) => controller.setSettings(
                      settings.copyWith(brightness: value),
                    ),
                  ),
                ),
                const Icon(Icons.brightness_high_outlined, size: 18),
              ],
            ),
            const SizedBox(height: 8),
            const Text('行距', style: TextStyle(fontWeight: FontWeight.w700)),
            Slider(
              value: settings.lineHeight,
              min: 1.45,
              max: 2.35,
              onChanged: (v) =>
                  controller.setSettings(settings.copyWith(lineHeight: v)),
            ),
            const SizedBox(height: 8),
            const Text('主题', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            Row(
              children: ReaderTheme.values
                  .map(
                    (theme) => Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: _ThemeChoice(
                          theme: theme,
                          selected: theme == settings.theme,
                          onTap: () => controller.setSettings(
                            settings.copyWith(theme: theme),
                          ),
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }
}

class _ThemeChoice extends StatelessWidget {
  const _ThemeChoice({
    required this.theme,
    required this.selected,
    required this.onTap,
  });
  final ReaderTheme theme;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final (label, color, foreground) = switch (theme) {
      ReaderTheme.light => ('日间', AppColors.paper, AppColors.ink),
      ReaderTheme.dark => (
        '夜间',
        const Color(0xFF1B1A17),
        const Color(0xFFD8D0BE),
      ),
      ReaderTheme.eye => ('护眼', AppColors.eye, AppColors.eyeInk),
    };
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? AppColors.seal : Colors.transparent,
            width: 2,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(color: foreground, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}

Future<String?> _requestNote(BuildContext context) async {
  final controller = TextEditingController();
  final result = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('添加笔记'),
      content: TextField(
        controller: controller,
        autofocus: true,
        minLines: 2,
        maxLines: 5,
        decoration: const InputDecoration(hintText: '写下此刻的想法…'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final value = controller.text.trim();
            if (value.isNotEmpty) Navigator.pop(dialogContext, value);
          },
          child: const Text('保存'),
        ),
      ],
    ),
  );
  controller.dispose();
  return result;
}

class PdfReaderPage extends ConsumerStatefulWidget {
  const PdfReaderPage({required this.book, super.key});
  final Book book;

  @override
  ConsumerState<PdfReaderPage> createState() => _PdfReaderPageState();
}

class _PdfReaderPageState extends ConsumerState<PdfReaderPage> {
  int _pageCount = 1;
  final PdfViewerController _pdfController = PdfViewerController();
  StreamSubscription? _playbackSubscription;
  StreamSubscription? _eventSubscription;
  bool _playing = false;
  int? _spokenPage;
  int? _lastFollowedPage;
  int _spokenStart = 0;
  int _spokenEnd = 0;

  Book get book => widget.book;

  @override
  void initState() {
    super.initState();
    if (ttsAudioHandler.currentBookId == book.id) {
      _playing = ttsAudioHandler.playbackState.value.playing;
      _spokenPage = ttsAudioHandler.currentChapter;
      _spokenStart = _spokenEnd = ttsAudioHandler.characterOffset;
    }
    _playbackSubscription = ttsAudioHandler.playbackState.listen((state) {
      if (!mounted) return;
      setState(() => _playing = state.playing);
      if (state.playing) _followSpokenPage();
    });
    _eventSubscription = ttsAudioHandler.customEvent.listen(_handleAudioEvent);
  }

  @override
  void dispose() {
    _playbackSubscription?.cancel();
    _eventSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(book.title),
      actions: [
        IconButton(
          tooltip: '听书',
          onPressed: () {
            if (book.chapters.isNotEmpty) {
              context.push('/player/${book.id}');
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('此 PDF 未提取到文本；扫描版 PDF 暂不支持听书。')),
              );
            }
          },
          icon: const Icon(Icons.headphones_outlined),
        ),
      ],
    ),
    body: book.filePath == null
        ? const Center(child: Text('PDF 文件路径不可用'))
        : LayoutBuilder(
            builder: (context, constraints) {
              final form = formFactorOf(constraints.maxWidth);
              final viewer = _buildPdfViewer(book);
              if (!form.hasSidebar) return viewer;
              // PDF 侧栏只提供页码导航；固定版式不套用重排阅读器的字号/行距，
              // 也不强行拼页——是否对开由 PDFium 的实际页面尺寸决定。
              return Row(
                children: [
                  SizedBox(width: 220, child: _buildPageList()),
                  const VerticalDivider(width: 1, thickness: 1),
                  Expanded(child: viewer),
                ],
              );
            },
          ),
  );

  Widget _buildPageList() => ListView.builder(
    itemCount: _pageCount,
    itemBuilder: (_, index) {
      final hasText =
          index < book.chapters.length &&
          book.chapters[index].content.trim().isNotEmpty;
      return ListTile(
        dense: true,
        selected: _spokenPage == index,
        selectedColor: AppColors.seal,
        leading: Text('${index + 1}'),
        title: Text(
          hasText ? '第 ${index + 1} 页' : '第 ${index + 1} 页（无文本）',
          style: TextStyle(
            fontSize: 12.5,
            color: hasText ? null : AppColors.graphite,
          ),
        ),
        onTap: () => unawaited(_pdfController.goToPage(pageNumber: index + 1)),
      );
    },
  );

  Widget _buildPdfViewer(Book book) => Stack(
    children: [
      PdfViewer.file(
        book.filePath!,
        controller: _pdfController,
        initialPageNumber: book.chapterIndex + 1,
        params: PdfViewerParams(
          onViewerReady: (document, _) {
            if (mounted) {
              setState(() => _pageCount = document.pages.length);
              _lastFollowedPage = null;
              _followSpokenPage();
            }
          },
          onPageChanged: (pageNumber) {
            if (pageNumber == null) return;
            ref
                .read(appControllerProvider.notifier)
                .updateProgress(
                  book.id,
                  pageNumber - 1,
                  (pageNumber / _pageCount).clamp(0, 1),
                );
          },
        ),
      ),
      Positioned(
        left: 14,
        right: 14,
        bottom: 14,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                const Icon(Icons.info_outline, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _playing && _spokenPage != null
                        ? _spokenPreview()
                        : 'PDF 为固定版式：支持缩放与翻页，不提供字号和行距调整。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ],
  );

  void _handleAudioEvent(dynamic event) {
    if (!mounted || event is! Map || event['bookId'] != book.id) return;
    if (!{'progress', 'chapter'}.contains(event['type'])) return;
    setState(() {
      _spokenPage = (event['chapter'] as int? ?? _spokenPage ?? 0).clamp(
        0,
        book.chapters.length - 1,
      );
      _spokenStart = event['start'] as int? ?? _spokenStart;
      _spokenEnd = event['end'] as int? ?? _spokenEnd;
    });
    _followSpokenPage();
  }

  void _followSpokenPage() {
    if (!_playing || _spokenPage == null || !_pdfController.isReady) return;
    if (_lastFollowedPage == _spokenPage) return;
    _lastFollowedPage = _spokenPage;
    unawaited(
      _pdfController.goToPage(
        pageNumber: _spokenPage! + 1,
        duration: const Duration(milliseconds: 360),
      ),
    );
  }

  String _spokenPreview() {
    final page = _spokenPage;
    if (page == null || page < 0 || page >= book.chapters.length) {
      return '自动跟读';
    }
    final text = book.chapters[page].content;
    if (text.isEmpty) return '自动跟读 · 第 ${page + 1} 页';
    final center = _spokenEnd.clamp(0, text.length);
    final start = (center - 18).clamp(0, text.length);
    final end = (center + 36).clamp(start, text.length);
    final excerpt = text.substring(start, end).replaceAll('\n', ' ');
    return '自动跟读 · 第 ${page + 1} 页\n$excerpt';
  }
}
