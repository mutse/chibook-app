/// PDF 文本层的清洗与可信度判定。
///
/// PDFium 是逐字符返回 Unicode 码点的（`FPDFText_GetUnicode`）。当字体缺少
/// ToUnicode CMap 时——中文 PDF 里非常常见，例如子集化的方正字体、排版软件
/// 导出的 Identity-H 编码文档——返回值会退化成 0（NUL）或私用区码点，于是
/// 提取结果非空但完全不可读。另一类常见问题是文字层把普通汉字映射成康熙
/// 部首（例如“目录”变成“⽬录”）。只用 `isEmpty` 判断“这页有没有文本”，
/// 就会把这些乱码当正文存进书里，播放页、跟读浮层和 TTS 全都拿到垃圾内容。
///
/// 因此这里把两件事分开：
/// - [isGarbledPdfText] 判断这一页的文本层能不能信，用来决定是否退回 OCR；
/// - [cleanPdfPageText] 清洗真正落库的文本：丢弃未映射字符、去掉 PDFium 按
///   版面插进汉字之间的空格、把硬换行的行拼回句子。
///
/// 能力边界：字符映射整体错位（CMap 张冠李戴，提取出合法却不对的汉字）靠
/// 字符类别判断不出来，这里不做识别——PDF 文本提取本就只能尽力而为。
library;

/// 未正确映射的字符占比达到该值即判定整页不可信。
///
/// 正常中文正文里私用区字符和生僻字占比通常远低于 1%，取 0.2 既挡得住整页
/// 乱码，也不会因为正文里夹了几个特殊符号就把好页面推去 OCR。
const double _garbledRatio = 0.2;

/// 短于该长度的行不参与硬换行拼接。页眉页脚、页码、标题和表格单元格都是
/// 短行，拼进正文只会更乱；正文行在 PDF 里通常有二三十字。
const int _minWrappedLineLength = 12;

/// U+2F00–U+2FD5（康熙部首）对应的统一汉字。部分 PDF 的 ToUnicode CMap
/// 会把正文中的普通汉字错误映射到部首区；字形看起来相近，但复制、搜索和 TTS
/// 都会把它们当作不同字符。映射顺序来自 Unicode CJKRadicals 数据。
const String _kangxiRadicalTargets =
    '一丨丶丿乙亅二亠人儿入八冂冖冫几凵刀力勹匕匚匸十卜卩厂厶又口囗土士夂夊夕大女子宀寸小尢尸屮山巛工己巾干幺广廴廾弋弓彐彡彳心戈戶手支攴文斗斤方无日曰月木欠止歹殳毋比毛氏气水火爪父爻爿片牙牛犬玄玉瓜瓦甘生用田疋疒癶白皮皿目矛矢石示禸禾穴立竹米糸缶网羊羽老而耒耳聿肉臣自至臼舌舛舟艮色艸虍虫血行衣襾見角言谷豆豕豸貝赤走足身車辛辰辵邑酉釆里金長門阜隶隹雨靑非面革韋韭音頁風飛食首香馬骨高髟鬥鬯鬲鬼魚鳥鹵鹿麥麻黃黍黑黹黽鼎鼓鼠鼻齊齒龍龜龠';

