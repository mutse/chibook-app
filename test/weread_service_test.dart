import 'package:chibook/services/weread_service.dart';
import 'package:test/test.dart';

void main() {
  test('WeRead login QR uses the current confirmation URL', () {
    final session = WeReadLoginSession(uid: 'login-uid', generation: 1);

    expect(
      session.confirmUrl,
      'https://weread.qq.com/web/confirm?uid=login-uid',
    );
  });

  test('WeRead login recognizes the current webLoginVid response', () {
    final result = parseWeReadLoginPoll({
      'succeed': true,
      'webLoginVid': 123456,
      'accessToken': 'session-key',
      'refreshToken': 'refresh-key',
    });

    expect(result.state, WeReadLoginState.success);
    expect(result.vid, '123456');
    expect(result.accessToken, 'session-key');
    expect(result.refreshToken, 'refresh-key');
  });

  test('WeRead login recognizes nested OTP and timeout states', () {
    expect(
      parseWeReadLoginPoll({
        'data': {'logicCode': 'NEED_OTP'},
      }).state,
      WeReadLoginState.needsOtp,
    );
    expect(
      parseWeReadLoginPoll({'logicCode': 'OTP_NOT_MATCH'}).state,
      WeReadLoginState.otpNotMatch,
    );
    expect(
      parseWeReadLoginPoll({'logicCode': 'LOGIN_TIMEOUT'}).state,
      WeReadLoginState.expired,
    );
  });

  test('WeRead id hashing matches current Web reader hashes', () {
    expect(wereadHashId('43208843'), 'c9c321c07293508bc9c79df');
    expect(wereadHashId(2), 'c81322c012c81e728d9d180');
    expect(wereadHashId(119), '07e323f027707e1cd7dc674');
  });

  test(
    'WeRead HTML extraction keeps paragraph boundaries and drops scripts',
    () {
      final text = wereadHtmlToText('''
      <html><body>
        <h1>第一章</h1>
        <p>第一段<br>下一行</p>
        <script>不应出现</script>
        <p>第二段</p>
      </body></html>
    ''');

      expect(text, contains('第一章'));
      expect(text, contains('第一段\n下一行'));
      expect(text, contains('第二段'));
      expect(text, isNot(contains('不应出现')));
    },
  );

  test('WeRead payload signature is independent of map insertion order', () {
    final first = wereadSignPayload({
      'b': 'book',
      'c': 'chapter',
      'ct': 123,
      'prevChapter': false,
    });
    final second = wereadSignPayload({
      'prevChapter': false,
      'ct': 123,
      'c': 'chapter',
      'b': 'book',
    });

    expect(first, second);
    expect(first, matches(RegExp(r'^[0-9a-f]+$')));
  });
}
