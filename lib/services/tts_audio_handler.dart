import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:just_audio/just_audio.dart' as ja;

import '../core/models.dart';
import '../core/reading_follow.dart';
import 'cloud_tts_service.dart';

late final TtsAudioHandler ttsAudioHandler;

Future<void> initializeAudioService() async {
  ttsAudioHandler = await AudioService.init<TtsAudioHandler>(
    builder: TtsAudioHandler.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.chibook.erdu.tts',
      androidNotificationChannelName: 'chibook 听书',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
    ),
  );
}

class TtsAudioHandler extends BaseAudioHandler with SeekHandler {
  TtsAudioHandler() {
    _initialize();
  }

  final FlutterTts _tts = FlutterTts();
  final ja.AudioPlayer _cloudPlayer = ja.AudioPlayer(handleInterruptions: true);
  final CloudTtsService _cloudTts = CloudTtsService();
  Book? _book;
  int _chapter = 0;
  double _speed = 1;
  int _characterOffset = 0;
  int _speechStartOffset = 0;
  bool _stopAfterCurrentChapter = false;
  PlaybackMode _mode = PlaybackMode.sequential;
  TtsSettings _settings = const TtsSettings();
  TextChunk? _activeChunk;
  int _operation = 0;
  bool _handlingCloudCompletion = false;
  Timer? _sleepTimer;
  DateTime? _sleepDeadline;
  bool _interruptedByFocus = false;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSubscription;
  StreamSubscription<void>? _noisySubscription;

  String? get currentBookId => _book?.id;
  int get currentChapter => _chapter;
  int get characterOffset => _characterOffset;
  double get speed => _speed;
  PlaybackMode get mode => _mode;
  bool get isCloud =>
      _settings.provider == TtsProvider.openai ||
      _settings.provider == TtsProvider.azure;

  /// 定时关闭状态由 handler 持有，页面重建后可据此恢复标签显示。
  bool get stopsAfterCurrentChapter => _stopAfterCurrentChapter;
  DateTime? get sleepDeadline => _sleepDeadline;

  Future<void> _initialize() async {
    await _tts.setLanguage('zh-CN');
    await _tts.awaitSpeakCompletion(true);
    await _tts.setSharedInstance(true);
    await _tts.setIosAudioCategory(
      IosTextToSpeechAudioCategory.playback,
      const [IosTextToSpeechAudioCategoryOptions.duckOthers],
      IosTextToSpeechAudioMode.spokenAudio,
    );
    _tts.setStartHandler(() => _publish(playing: true));
    _tts.setPauseHandler(() => _publish(playing: false));
    _tts.setCancelHandler(() => _publish(playing: false));
    _tts.setErrorHandler((message) => _reportError(message));
    _tts.setProgressHandler((text, start, end, word) {
      final absoluteStart = _speechStartOffset + start;
      final absoluteEnd = _speechStartOffset + end;
      _characterOffset = absoluteEnd;
      _emitPosition(start: absoluteStart, end: absoluteEnd);
    });
    _tts.setCompletionHandler(_completeChapter);

    _cloudPlayer.positionStream.listen(_handleCloudPosition);
    _cloudPlayer.processingStateStream.listen((state) {
      if (state == ja.ProcessingState.completed) _completeCloudChunk();
    });
    _cloudPlayer.errorStream.listen(
      (error) => _reportError(error.message ?? '音频解码失败'),
    );
    _cloudPlayer.playerStateStream.listen((state) {
      if (isCloud) {
        _publish(
          playing: state.playing,
          state: switch (state.processingState) {
            ja.ProcessingState.loading ||
            ja.ProcessingState.buffering => AudioProcessingState.buffering,
            ja.ProcessingState.completed => AudioProcessingState.completed,
            ja.ProcessingState.idle => AudioProcessingState.idle,
            ja.ProcessingState.ready => AudioProcessingState.ready,
          },
        );
      }
    });
    await _configureAudioSession();
    _publish(playing: false);
  }