/// CJK 部首补充区中有明确独体字含义、且会出现在 PDF 正文文字层里的字形。
/// 带箭头注释的是实际问题 PDF 中出现的常用字符，其余简化部首来自同一
/// Unicode CJKRadicals 映射表。
const Map<int, int> _cjkRadicalSupplementTargets = {
  0x2e9f: 0x6bcd, // ⺟ -> 母
  0x2ea0: 0x6c11, // ⺠ -> 民
  0x2ea6: 0x4e2c,
  0x2eb0: 0x7e9f,
  0x2ec4: 0x897f, // ⻄ -> 西
  0x2ec5: 0x89c1,
  0x2ec8: 0x8ba0,
  0x2ec9: 0x8d1d,
  0x2ecb: 0x8f66,
  0x2ed0: 0x9485,
  0x2ed3: 0x957f,
  0x2ed4: 0x95e8,
  0x2ed8: 0x9752, // ⻘ -> 青
  0x2ed9: 0x97e6,
  0x2eda: 0x9875,
  0x2edb: 0x98ce,
  0x2edc: 0x98de,
  0x2ee0: 0x9963,
  0x2ee2: 0x9a6c,
  0x2ee5: 0x9c7c,
  0x2ee6: 0x9e1f,
  0x2ee7: 0x5364,
  0x2ee8: 0x9ea6,
  0x2ee9: 0x9ec4,
  0x2eea: 0x9efe,
  0x2eeb: 0x6589,
  0x2eec: 0x9f50,
  0x2eed: 0x6b6f,
  0x2eee: 0x9f7f,
  0x2eef: 0x7adc,
  0x2ef0: 0x9f99,
  0x2ef2: 0x4e80,
  0x2ef3: 0x9f9f,
};

/// CJK 汉字、假名与全角标点：用于判断两个字符之间的空格是不是版面产物。
const String _cjkRanges =
    '⺀-⿟' // 康熙部首
    '　-〿' // CJK 标点
    '぀-ヿ' // 假名
    '㐀-䶿' // 扩展 A
    '一-鿿' // 基本汉字
    '豈-﫿' // 兼容汉字
    '︰-﹏' // 兼容形式
    '＀-￯'; // 全角与半角形式

/// 汉字本身（不含标点）：行尾是汉字才说明句子是被版面截断的。
const String _ideographRanges = '㐀-䶿一-鿿豈-﫿';

final RegExp _spaceBetweenCjk = RegExp('(?<=[$_cjkRanges]) +(?=[$_cjkRanges])');
final RegExp _horizontalSpace = RegExp(r'[ \t]+');
final RegExp _blankLines = RegExp(r'\n{3,}');

/// 行尾可以和下一行拼接的字符。刻意不含数字：目录行以页码结尾，拼起来会把
/// 整张目录粘成一团。
final RegExp _wrappableEnd = RegExp('[${_ideographRanges}A-Za-z]\$');
final RegExp _wrappableStart = RegExp('^[${_cjkRanges}A-Za-z]');
final RegExp _latinEnd = RegExp(r'[A-Za-z]$');
final RegExp _latinStart = RegExp(r'^[A-Za-z]');

/// 判断 PDFium 提取的原始页面文本是否为乱码。
///
/// 判断依据是未映射字符（NUL、私用区、替换字符、扩展区汉字）占比过高，
/// 这是字体缺 ToUnicode CMap 的典型症状。不能用“汉字多但标点少”作为依据：
/// 古籍、目录和逐行排版的正常文本同样可能没有标点，误判后 OCR 反而更差。
///
/// 空白页返回 `false`：“没有文本”和“文本不可信”是两回事，调用方对两者的
/// 处理恰好相同（都退回 OCR），但语义要分清。
bool isGarbledPdfText(String raw) {
  var counted = 0;
  var suspect = 0;
  for (final rune in raw.runes) {
    if (_isWhitespace(rune)) continue;
    counted++;
    if (_isUnmappedGlyph(rune) || _isRareIdeograph(rune)) suspect++;
  }
  if (counted == 0) return false;
  return suspect / counted >= _garbledRatio;
}

