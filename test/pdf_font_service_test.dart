import 'package:chibook/services/pdf_font_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  PdfFontQuery query(String face, PdfFontCharset charset) => PdfFontQuery(
    face: face,
    weight: 400,
    isItalic: false,
    charset: charset,
    pitchFamily: 0,
  );

  test('uses fallback for explicit simplified and traditional Chinese', () {
    expect(
      shouldUseCjkPdfFallback(query('Unknown', PdfFontCharset.gb2312)),
      isTrue,
    );
    expect(
      shouldUseCjkPdfFallback(query('Unknown', PdfFontCharset.chineseBig5)),
      isTrue,
    );
  });

  test('uses fallback for common Chinese font aliases', () {
    expect(
      shouldUseCjkPdfFallback(query('ABCDEF+SimSun', PdfFontCharset.symbol)),
      isTrue,
    );
    expect(
      shouldUseCjkPdfFallback(query('微软雅黑', PdfFontCharset.symbol)),
      isTrue,
    );
  });

  test('covers malformed Chinese PDFs marked as default or ANSI', () {
    expect(
      shouldUseCjkPdfFallback(query('F1', PdfFontCharset.default_)),
      isTrue,
    );
    expect(shouldUseCjkPdfFallback(query('F2', PdfFontCharset.ansi)), isTrue);
  });

  test('does not replace unrelated symbol or complex-script fonts', () {
    expect(
      shouldUseCjkPdfFallback(query('Symbol', PdfFontCharset.symbol)),
      isFalse,
    );
    expect(
      shouldUseCjkPdfFallback(query('Arabic', PdfFontCharset.arabic)),
      isFalse,
    );
  });

  test('bundled CJK fallback font is complete', () async {
    final bytes = await rootBundle.load(pdfCjkFallbackFontAsset);
    expect(bytes.lengthInBytes, pdfCjkFallbackFontLength);
  });
}
