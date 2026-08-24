import 'package:chibook/core/models.dart';
import 'package:chibook/core/reading_follow.dart';
import 'package:test/test.dart';

void main() {
  group('readingFollowScrollTarget', () {
    test('keeps the spoken line near the upper third of the viewport', () {
      expect(
        readingFollowScrollTarget(
          contentOffset: 900,
          minScrollExtent: 0,
          maxScrollExtent: 1800,
          viewportDimension: 600,
        ),
        708,
      );
    });

    test('clamps the beginning and end of the document', () {
      expect(
        readingFollowScrollTarget(
          contentOffset: 20,
          minScrollExtent: 0,
          maxScrollExtent: 1200,
          viewportDimension: 600,
        ),
        0,
      );
      expect(
        readingFollowScrollTarget(
          contentOffset: 1800,
          minScrollExtent: 0,
          maxScrollExtent: 1200,
          viewportDimension: 600,
        ),
        1200,
      );
    });
  });

  group('nextReadableChapterIndex', () {
    const chapters = [
      Chapter(title: '封面', content: ''),
      Chapter(title: '第一页', content: '正文'),
      Chapter(title: '插图', content: '  \n '),
      Chapter(title: '第二页', content: '下一页正文'),
    ];

    test('skips empty PDF pages while moving forward', () {
      expect(
        nextReadableChapterIndex(chapters, currentIndex: 1, direction: 1),
        3,
      );
    });

    test('skips empty PDF pages while moving backward', () {
      expect(
        nextReadableChapterIndex(chapters, currentIndex: 3, direction: -1),
        1,
      );
    });

    test('returns null at the readable boundary', () {
      expect(
        nextReadableChapterIndex(chapters, currentIndex: 3, direction: 1),
        isNull,
      );
      expect(
        nextReadableChapterIndex(chapters, currentIndex: 1, direction: -1),
        isNull,
      );
    });
  });

  group('nextTtsChapterIndex', () {
    const remoteChapters = [
      Chapter(title: '第一章', content: '已加载', remoteUid: 1),
      Chapter(title: '第二章', content: '', remoteUid: 2, isLoaded: false),
      Chapter(title: '第三章', content: '', remoteUid: 3, isLoaded: false),
    ];

    test('enters an unloaded remote chapter so TTS can fetch it', () {
      expect(
        nextTtsChapterIndex(
          remoteChapters,
          currentIndex: 0,
          direction: 1,
          loadOnDemand: true,
        ),
        1,
      );
    });

    test('still respects remote chapter boundaries', () {
      expect(
        nextTtsChapterIndex(
          remoteChapters,
          currentIndex: 2,
          direction: 1,
          loadOnDemand: true,
        ),
        isNull,
      );
    });
  });
}
