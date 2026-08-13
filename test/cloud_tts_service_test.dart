import 'package:chibook/services/cloud_tts_service.dart';
import 'package:test/test.dart';

void main() {
  test('Microsoft display voices map to stable Edge voice ids', () {
    expect(microsoftVoiceId('晓晓 · 女声'), 'zh-CN-XiaoxiaoNeural');
    expect(microsoftVoiceId('云希 · 男声'), 'zh-CN-YunxiNeural');
  });

  test('legacy Azure voice names degrade to a compatible voice', () {
    expect(microsoftVoiceId('温润男声'), 'zh-CN-YunxiNeural');
    expect(microsoftVoiceId('已下线的音色'), 'zh-CN-XiaoxiaoNeural');
  });

  test('text chunks keep all characters in order', () {
    final service = CloudTtsService();
    final chunks = service.splitText('第一句。第二句。第三句。', maxCharacters: 6);

    expect(chunks.map((chunk) => chunk.text).join(), '第一句。第二句。第三句。');
    expect(chunks.first.start, 0);
    expect(chunks.last.end, '第一句。第二句。第三句。'.length);
  });
}
