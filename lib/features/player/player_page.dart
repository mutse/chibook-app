import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_state.dart';
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
  Timer? _sleepTimer;
  String? _timerLabel;

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
    Future.microtask(() async {
      final book = _book;
      if (book == null || book.chapters.isEmpty) return;
      _chapter = book.chapterIndex.clamp(0, book.chapters.length - 1);
      ref.read(appControllerProvider.notifier).setActiveAudio(book.id);
      await ttsAudioHandler.loadBook(book, chapterIndex: _chapter);
      _playbackSubscription = ttsAudioHandler.playbackState.listen((value) {
        if (mounted) setState(() => _playing = value.playing);
      });
      _eventSubscription = ttsAudioHandler.customEvent.listen((event) {
        if (!mounted || event is! Map) return;
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
            _start = 0;
            _end = 0;
          });
          ref
              .read(appControllerProvider.notifier)
              .updateProgress(book.id, next, (next + 1) / book.chapters.length);
        }
      });
    });
  }

  @override
  void dispose() {
    _sleepTimer?.cancel();
    _playbackSubscription?.cancel();
    _eventSubscription?.cancel();
    _wave.dispose();
    super.dispose();
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
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 6, 24, 16),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    onPressed: () => context.pop(),
                    icon: const Icon(
                      Icons.keyboard_arrow_down,
                      color: Color(0xFFEDE7D8),
                    ),
                  ),
                  const Text(
                    '正在收听',
                    style: TextStyle(
                      color: Color(0xFFEDE7D8),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  IconButton(
                    onPressed: () {},
                    icon: const Icon(
                      Icons.more_horiz,
                      color: Color(0xFFEDE7D8),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _PlayerCover(book: book),
              const SizedBox(height: 22),
              Text(
                book.title,
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
              const SizedBox(height: 24),
              SizedBox(
                height: 70,
                child: SingleChildScrollView(
                  child: _SpokenText(
                    text: chapter.content,
                    start: _start,
                    end: _end,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              AnimatedBuilder(
                animation: _wave,
                builder: (_, _) => _Waveform(value: _playing ? _wave.value : 0),
              ),
              const Spacer(),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: const Color(0xFFF2C9A0),
                  inactiveTrackColor: Colors.white12,
                  thumbColor: const Color(0xFFF2C9A0),
                ),
                child: Slider(value: progress, onChanged: (_) {}),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${(progress * 100).round()}%',
                    style: const TextStyle(
                      color: Color(0xFF9B9184),
                      fontSize: 10,
                    ),
                  ),
                  Text(
                    '${_chapter + 1} / ${book.chapters.length}',
                    style: const TextStyle(
                      color: Color(0xFF9B9184),
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
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
                    onPressed: () {},
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
                    onPressed: () {},
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
              ),
              const SizedBox(height: 17),
              Wrap(
                spacing: 8,
                children: [.5, 1.0, 1.5, 2.0]
                    .map(
                      (speed) => ChoiceChip(
                        label: Text('${speed}x'),
                        selected: _speed == speed,
                        onSelected: (_) {
                          setState(() => _speed = speed);
                          ttsAudioHandler.setSpeed(speed);
                        },
                        selectedColor: const Color(0xFFF2C9A0),
                        backgroundColor: Colors.transparent,
                        labelStyle: TextStyle(
                          color: _speed == speed
                              ? AppColors.ink
                              : const Color(0xFFD8D0BE),
                        ),
                        side: const BorderSide(color: Colors.white24),
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 17),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  const _PlayerUtility(icon: Icons.mic_none, label: '发音人'),
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
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showTimer() async {
    final minutes = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: const Color(0xFF1E1C19),
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [15, 30, 60]
              .map(
                (m) => ListTile(
                  title: Text(
                    '$m 分钟',
                    style: const TextStyle(color: Color(0xFFD8D0BE)),
                  ),
                  onTap: () => Navigator.pop(context, m),
                ),
              )
              .toList(),
        ),
      ),
    );
    if (minutes == null) return;
    _sleepTimer?.cancel();
    _sleepTimer = Timer(Duration(minutes: minutes), () {
      unawaited(ttsAudioHandler.stop());
      if (mounted) setState(() => _playing = false);
    });
    setState(() => _timerLabel = '$minutes 分钟');
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
