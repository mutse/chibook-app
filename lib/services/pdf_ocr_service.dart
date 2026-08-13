import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import '../core/pdf_text.dart';

class PdfOcrService {
  bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  Future<String?> recognizePage(PdfPage page) async {
    if (!isSupported) return null;
    final scale = (180 / 72).clamp(1.0, 3.0);
    final rendered = await page.render(
      fullWidth: page.width * scale,
      fullHeight: page.height * scale,
      backgroundColor: 0xffffffff,
    );
    if (rendered == null) return '';

    File? temporary;
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    final recognizer = TextRecognizer(script: TextRecognitionScript.chinese);
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(rendered.pixels);
      descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: rendered.width,
        height: rendered.height,
        pixelFormat: ui.PixelFormat.bgra8888,
      );
      codec = await descriptor.instantiateCodec();
      final frame = await codec.getNextFrame();
      image = frame.image;
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      if (png == null) return '';
      final temp = await getTemporaryDirectory();
      temporary = File(
        '${temp.path}/erdu_ocr_${DateTime.now().microsecondsSinceEpoch}_${page.pageNumber}.png',
      );
      await temporary.writeAsBytes(png.buffer.asUint8List(), flush: true);
      final result = await recognizer.processImage(
        InputImage.fromFilePath(temporary.path),
      );
      // 清洗交给 cleanPdfPageText：ML Kit 的中文结果同样会在汉字之间夹空格，
      // 和文本层走同一套规范化才能保证两条路产出的正文格式一致。
      return cleanPdfPageText(result.text);
    } finally {
      await recognizer.close();
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
      rendered.dispose();
      if (temporary != null && await temporary.exists()) {
        await temporary.delete();
      }
    }
  }
}
