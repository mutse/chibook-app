import 'package:chibook/core/models.dart';
import 'package:test/test.dart';

void main() {
  test('listening record accepts missing fields from older JSON', () {
    final decoded = ListeningRecord.fromJson(const {'bookId': 'legacy-book'});

    expect(decoded.bookId, 'legacy-book');
    expect(decoded.chapterIndex, 0);
    expect(decoded.characterOffset, 0);
    expect(decoded.listenedSeconds, 0);
    expect(decoded.updatedAt, DateTime.fromMillisecondsSinceEpoch(0));
  });

  test('listening record tolerates an unparseable timestamp', () {
    final decoded = ListeningRecord.fromJson(const {
      'bookId': 'legacy-book',
      'updatedAt': 'not-a-date',
    });

    expect(decoded.updatedAt, DateTime.fromMillisecondsSinceEpoch(0));
  });

  test('audio progress tolerates an unknown playback mode', () {
    final decoded = AudioProgress.fromJson(const {
      'bookId': 'legacy-book',
      'mode': 'shuffleEverything',
    });

    expect(decoded.mode, PlaybackMode.sequential);
  });
}
