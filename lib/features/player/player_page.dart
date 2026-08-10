import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_state.dart';
import '../../core/adaptive.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import '../../services/tts_audio_handler.dart';

class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({required this.bookId, super.key});
  final String bookId;

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _wave;
  StreamSubscription? _playbackSubscription;
  StreamSubscription? _eventSubscription;
  bool _playing = false;
  double _speed = 1;
  int _chapter = 0;
  int _start = 0;
  int _end = 0;
  PlaybackMode _mode = PlaybackMode.sequential;
  String? _timerLabel;
  bool _wasImmersive = false;

  Book? get _book {
    final matches = ref
        .read(appControllerProvider)
        .books
        .where((e) => e.id == widget.bookId);
    return matches.isEmpty ? null : matches.first;
  }

  @override
  void initState() {
    super.initState();
    _wave = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _enterImmersive();
    _timerLabel = _sleepLabelFromHandler();
    Future.microtask(() async {
      final book = _book;
      if (book == null || book.chapters.isEmpty) return;
      final controller = ref.read(appControllerProvider.notifier);
      final saved = controller.audioProgressFor(book.id);
      _chapter = (saved?.chapterIndex ?? book.chapterIndex).clamp(
        0,
        book.chapters.length - 1,
      );
      _start = _end =
          saved?.characterOffset.clamp(
            0,
            book.chapters[_chapter].content.length,
          ) ??
          0;
      _speed =
          saved?.speed ?? ref.read(appControllerProvider).ttsSettings.speed;
      _mode = saved?.mode ?? PlaybackMode.sequential;
      ref.read(appControllerProvider.notifier).setActiveAudio(book.id);
      _playbackSubscription = ttsAudioHandler.playbackState.listen((value) {
        if (mounted) setState(() => _playing = value.playing);
      });
      _eventSubscription = ttsAudioHandler.customEvent.listen((event) {
        if (!mounted || event is! Map || event['bookId'] != book.id) return;
        if (event['type'] == 'progress') {
          setState(() {
            _start = event['start'] as int? ?? 0;
            _end = event['end'] as int? ?? 0;
          });
        }
        if (event['type'] == 'chapter') {
          final next = event['chapter'] as int? ?? _chapter;
          setState(() {
            _chapter = next;
            _start = event['start'] as int? ?? 0;
            _end = event['end'] as int? ?? _start;
          });
        }
        if (event['type'] == 'sleepComplete') {
          setState(() => _timerLabel = null);
        }
        if (event['type'] == 'sleep') {
          setState(() => _timerLabel = _sleepLabelFromHandler());
        }
        if (event['type'] == 'mode') {
          setState(() {
            _mode = PlaybackMode.values.byName(event['mode'] as String);
          });
        }
        if (event['type'] == 'error') {
          final message = event['message']?.toString() ?? '播放失败';
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(message)));
        }
      });
      if (ttsAudioHandler.currentBookId != book.id) {
        await ttsAudioHandler.loadBook(
          book,
          chapterIndex: _chapter,
          characterOffset: _end,
          mode: _mode,
        );
        await ttsAudioHandler.applySettings(
          ref.read(appControllerProvider).ttsSettings.copyWith(speed: _speed),
        );
      } else {
        setState(() {
          _chapter = ttsAudioHandler.currentChapter;
          _start = _end = ttsAudioHandler.characterOffset;
          _speed = ttsAudioHandler.speed;
          _mode = ttsAudioHandler.mode;
          _playing = ttsAudioHandler.playbackState.value.playing;
        });
      }
    });
  }

  @override
  void dispose() {
    _restoreSystemUi();
    _playbackSubscription?.cancel();
    _eventSubscription?.cancel();
    final book = _book;
    if (book != null) {
      unawaited(
        ref
            .read(appControllerProvider.notifier)
            .saveAudioPosition(
              bookId: book.id,
              chapterIndex: _chapter,
              characterOffset: _end,
              speed: _speed,
              mode: _mode,
            ),
      );
    }
    _wave.dispose();
    super.dispose();
  }

  /// 进入沉浸模式：隐藏状态栏与导航栏。
  ///
  /// 播放页需要全屏专注；必须成对恢复（见 [_restoreSystemUi]）。
  Future<void> _enterImmersive() async {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
    );
    _wasImmersive = true;
  }

  /// 恢复系统栏。必须在 dispose 调用，覆盖返回手势、跳转阅读、页面回收等
  /// 所有退出路径，否则系统栏会一直停留在隐藏状态。
  Future<void> _restoreSystemUi() async {
    if (!_wasImmersive) return;
    _wasImmersive = false;
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  /// 定时关闭状态由 handler 持有，重建页面时据此恢复标签显示。
  String? _sleepLabelFromHandler() {
    if (ttsAudioHandler.stopsAfterCurrentChapter) return '本章结束';
    final deadline = ttsAudioHandler.sleepDeadline;
    if (deadline == null) return null;
    final minutes = deadline.difference(DateTime.now()).inMinutes;
    if (minutes <= 0) return null;
    return '$minutes 分钟';
  }

  Future<void> _speak() async {
    final book = _book;
    if (book == null || book.chapters.isEmpty) return;
    if (_playing) {
      await ttsAudioHandler.pause();
      return;
    }
    await ttsAudioHandler.play();
  }

  Future<void> _changeChapter(int delta) async {
    final book = _book;
    if (book == null) return;
    if (delta > 0) {
      await ttsAudioHandler.skipToNext();
    } else {
      await ttsAudioHandler.skipToPrevious();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appControllerProvider);
    final matches = state.books.where((e) => e.id == widget.bookId);
    if (matches.isEmpty) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final book = matches.first;
    if (book.chapters.isEmpty) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('此 PDF 暂无可用于 TTS 的文本')),
      );
    }
    final chapter = book.chapters[_chapter.clamp(0, book.chapters.length - 1)];
    final progress = chapter.content.isEmpty
        ? 0.0
        : (_end / chapter.content.length).clamp(0.0, 1.0);
    return Scaffold(
      backgroundColor: const Color(0xFF121110),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 横屏与大屏走左右分栏：原纵向布局用 Spacer 撑开，在矮而宽的
            // 窗口里必定溢出。
            final wide =
                constraints.maxWidth >= 600 && constraints.maxHeight < 640;
            final form = formFactorOf(constraints.maxWidth);
            final split = wide || form == FormFactor.expanded;
            return Padding(
              padding: const EdgeInsets.fromLTRB(24, 6, 24, 16),
              child: split
                  ? _buildSplit(book, chapter, progress, state)
                  : _buildStacked(book, chapter, progress, state),
            );
          },
        ),
      ),
    );
  }

  /// compact 竖屏：保持原有的纵向沉浸布局。
  Widget _buildStacked(
    Book book,
    Chapter chapter,
    double progress,
    AppState state,
  ) => Column(
    children: [
      _header(book),
      const SizedBox(height: 14),
      _PlayerCover(book: book),
      const SizedBox(height: 22),
      _titles(book, chapter),
      const SizedBox(height: 24),
      SizedBox(
        height: 70,
        child: SingleChildScrollView(
          child: _SpokenText(text: chapter.content, start: _start, end: _end),
        ),
      ),
      const SizedBox(height: 10),
      AnimatedBuilder(
        animation: _wave,
        builder: (_, _) => _Waveform(value: _playing ? _wave.value : 0),
      ),
      const Spacer(),
      _progressBar(chapter, progress),
      _progressLabels(book, progress),
      const SizedBox(height: 14),
      _transportControls(),
      const SizedBox(height: 17),
      _speedChips(book),
      const SizedBox(height: 17),
      _utilities(book, state),
    ],
  );

  /// 横屏 / 大屏：左列封面与控件，右列朗读文本跟随。
  Widget _buildSplit(
    Book book,
    Chapter chapter,
    double progress,
    AppState state,
  ) => Column(
    children: [
      _header(book),
      const SizedBox(height: 8),
      Expanded(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _PlayerCover(book: book),
                    const SizedBox(height: 18),
                    _titles(book, chapter),
                    const SizedBox(height: 12),
                    _progressBar(chapter, progress),
                    _progressLabels(book, progress),
                    const SizedBox(height: 10),
                    _transportControls(),
                    const SizedBox(height: 14),
                    _speedChips(book),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 24),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AnimatedBuilder(
                    animation: _wave,
                    builder: (_, _) =>
                        _Waveform(value: _playing ? _wave.value : 0),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: SingleChildScrollView(
                      child: _SpokenText(
                        text: chapter.content,
                        start: _start,
                        end: _end,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  _utilities(book, state),
                ],
              ),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _header(Book book) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      IconButton(
        onPressed: () => context.pop(),
        icon: const Icon(Icons.keyboard_arrow_down, color: Color(0xFFEDE7D8)),
      ),
      const Text(
        '正在收听',
        style: TextStyle(color: Color(0xFFEDE7D8), fontWeight: FontWeight.w700),
      ),
      IconButton(
        tooltip: '章节与播放顺序',
        onPressed: () => _showQueue(book),
        icon: const Icon(Icons.more_horiz, color: Color(0xFFEDE7D8)),
      ),
    ],
  );

  Widget _titles(Book book, Chapter chapter) => Column(
    children: [
      Text(
        book.title,
        textAlign: TextAlign.center,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Color(0xFFEDE7D8),
          fontSize: 22,
          fontWeight: FontWeight.w800,
        ),
      ),
      const SizedBox(height: 5),
      Text(
        chapter.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Color(0xFFB9B0A0), fontSize: 12),
      ),
    ],
  );

  Widget _progressBar(Chapter chapter, double progress) => SliderTheme(
    data: SliderTheme.of(context).copyWith(
      activeTrackColor: const Color(0xFFF2C9A0),
      inactiveTrackColor: Colors.white12,
      thumbColor: const Color(0xFFF2C9A0),
    ),
    child: Slider(
      value: progress,
      onChanged: (value) {
        final offset = (chapter.content.length * value).round();
        setState(() {
          _start = offset;
          _end = offset;
        });
      },
      onChangeEnd: (value) => ttsAudioHandler.seekToCharacter(
        (chapter.content.length * value).round(),
      ),
    ),
  );

  Widget _progressLabels(Book book, double progress) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      Text(
        '${(progress * 100).round()}%',
        style: const TextStyle(color: Color(0xFF9B9184), fontSize: 10),
      ),
      Text(
        '${_chapter + 1} / ${book.chapters.length}',
        style: const TextStyle(color: Color(0xFF9B9184), fontSize: 10),
      ),
    ],
  );

  Widget _transportControls() => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      IconButton(
        onPressed: () => _changeChapter(-1),
        icon: const Icon(
          Icons.skip_previous_rounded,
          color: Color(0xFFEDE7D8),
          size: 30,
        ),
      ),
      IconButton(
        tooltip: '后退约 15 秒',
        onPressed: () => ttsAudioHandler.seekBySeconds(-15),
        icon: const Icon(
          Icons.replay_10_rounded,
          color: Color(0xFFEDE7D8),
          size: 28,
        ),
      ),
      IconButton.filled(
        onPressed: _speak,
        style: IconButton.styleFrom(
          backgroundColor: const Color(0xFFEDE7D8),
          foregroundColor: AppColors.ink,
          fixedSize: const Size(66, 66),
        ),
        icon: Icon(
          _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
          size: 34,
        ),
      ),
      IconButton(
        tooltip: '前进约 15 秒',
        onPressed: () => ttsAudioHandler.seekBySeconds(15),
        icon: const Icon(
          Icons.forward_10_rounded,
          color: Color(0xFFEDE7D8),
          size: 28,
        ),
      ),
      IconButton(
        onPressed: () => _changeChapter(1),
        icon: const Icon(
          Icons.skip_next_rounded,
          color: Color(0xFFEDE7D8),
          size: 30,
        ),
      ),
    ],
  );

  Widget _speedChips(Book book) => Wrap(
    spacing: 8,
    alignment: WrapAlignment.center,
    children: [.5, 1.0, 1.5, 2.0]
        .map(
          (speed) => ChoiceChip(
            label: Text('${speed}x'),
            selected: _speed == speed,
            onSelected: (_) {
              setState(() => _speed = speed);
              ttsAudioHandler.setSpeed(speed);
              ref
                  .read(appControllerProvider.notifier)
                  .saveAudioPosition(
                    bookId: book.id,
                    chapterIndex: _chapter,
                    characterOffset: _end,
                    speed: speed,
                    mode: _mode,
                  );
            },
            selectedColor: const Color(0xFFF2C9A0),
            backgroundColor: Colors.transparent,
            labelStyle: TextStyle(
              color: _speed == speed ? AppColors.ink : const Color(0xFFD8D0BE),
            ),
            side: const BorderSide(color: Colors.white24),
          ),
        )
        .toList(),
  );

  Widget _utilities(Book book, AppState state) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceAround,
    children: [
      _PlayerUtility(
        icon: Icons.mic_none,
        label: state.ttsSettings.voiceName,
        onTap: () => context.push('/settings/tts'),
      ),
      _PlayerUtility(
        icon: Icons.timer_outlined,
        label: _timerLabel ?? '定时关闭',
        onTap: _showTimer,
      ),
      _PlayerUtility(
        icon: Icons.subject,
        label: '切回阅读',
        onTap: () => context.pushReplacement('/reader/${book.id}'),
      ),
    ],
  );

  Future<void> _showTimer() async {
    final choice = await showAdaptiveSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF1E1C19),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text(
                '播完本章',
                style: TextStyle(color: Color(0xFFD8D0BE)),
              ),
              onTap: () => Navigator.pop(context, 'chapter'),
            ),
            ...[15, 30, 60].map(
              (m) => ListTile(
                title: Text(
                  '$m 分钟',
                  style: const TextStyle(color: Color(0xFFD8D0BE)),
                ),
                onTap: () => Navigator.pop(context, '$m'),
              ),
            ),
            if (_timerLabel != null)
              ListTile(
                title: const Text(
                  '取消定时',
                  style: TextStyle(color: AppColors.seal),
                ),
                onTap: () => Navigator.pop(context, 'cancel'),
              ),
          ],
        ),
      ),
    );
    if (choice == null) return;
    // 定时状态交给 handler 持有：离开播放页不再静默取消倒计时，
    // 重新进入时也能通过 handler 恢复标签。
    if (choice == 'cancel') {
      ttsAudioHandler.stopAfterCurrentChapter(false);
      ttsAudioHandler.setSleepTimer(null);
    } else if (choice == 'chapter') {
      ttsAudioHandler.stopAfterCurrentChapter(true);
    } else {
      ttsAudioHandler.setSleepTimer(int.parse(choice));
    }
    setState(() => _timerLabel = _sleepLabelFromHandler());
  }

  Future<void> _showQueue(Book book) async {
    await showAdaptiveSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1E1C19),
      scrollable: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '章节列表',
                          style: TextStyle(
                            color: Color(0xFFEDE7D8),
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      DropdownButton<PlaybackMode>(
                        value: _mode,
                        dropdownColor: const Color(0xFF26231F),
                        style: const TextStyle(color: Color(0xFFEDE7D8)),
                        items: PlaybackMode.values
                            .map(
                              (mode) => DropdownMenuItem(
                                value: mode,
                                child: Text(switch (mode) {
                                  PlaybackMode.sequential => '顺序播放',
                                  PlaybackMode.reverse => '倒序播放',
                                  PlaybackMode.repeatOne => '单章循环',
                                }),
                              ),
                            )
                            .toList(),
                        onChanged: (mode) {
                          if (mode == null) return;
                          setState(() => _mode = mode);
                          setSheetState(() {});
                          ttsAudioHandler.setPlaybackMode(mode);
                        },
                      ),
                    ],
                  ),
                ),
                const Divider(color: Colors.white12, height: 1),
                Expanded(
                  child: ListView.builder(
                    itemCount: book.chapters.length,
                    itemBuilder: (_, index) => ListTile(
                      selected: index == _chapter,
                      selectedTileColor: Colors.white10,
                      leading: Text(
                        '${index + 1}'.padLeft(2, '0'),
                        style: TextStyle(
                          color: index == _chapter
                              ? const Color(0xFFF2C9A0)
                              : const Color(0xFF9B9184),
                        ),
                      ),
                      title: Text(
                        book.chapters[index].title,
                        style: TextStyle(
                          color: index == _chapter
                              ? const Color(0xFFF2C9A0)
                              : const Color(0xFFD8D0BE),
                        ),
                      ),
                      onTap: () async {
                        Navigator.pop(context);
                        await ttsAudioHandler.playChapter(index);
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PlayerCover extends StatelessWidget {
  const _PlayerCover({required this.book});
  final Book book;
  @override
  Widget build(BuildContext context) => Container(
    width: 190,
    height: 190,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(18),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(book.coverColor), const Color(0xFF1C1A16)],
      ),
      boxShadow: const [
        BoxShadow(color: Colors.black54, blurRadius: 28, offset: Offset(0, 16)),
      ],
      border: Border.all(color: Colors.white12),
    ),
    child: Container(
      width: 66,
      height: 66,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        color: AppColors.seal,
        shape: BoxShape.circle,
      ),
      child: Text(
        book.title.characters.first,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 29,
          fontWeight: FontWeight.w800,
        ),
      ),
    ),
  );
}

