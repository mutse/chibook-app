import 'package:chibook/core/sentence_bounds.dart';
import 'package:test/test.dart';

void main() {
  group('sentenceBoundsFor', () {
    test('expands a mid-sentence range to full sentence bounds', () {
      const text = '第一句话。第二句比较长一些。第三句话。';
      // “第二句比较长一些。” 占据 [5, 14)。
      final bounds = sentenceBoundsFor(text, 7, 9);
      expect(bounds.start, 5);
      expect(bounds.end, 14);
      expect(text.substring(bounds.start, bounds.end), '第二句比较长一些。');
    });

    test('keeps highlight stable across callbacks within one sentence', () {
      const text = '开头。中间这句要念很久。结尾。';
      final first = sentenceBoundsFor(text, 3, 5);
      final second = sentenceBoundsFor(text, 8, 11);
      expect(first, second);
    });

    test('starts at text head when range is in the first sentence', () {
      const text = '没有前置标点的第一句！后续。';
      final bounds = sentenceBoundsFor(text, 2, 4);
      expect(bounds.start, 0);
      expect(text.substring(bounds.start, bounds.end), '没有前置标点的第一句！');
    });

    test('runs to text tail when the last sentence has no delimiter', () {
      const text = '前一句。最后一句没有句号';
      final bounds = sentenceBoundsFor(text, 6, 7);
      expect(bounds.end, text.length);
      expect(text.substring(bounds.start, bounds.end), '最后一句没有句号');
    });

    test('includes closing quote after the delimiter', () {
      const text = '他说：“今天不错。”然后离开了。';
      final bounds = sentenceBoundsFor(text, 4, 6);
      expect(text.substring(bounds.start, bounds.end), '他说：“今天不错。”');
    });

    test('does not leak leading closing quote into the next sentence', () {
      const text = '他说：“今天不错。”然后离开了。';
      final bounds = sentenceBoundsFor(text, 11, 13);
      expect(text.substring(bounds.start, bounds.end), '然后离开了。');
    });

    test('treats newline as a sentence boundary', () {
      const text = '第一行没有标点\n第二行内容';
      final bounds = sentenceBoundsFor(text, 9, 10);
      expect(text.substring(bounds.start, bounds.end), '第二行内容');
    });

    test('absorbs consecutive terminal punctuation into one sentence', () {
      const text = '先是……然后再说。';
      final first = sentenceBoundsFor(text, 0, 1);
      expect(text.substring(first.start, first.end), '先是……');
      final second = sentenceBoundsFor(text, 4, 5);
      expect(text.substring(second.start, second.end), '然后再说。');
      const stacked = '什么？！接着走。';
      final bounds = sentenceBoundsFor(stacked, 0, 1);
      expect(stacked.substring(bounds.start, bounds.end), '什么？！');
    });

    test('returns an empty range untouched instead of fabricating one', () {
      const text = '一些内容。';
      final bounds = sentenceBoundsFor(text, 3, 3);
      expect(bounds.start, bounds.end);
    });

    test('clamps out-of-range input safely', () {
      const text = '短句。';
      final bounds = sentenceBoundsFor(text, -5, 99);
      expect(bounds.start, 0);
      expect(bounds.end, text.length);
      expect(sentenceBoundsFor('', 0, 3), (start: 0, end: 0));
    });
  });

  group('nextSentenceChunkEnd', () {
    test('uses one complete sentence per Android utterance', () {
      const text = '第一句。第二句比较长！第三句';
      final first = nextSentenceChunkEnd(text, 0);
      final second = nextSentenceChunkEnd(text, first);

      expect(text.substring(0, first), '第一句。');
      expect(text.substring(first, second), '第二句比较长！');
      expect(text.substring(second), '第三句');
    });

    test('keeps leading whitespace with the following spoken sentence', () {
      const text = '\n\n  正文开始。下一句。';
      final end = nextSentenceChunkEnd(text, 0);
      expect(text.substring(0, end), '\n\n  正文开始。');
    });

    test('caps a sentence without punctuation without splitting emoji', () {
      const text = '甲甲甲😀乙乙';
      final end = nextSentenceChunkEnd(text, 0, maxCharacters: 4);
      expect(end, 3);
      expect(text.substring(0, end), '甲甲甲');
      expect(nextSentenceChunkEnd(text, end, maxCharacters: 4), 7);
    });

    test('rejects a non-positive chunk limit', () {
      expect(
        () => nextSentenceChunkEnd('正文', 0, maxCharacters: 0),
        throwsArgumentError,
      );
    });
  });
}
