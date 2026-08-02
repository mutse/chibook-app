import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../core/models.dart';

late final TtsAudioHandler ttsAudioHandler;

Future<void> initializeAudioService() async {
  ttsAudioHandler = await AudioService.init<TtsAudioHandler>(
    builder: TtsAudioHandler.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.chibook.erdu.tts',
      androidNotificationChannelName: '耳读听书',
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
  Book? _book;
  int _chapter = 0;
  double _speed = 1;

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
    _tts.setErrorHandler((message) {
      _publish(playing: false, state: AudioProcessingState.error);
      customEvent.add({'type': 'error', 'message': message});
    });
    _tts.setProgressHandler((text, start, end, word) {
      customEvent.add({
        'type': 'progress',
        'start': start,
        'end': end,
        'chapter': _chapter,
      });
    });
    _tts.setCompletionHandler(() async {
      final book = _book;
      if (book != null && _chapter < book.chapters.length - 1) {
        _chapter++;
        _publishMediaItem();
        customEvent.add({'type': 'chapter', 'chapter': _chapter});
        await _speakCurrent();
      } else {
        _publish(playing: false, state: AudioProcessingState.completed);
      }
    });
    _publish(playing: false);
  }

  Future<void> loadBook(Book book, {required int chapterIndex}) async {
    await _tts.stop();
    _book = book;
    _chapter = chapterIndex.clamp(0, book.chapters.length - 1);
    _publishMediaItem();
    _publish(playing: false, state: AudioProcessingState.ready);
    customEvent.add({'type': 'chapter', 'chapter': _chapter});
  }

  @override
  Future<void> setSpeed(double speed) async {
    _speed = speed;
    await _tts.setSpeechRate((_speed * .5).clamp(.1, 1.0));
    if (playbackState.value.playing) {
      await _tts.stop();
      await _speakCurrent();
    }
  }

  @override
  Future<void> play() => _speakCurrent();

  @override
  Future<void> pause() async {
    await _tts.pause();
    _publish(playing: false);
  }

  @override
  Future<void> stop() async {
    await _tts.stop();
    _publish(playing: false, state: AudioProcessingState.idle);
  }

  @override
  Future<void> skipToNext() => _moveChapter(1);

  @override
  Future<void> skipToPrevious() => _moveChapter(-1);

  Future<void> _moveChapter(int delta) async {
    final book = _book;
    if (book == null || book.chapters.isEmpty) return;
    await _tts.stop();
    _chapter = (_chapter + delta).clamp(0, book.chapters.length - 1);
    _publishMediaItem();
    customEvent.add({'type': 'chapter', 'chapter': _chapter});
    await _speakCurrent();
  }

  Future<void> _speakCurrent() async {
    final book = _book;
    if (book == null || book.chapters.isEmpty) return;
    await _tts.setSpeechRate((_speed * .5).clamp(.1, 1.0));
    _publish(playing: true, state: AudioProcessingState.ready);
    await _tts.speak(book.chapters[_chapter].content);
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
        extras: {'bookId': book.id, 'chapter': _chapter},
      ),
    );
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
        processingState: state,
        playing: playing,
      ),
    );
  }
}