  /// 音频焦点、来电中断与拔耳机。
  ///
  /// `just_audio` 的 `handleInterruptions: true` 只覆盖云端 MP3 路径；
  /// builtin（`flutter_tts`）路径没有任何打断处理，因此这里统一订阅
  /// `audio_session` 的事件流，对两条引擎路径做同样的暂停/恢复决策。
  Future<void> _configureAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.speech());
      _interruptionSubscription = session.interruptionEventStream.listen(
        _handleInterruption,
      );
      // 拔耳机 / 蓝牙断开：立即暂停，不允许转外放继续朗读。
      _noisySubscription = session.becomingNoisyEventStream.listen((_) {
        if (playbackState.value.playing) unawaited(pause());
      });
    } catch (_) {
      // 平台不支持或配置失败时不影响正常播放，只是失去自动暂停能力。
    }
  }

  void _handleInterruption(AudioInterruptionEvent event) {
    if (event.begin) {
      switch (event.type) {
        case AudioInterruptionType.duck:
          // 已声明 spokenAudio + duckOthers，让系统压低其他音频而不暂停朗读；
          // 不自行降低音量，避免与系统 ducking 叠加。
          break;
        case AudioInterruptionType.pause:
        case AudioInterruptionType.unknown:
          if (playbackState.value.playing) {
            _interruptedByFocus = true;
            unawaited(_pauseEngines());
          }
      }
      return;
    }
    switch (event.type) {
      case AudioInterruptionType.duck:
        break;
      case AudioInterruptionType.pause:
        // 短暂中断（来电结束等）结束后恢复。
        if (_interruptedByFocus) {
          _interruptedByFocus = false;
          unawaited(play());
        }
      case AudioInterruptionType.unknown:
        // 焦点可能已被永久让出，保持暂停，由用户决定何时继续。
        _interruptedByFocus = false;
    }
  }

  Future<void> loadBook(
    Book book, {
    required int chapterIndex,
    int characterOffset = 0,
    PlaybackMode mode = PlaybackMode.sequential,
  }) async {
    _operation++;
    await _stopEngines();
    _book = book;
    _chapter = chapterIndex.clamp(0, book.chapters.length - 1);
    _characterOffset = characterOffset.clamp(
      0,
      book.chapters[_chapter].content.length,
    );
    _mode = mode;
    _activeChunk = null;
    _publishMediaItem();
    _publish(playing: false, state: AudioProcessingState.ready);
    _publishPosition(type: 'chapter');
  }

  @override
  Future<void> setSpeed(double speed) async {
    _speed = speed;
    await _tts.setSpeechRate((_speed * .5).clamp(.1, 1.0));
    await _cloudPlayer.setSpeed(_speed);
    if (playbackState.value.playing && !isCloud) {
      await _tts.stop();
      await _speakCurrent();
    } else {
      _publishPosition(type: 'progress');
    }
  }

  Future<void> applySettings(TtsSettings settings) async {
    final wasPlaying = playbackState.value.playing;
    final changedEngine = settings.provider != _settings.provider;
    final changedCloudVoice =
        (settings.provider == TtsProvider.openai ||
            settings.provider == TtsProvider.azure) &&
        (settings.voiceName != _settings.voiceName ||
            settings.endpoint != _settings.endpoint);
    _settings = settings;
    _publishMediaItem();
    if (changedEngine || changedCloudVoice) {
      _operation++;
      await _stopEngines();
      _activeChunk = null;
    }
    if (settings.provider == TtsProvider.builtin) {
      final voiceParts = settings.systemVoiceId?.split('|');
      if (voiceParts != null && voiceParts.length == 2) {
        try {
          await _tts.setVoice({
            'name': voiceParts.first,
            'locale': voiceParts.last,
          });
        } catch (_) {
          await _tts.setLanguage('zh-CN');
        }
      }
      await _tts.setPitch(switch (settings.voiceName) {
        '温润男声' => .85,
        '清亮少年音' => 1.18,
        _ => 1.02,
      });
    }
    await setSpeed(settings.speed);
    if (wasPlaying && (changedEngine || changedCloudVoice)) {
      await _speakCurrent();
    }
  }

  void stopAfterCurrentChapter(bool enabled) {
    _stopAfterCurrentChapter = enabled;
    if (enabled) _cancelSleepTimer();
    _emitSleepState();
  }

  /// 定时关闭。[minutes] 为 null 表示取消倒计时。
  void setSleepTimer(int? minutes) {
    _cancelSleepTimer();
    if (minutes == null) {
      _stopAfterCurrentChapter = false;
      _emitSleepState();
      return;
    }
    _stopAfterCurrentChapter = false;
    _sleepDeadline = DateTime.now().add(Duration(minutes: minutes));
    _sleepTimer = Timer(Duration(minutes: minutes), () {
      _sleepTimer = null;
      _sleepDeadline = null;
      unawaited(stop());
      customEvent.add({
        'type': 'sleepComplete',
        'bookId': _book?.id,
        'chapter': _chapter,
      });
    });
    _emitSleepState();
  }

  void _cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepDeadline = null;
  }

  void _emitSleepState() {
    customEvent.add({
      'type': 'sleep',
      'bookId': _book?.id,
      'chapter': _chapter,
      'stopAfterChapter': _stopAfterCurrentChapter,
      'deadline': _sleepDeadline?.toIso8601String(),
    });
  }

  void setPlaybackMode(PlaybackMode mode) {
    _mode = mode;
    _publishPosition(type: 'mode');
  }

  @override
  Future<void> play() => _speakCurrent();

  @override
  Future<void> pause() async {
    // 用户主动暂停：清除中断标记，避免之后焦点恢复时被误判为需要自动续播。
    _interruptedByFocus = false;
    await _pauseEngines();
  }

  Future<void> _pauseEngines() async {
    if (isCloud) {
      if (_activeChunk == null && playbackState.value.playing) {
        _operation++;
      }
      await _cloudPlayer.pause();
    } else {
      await _tts.pause();
    }
    _publish(playing: false);
    _publishPosition(type: 'progress');
  }

  @override
  Future<void> stop() async {
    _operation++;
    _stopAfterCurrentChapter = false;
    _cancelSleepTimer();
    _interruptedByFocus = false;
    await _stopEngines();
    _publish(playing: false, state: AudioProcessingState.idle);
  }

  Future<void> _stopEngines() async {
    await Future.wait([_tts.stop(), _cloudPlayer.stop()]);
  }

  Future<void> unloadBook(String bookId) async {
    if (_book?.id != bookId) return;
    await stop();
    _book = null;
    _chapter = 0;
    _characterOffset = 0;
    _activeChunk = null;
    mediaItem.add(null);
  }

  @override
  Future<void> skipToNext() => _moveChapter(1);

  @override
  Future<void> skipToPrevious() => _moveChapter(-1);

  Future<void> seekByCharacters(int delta) async {
    final book = _book;
    if (book == null || book.chapters.isEmpty) return;
    final length = book.chapters[_chapter].content.length;
    await seekToCharacter((_characterOffset + delta).clamp(0, length));
  }

  Future<void> seekBySeconds(int seconds) {
    if (isCloud && _activeChunk != null && _cloudPlayer.duration != null) {
      final target = _cloudPlayer.position + Duration(seconds: seconds);
      final duration = _cloudPlayer.duration!;
      return _cloudPlayer.seek(
        Duration(
          microseconds: target.inMicroseconds.clamp(0, duration.inMicroseconds),
        ),
      );
    }
    final estimatedCharactersPerSecond = 7.0 * _speed;
    return seekByCharacters((seconds * estimatedCharactersPerSecond).round());
  }

  Future<void> playChapter(int chapterIndex) async {
    final book = _book;
    if (book == null || book.chapters.isEmpty) return;
    _operation++;
    await _stopEngines();
    _chapter = chapterIndex.clamp(0, book.chapters.length - 1);
    _characterOffset = 0;
    _activeChunk = null;
    _publishMediaItem();
    _publishPosition(type: 'chapter');
    await _speakCurrent();
  }

  Future<void> seekToCharacter(int offset) async {
    final book = _book;
    if (book == null || book.chapters.isEmpty) return;
    final length = book.chapters[_chapter].content.length;
    _characterOffset = offset.clamp(0, length);
    _operation++;
    await _stopEngines();
    _activeChunk = null;
    _publishPosition(type: 'progress');
    await _speakCurrent();
  }

  Future<void> _moveChapter(int delta) async {
    final book = _book;
    if (book == null || book.chapters.isEmpty) return;
    final nextChapter = nextReadableChapterIndex(
      book.chapters,
      currentIndex: _chapter,
      direction: delta,
    );
    if (nextChapter == null) return;
    _operation++;
    await _stopEngines();
    _chapter = nextChapter;
    _characterOffset = 0;
    _activeChunk = null;
    _publishMediaItem();
    _publishPosition(type: 'chapter');
    await _speakCurrent();
  }

  Future<void> _speakCurrent() async {
    final book = _book;
    if (book == null || book.chapters.isEmpty) return;
    final content = book.chapters[_chapter].content;
    if (content.trim().isEmpty) {
      final nextChapter = switch (_mode) {
        PlaybackMode.sequential => nextReadableChapterIndex(
          book.chapters,
          currentIndex: _chapter,
          direction: 1,
        ),
        PlaybackMode.reverse => nextReadableChapterIndex(
          book.chapters,
          currentIndex: _chapter,
          direction: -1,
        ),
        PlaybackMode.repeatOne => null,
      };
      if (nextChapter != null) {
        _chapter = nextChapter;
        _characterOffset = 0;
        _activeChunk = null;
        _publishMediaItem();
        _publishPosition(type: 'chapter');
        await _speakCurrent();
      } else {
        _reportError('没有更多可朗读文本');
      }
      return;
    }
    if (_characterOffset >= content.length) _characterOffset = 0;
    if (_settings.provider == TtsProvider.openai ||
        _settings.provider == TtsProvider.azure) {
      await _playCloudChunk();
    } else if (_settings.provider == TtsProvider.builtin) {
      // builtin 路径同样需要 token 校验：setSpeechRate 之后若有新的
      // seek/切章/中断恢复抢先执行，这次 speak 必须放弃，否则会复活旧位置。
      final token = ++_operation;
      await _tts.setSpeechRate((_speed * .5).clamp(.1, 1.0));
      if (token != _operation) return;
      _publish(playing: true, state: AudioProcessingState.ready);
      _speechStartOffset = _characterOffset;
      await _tts.speak(content.substring(_characterOffset));
    } else {
      _reportError('当前云端服务尚未接入，请选择 OpenAI 或系统语音');
    }
  }

  Future<void> _playCloudChunk() async {
    final book = _book;
    if (book == null) return;
    final content = book.chapters[_chapter].content;
    final chunks = _cloudTts.splitText(content);
    if (chunks.isEmpty) return;
    final chunk = chunks.firstWhere(
      (value) => _characterOffset < value.end,
      orElse: () => chunks.last,
    );
    final token = ++_operation;
    _publish(playing: true, state: AudioProcessingState.loading);
    customEvent.add({
      'type': 'loading',
      'bookId': book.id,
      'chapter': _chapter,
    });
    try {
      final file = await _cloudTts.audioFor(
        book: book,
        chapterIndex: _chapter,
        chunk: chunk,
        settings: _settings,
      );
      if (token != _operation || _book?.id != book.id) return;
      _activeChunk = chunk;
      final duration = await _cloudPlayer.setFilePath(file.path);
      await _cloudPlayer.setSpeed(_speed);
      if (duration != null && _characterOffset > chunk.start) {
        final ratio =
            (_characterOffset - chunk.start) / (chunk.end - chunk.start);
        await _cloudPlayer.seek(duration * ratio.clamp(0.0, 1.0));
      }
      if (token != _operation) return;
      unawaited(_cloudPlayer.play());
    } catch (error) {
      if (token == _operation) _reportError(error.toString());
    }
  }

  void _handleCloudPosition(Duration position) {
    final chunk = _activeChunk;
    final duration = _cloudPlayer.duration;
    if (!isCloud ||
        chunk == null ||
        duration == null ||
        duration.inMilliseconds <= 0) {
      return;
    }
    final ratio = (position.inMilliseconds / duration.inMilliseconds).clamp(
      0.0,
      1.0,
    );
    final offset = chunk.start + ((chunk.end - chunk.start) * ratio).round();
    if (offset == _characterOffset) return;
    final previous = _characterOffset;
    _characterOffset = offset;
    _emitPosition(start: previous, end: offset);
  }

  Future<void> _completeCloudChunk() async {
    if (!isCloud || _handlingCloudCompletion || _activeChunk == null) return;
    _handlingCloudCompletion = true;
    try {
      final content = _book?.chapters[_chapter].content;
      if (content == null) return;
      _characterOffset = _activeChunk!.end;
      _emitPosition(start: _characterOffset, end: _characterOffset);
      if (_characterOffset < content.length) {
        _activeChunk = null;
        await _playCloudChunk();
      } else {
        _activeChunk = null;
        await _completeChapter();
      }
    } finally {
      _handlingCloudCompletion = false;
    }
  }

  Future<void> _completeChapter() async {
    final book = _book;
    if (_stopAfterCurrentChapter) {
      _stopAfterCurrentChapter = false;
      _publish(playing: false, state: AudioProcessingState.completed);
      customEvent.add({
        'type': 'sleepComplete',
        // 所有监听方都按 bookId 过滤，缺了这个字段事件会被静默丢弃。
        'bookId': book?.id,
        'chapter': _chapter,
      });
      return;
    }
    final nextChapter = switch (_mode) {
      PlaybackMode.sequential => nextReadableChapterIndex(
        book?.chapters ?? const [],
        currentIndex: _chapter,
        direction: 1,
      ),
      PlaybackMode.reverse => nextReadableChapterIndex(
        book?.chapters ?? const [],
        currentIndex: _chapter,
        direction: -1,
      ),
      PlaybackMode.repeatOne => _chapter,
    };
    if (book != null && nextChapter != null) {
      _chapter = nextChapter;
      _characterOffset = 0;
      _activeChunk = null;
      _publishMediaItem();
      _publishPosition(type: 'chapter');
      await _speakCurrent();
    } else {
      _publish(playing: false, state: AudioProcessingState.completed);
    }
  }

  void _emitPosition({required int start, required int end}) {
    customEvent.add({
      'type': 'progress',
      'bookId': _book?.id,
      'start': start,
      'end': end,
      'chapter': _chapter,
      'speed': _speed,
      'mode': _mode.name,
    });
  }

  void _reportError(String message) {
    _publish(playing: false, state: AudioProcessingState.error);
    customEvent.add({'type': 'error', 'bookId': _book?.id, 'message': message});
  }

  void _publishMediaItem() {
    final book = _book;
    if (book == null || book.chapters.isEmpty) return;
    mediaItem.add(
      MediaItem(
        id: '${book.id}:$_chapter',
        album: book.title,
        title: book.chapters[_chapter].title,
        artist: book.author,
        extras: {
          'bookId': book.id,
          'chapter': _chapter,
          'aiGenerated': isCloud,
        },
      ),
    );
  }

  void _publishPosition({required String type}) {
    customEvent.add({
      'type': type,
      'bookId': _book?.id,
      'chapter': _chapter,
      'start': _characterOffset,
      'end': _characterOffset,
      'speed': _speed,
      'mode': _mode.name,
    });
  }

  void _publish({
    required bool playing,
    AudioProcessingState state = AudioProcessingState.ready,
  }) {
    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          playing ? MediaControl.pause : MediaControl.play,
          MediaControl.stop,
          MediaControl.skipToNext,
        ],
        androidCompactActionIndices: const [0, 1, 3],
        // 声明系统媒体控件可用的动作，否则锁屏/通知栏只有按钮没有可用的
        // seek 与倍速入口。
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
          MediaAction.setSpeed,
        },
        processingState: state,
        playing: playing,
        speed: _speed,
        updatePosition: _cloudPosition,
      ),
    );
  }

  /// 系统媒体控件的进度只在云端音频下有真实时间轴；builtin 朗读没有可用的
  /// 时间位置，统一上报 0 而不是伪造一个由字符数换算的假时长。
  Duration get _cloudPosition =>
      isCloud && _activeChunk != null ? _cloudPlayer.position : Duration.zero;

  @override
  Future<void> onTaskRemoved() async {
    await stop();
    await super.onTaskRemoved();
  }

  /// 释放会话订阅。全局单例正常不会销毁，这里保证测试与热重载不泄漏。
  Future<void> dispose() async {
    _cancelSleepTimer();
    await _interruptionSubscription?.cancel();
    await _noisySubscription?.cancel();
    await _cloudPlayer.dispose();
  }
}
