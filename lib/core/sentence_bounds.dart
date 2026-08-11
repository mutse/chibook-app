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
