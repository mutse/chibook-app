/// 朗读高亮的句级对齐。
///
/// 系统 TTS 的 progress 回调粒度不稳定（逐词甚至逐字），直接高亮原始区间
/// 会造成闪烁；规格要求高亮以句为单位对齐。这里把回调给出的字符区间
/// 扩展到所在句子的完整边界。区间无效（空或越界后为空）时原样返回，
/// 由调用方降级为不高亮——不得伪造进度。
library;

const Set<String> _sentenceDelimiters = {
  '。',
  '！',
  '？',
  '；',
  '!',
  '?',
  ';',
  '…',
  '\n',
  '\r',
};

/// 句末标点之后允许并入本句的收尾符号（右引号、右括号等）。
/// 英文直引号 `"`/`'` 不区分开合方向，无法判断归属，刻意不收录。
const Set<String> _closingMarks = {'”', '’', '』', '」', '）', ')', '】', '〉', '》'};

/// 将 `[start, end)` 扩展为所在句子的完整区间。
///
/// 返回的区间保证 `0 <= start <= end <= text.length`；输入区间为空时
/// 返回收缩后的空区间，表示"本次没有可高亮的句子"。
({int start, int end}) sentenceBoundsFor(String text, int start, int end) {
  if (text.isEmpty) return (start: 0, end: 0);
  final low = start.clamp(0, text.length);
  final high = end.clamp(low, text.length);
  if (high <= low) return (start: low, end: high);

  var from = low;
  while (from > 0 && !_sentenceDelimiters.contains(text[from - 1])) {
    from--;
  }
  // 上一句句末标点后紧跟的右引号/空白属于上一句，跳过它们再作为句首。
  while (from < low &&
      (_closingMarks.contains(text[from]) ||
          text[from] == ' ' ||
          text[from] == '　')) {
    from++;
  }

  var to = high;
  while (to < text.length && !_sentenceDelimiters.contains(text[to])) {
    to++;
  }
  // 吸收整段连续句末标点（……、？！）及夹杂的右引号；只收第一个的话，
  // 剩下的标点会被当成下一句开头，造成一次单字符高亮抖动。
  while (to < text.length &&
      (_sentenceDelimiters.contains(text[to]) ||
          _closingMarks.contains(text[to]))) {
    to++;
  }
  return (start: from, end: to);
}

/// 返回从 [start] 开始、适合作为一次系统 TTS utterance 的句末位置。
///
/// Android 的部分厂商 TTS 不实现逐字范围回调。让每次真实 utterance 只包含
/// 一个句子后，即使没有范围回调，也能在 utterance 开始/结束事件上可靠地做
/// 句级高亮和跟随。超长无标点文本仍受 [maxCharacters] 限制。
int nextSentenceChunkEnd(String text, int start, {int maxCharacters = 3000}) {
  if (maxCharacters <= 0) {
    throw ArgumentError.value(maxCharacters, 'maxCharacters', '必须大于 0');
  }
  final from = start.clamp(0, text.length);
  if (from >= text.length) return text.length;
  final limit = (from + maxCharacters).clamp(from, text.length);
  var hasSpokenContent = false;
  var end = from;
  while (end < limit) {
    final character = text[end];
    end++;
    if (_sentenceDelimiters.contains(character)) {
      // 开头的换行和空白归入下一句，避免生成只含空白的 utterance。
      if (!hasSpokenContent) continue;
      while (end < limit &&
          (_sentenceDelimiters.contains(text[end]) ||
              _closingMarks.contains(text[end]))) {
        end++;
      }
      return end;
    }
    if (!_closingMarks.contains(character) && character.trim().isNotEmpty) {
      hasSpokenContent = true;
    }
  }

  // Dart 字符串索引是 UTF-16 code unit；硬截断时不要拆开 emoji 等代理对。
  if (end < text.length &&
      end > from &&
      _isHighSurrogate(text.codeUnitAt(end - 1)) &&
      _isLowSurrogate(text.codeUnitAt(end))) {
    end--;
  }
  return end;
}

bool _isHighSurrogate(int value) => value >= 0xD800 && value <= 0xDBFF;

bool _isLowSurrogate(int value) => value >= 0xDC00 && value <= 0xDFFF;