class _SpokenText extends StatelessWidget {
  const _SpokenText({
    required this.text,
    required this.start,
    required this.end,
  });
  final String text;
  final int start;
  final int end;
  @override
  Widget build(BuildContext context) {
    final safeStart = start.clamp(0, text.length);
    final safeEnd = end.clamp(safeStart, text.length);
    return Text.rich(
      TextSpan(
        style: const TextStyle(
          color: Color(0xFFD8D0BE),
          height: 1.8,
          fontSize: 14,
        ),
        children: [
          TextSpan(text: text.substring(0, safeStart)),
          TextSpan(
            text: text.substring(safeStart, safeEnd),
            style: const TextStyle(
              color: Color(0xFFF2C9A0),
              fontWeight: FontWeight.w800,
            ),
          ),
          TextSpan(text: text.substring(safeEnd)),
        ],
      ),
      textAlign: TextAlign.center,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _Waveform extends StatelessWidget {
  const _Waveform({required this.value});
  final double value;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 28,
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: List.generate(13, (i) {
        final phase = ((i * 37) % 10) / 10;
        final height = 5 + 22 * (value == 0 ? 0 : (phase - value).abs());
        return Container(
          width: 3,
          height: height.clamp(5, 26).toDouble(),
          margin: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(2),
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFFF2C9A0), AppColors.seal],
            ),
          ),
        );
      }),
    ),
  );
}

class _PlayerUtility extends StatelessWidget {
  const _PlayerUtility({required this.icon, required this.label, this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        children: [
          Icon(icon, color: const Color(0xFFB9B0A0), size: 21),
          const SizedBox(height: 5),
          Text(
            label,
            style: const TextStyle(color: Color(0xFFB9B0A0), fontSize: 10),
          ),
        ],
      ),
    ),
  );
}