/// 清洗一页 PDF 文本。文本层和 OCR 结果都走这里，保证两条路产出同样的格式。
///
/// 幂等：对已清洗过的文本再调用一次，结果不变。
String cleanPdfPageText(String raw) {
  if (raw.isEmpty) return '';

  final buffer = StringBuffer();
  for (final rune in raw.replaceAll('\r\n', '\n').runes) {
    final normalizedRune = _normalizeCjkRadical(rune);
    if (normalizedRune == 0x0d) {
      buffer.write('\n'); // 落单的 \r 也是换行
    } else if (normalizedRune == 0xa0 ||
        normalizedRune == 0x2007 ||
        normalizedRune == 0x202f) {
      buffer.write(' '); // 各种不换行空格按普通空格处理
    } else if (_isUnmappedGlyph(normalizedRune) ||
        _isInvisible(normalizedRune)) {
      continue; // 未映射或零宽字符：留着只会变成方框和朗读杂音
    } else {
      buffer.writeCharCode(normalizedRune);
    }
  }

  final text = buffer
      .toString()
      .replaceAll(_horizontalSpace, ' ')
      // PDFium 按字符位置插空格，落到中文正文里几乎全是伪空格。
      .replaceAll(_spaceBetweenCjk, '');
  return _joinWrappedLines(text).replaceAll(_blankLines, '\n\n').trim();
}

/// 把被版面截断的行拼回句子，保留段落之间的空行。
///
/// 只在上一行以汉字或西文字母结尾、且足够长时拼接：以句末标点结尾的行说明
/// 句子已经完了，换行留着正好是朗读和预览的自然停顿。
String _joinWrappedLines(String text) {
  final joined = <String>[];
  for (final line in text.split('\n')) {
    final current = line.trim();
    if (joined.isEmpty || current.isEmpty || joined.last.isEmpty) {
      joined.add(current);
      continue;
    }
    final previous = joined.last;
    if (previous.length >= _minWrappedLineLength &&
        _wrappableEnd.hasMatch(previous) &&
        _wrappableStart.hasMatch(current)) {
      // 西文单词之间要补空格，汉字之间不能补。
      final separator =
          _latinEnd.hasMatch(previous) && _latinStart.hasMatch(current)
          ? ' '
          : '';
      joined[joined.length - 1] = '$previous$separator$current';
      continue;
    }
    joined.add(current);
  }
  return joined.join('\n');
}

/// 字体缺 ToUnicode 时 PDFium 会吐出的东西：NUL、控制字符、替换字符、
/// 私用区码点和非字符码点。
bool _isUnmappedGlyph(int rune) =>
    (rune < 0x20 && rune != 0x09 && rune != 0x0a && rune != 0x0d) ||
    (rune >= 0x7f && rune <= 0x9f) ||
    rune == 0xfffd ||
    _isPrivateUse(rune) ||
    _isNoncharacter(rune);

bool _isPrivateUse(int rune) =>
    (rune >= 0xe000 && rune <= 0xf8ff) ||
    (rune >= 0xf0000 && rune <= 0xffffd) ||
    (rune >= 0x100000 && rune <= 0x10fffd);

bool _isNoncharacter(int rune) =>
    (rune >= 0xfdd0 && rune <= 0xfdef) || (rune & 0xfffe) == 0xfffe;

/// 扩展区汉字。正常中文书里几乎不出现，成片出现基本可以断定是映射错了。
bool _isRareIdeograph(int rune) =>
    (rune >= 0x3400 && rune <= 0x4dbf) || (rune >= 0x20000 && rune <= 0x3ffff);

int _normalizeCjkRadical(int rune) {
  if (rune >= 0x2f00 && rune <= 0x2fd5) {
    return _kangxiRadicalTargets.codeUnitAt(rune - 0x2f00);
  }
  return _cjkRadicalSupplementTargets[rune] ?? rune;
}

/// 零宽字符：本身合法，所以不算乱码证据，但没有阅读价值，清洗时丢掉。
bool _isInvisible(int rune) =>
    (rune >= 0x200b && rune <= 0x200d) || rune == 0xfeff;

bool _isWhitespace(int rune) =>
    rune == 0x09 ||
    rune == 0x0a ||
    rune == 0x0d ||
    rune == 0x20 ||
    rune == 0xa0 ||
    rune == 0x3000;
