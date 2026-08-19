import 'dart:async';

import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

const pdfCjkFallbackFontAsset = 'assets/fonts/NotoSansCJKsc-Regular.otf';
const pdfCjkFallbackFontLength = 16437364;
const _pdfCjkFallbackFontSha256 =
    '2c76254f6fc379fddfce0a7e84fb5385bb135d3e399294f6eeb6680d0365b74b';

/// Android 的 PDFium 无法保证能为未嵌入字体的 PDF 找到中文字体。
///
/// 该管理器仅由 Android PDF 阅读器使用。pdfrx 会在发现缺失字体后调用解析器，
/// 注册字体并重新打开文档；字体文件不会在普通启动或字体完整的 PDF 中预加载。
final PdfFontManager androidPdfFontManager = PdfFontManager(
  resolvers: [BundledCjkPdfFontResolver()],
);

class BundledCjkPdfFontResolver implements PdfFontResolver {
  Future<Uint8List>? _fontData;

  @override
  FutureOr<PdfFontResolution?> resolve(
    PdfFontQuery query,
    PdfFontResolveContext context,
  ) {
    if (!shouldUseCjkPdfFallback(query)) return null;
    return PdfFontResolution(
      loadData: ({onProgress}) async {
        final data = await (_fontData ??= _loadFontData());
        onProgress?.call(loaded: data.length, total: data.length);
        return data;
      },
      resolvedFace: 'Noto Sans CJK SC',
      source: Uri.parse('asset:///$pdfCjkFallbackFontAsset'),
      expectedLength: pdfCjkFallbackFontLength,
      expectedSha256: _pdfCjkFallbackFontSha256,
    );
  }

  Future<Uint8List> _loadFontData() async {
    final bytes = await rootBundle.load(pdfCjkFallbackFontAsset);
    return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
  }
}

/// 某些中文 PDF 会把字体错误标记成 ANSI/default，因此除了明确的 CJK
/// charset，也需要根据常见中文字体名和通用 charset 启用回退。
bool shouldUseCjkPdfFallback(PdfFontQuery query) {
  final face = query.face.toLowerCase().replaceAll(
    RegExp(r'[^a-z0-9\u4e00-\u9fff]'),
    '',
  );
  const cjkFaceMarkers = <String>[
    'adobesong',
    'adobeheit',
    'adobefangsong',
    'adobekaiti',
    'simsun',
    'nsimsun',
    'simhei',
    'simkai',
    'kaiti',
    'fangsong',
    'microsoftyahei',
    'dengxian',
    'songti',
    'heiti',
    'pingfang',
    'hiragino',
    'notosanscjk',
    'sourcehansans',
    'sourcehanserif',
    '宋体',
    '黑体',
    '楷体',
    '仿宋',
    '微软雅黑',
    '等线',
  ];
  if (cjkFaceMarkers.any(face.contains)) return true;

  return switch (query.charset) {
    PdfFontCharset.gb2312 ||
    PdfFontCharset.chineseBig5 ||
    PdfFontCharset.shiftJis ||
    PdfFontCharset.hangul ||
    PdfFontCharset.default_ ||
    PdfFontCharset.ansi => true,
    _ => false,
  };
}
