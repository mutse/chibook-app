import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:html/parser.dart' as html_parser;

import '../core/models.dart';

const _wereadBaseUrl = 'https://weread.qq.com';
const _wereadUserAgent =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
    'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36';

class WeReadException implements Exception {
  const WeReadException(this.message);

  final String message;

  @override
  String toString() => message;
}

class WeReadOtpRequiredException extends WeReadException {
  const WeReadOtpRequiredException() : super('请输入微信显示的四位验证码');
}

class WeReadOtpRejectedException extends WeReadException {
  const WeReadOtpRejectedException() : super('验证码错误，请重新输入');
}

class WeReadAccount {
  const WeReadAccount({required this.vid, required this.name, this.avatarUrl});

  final String vid;
  final String name;
  final String? avatarUrl;

  Map<String, Object?> toJson() => {
    'vid': vid,
    'name': name,
    'avatarUrl': avatarUrl,
  };

  factory WeReadAccount.fromJson(Map<String, Object?> json) => WeReadAccount(
    vid: json['vid']?.toString() ?? '',
    name: json['name'] as String? ?? '微信读书用户',
    avatarUrl: json['avatarUrl'] as String?,
  );
}

class WeReadLoginSession {
  WeReadLoginSession({
    required this.uid,
    required this.generation,
    Map<String, String> cookies = const {},
  }) : _cookies = Map<String, String>.from(cookies);

  final String uid;
  final int generation;
  final Map<String, String> _cookies;
  String get confirmUrl => '$_wereadBaseUrl/web/confirm?uid=$uid';
}

enum WeReadLoginState {
  waiting,
  success,
  needsOtp,
  otpExpired,
  otpNotMatch,
  expired,
}

class WeReadLoginPoll {
  const WeReadLoginPoll({
    required this.state,
    required this.payload,
    this.vid,
    this.accessToken,
    this.refreshToken,
  });

  final WeReadLoginState state;
  final Map<String, Object?> payload;
  final String? vid;
  final String? accessToken;
  final String? refreshToken;
}

class WeReadCatalog {
  const WeReadCatalog({
    required this.title,
    required this.author,
    required this.coverUrl,
    required this.format,
    required this.chapters,
    required this.progress,
    this.currentChapterUid,
  });

  final String title;
  final String author;
  final String? coverUrl;
  final String format;
  final List<Chapter> chapters;
  final double progress;
  final int? currentChapterUid;
}

class WeReadCredentialStore {
  const WeReadCredentialStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _cookieKey = 'erdu.weread.cookie.v1';
  static const _accountKey = 'erdu.weread.account.v1';
  final FlutterSecureStorage _storage;

  Future<Map<String, String>> readCookies() async {
    final raw = await _storage.read(key: _cookieKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final value = (jsonDecode(raw) as Map).cast<String, Object?>();
      return value.map((key, value) => MapEntry(key, value.toString()));
    } catch (_) {
      return {};
    }
  }

  Future<WeReadAccount?> readAccount() async {
    final raw = await _storage.read(key: _accountKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return WeReadAccount.fromJson(
        (jsonDecode(raw) as Map).cast<String, Object?>(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> save({
    required Map<String, String> cookies,
    required WeReadAccount account,
  }) async {
    await Future.wait([
      _storage.write(key: _cookieKey, value: jsonEncode(cookies)),
      _storage.write(key: _accountKey, value: jsonEncode(account.toJson())),
    ]);
  }

  Future<void> writeCookies(Map<String, String> cookies) =>
      _storage.write(key: _cookieKey, value: jsonEncode(cookies));

  Future<void> clear() => Future.wait([
    _storage.delete(key: _cookieKey),
    _storage.delete(key: _accountKey),
  ]);
}

class WeReadService {
  WeReadService({
    WeReadCredentialStore? credentials,
    HttpClient Function()? clientFactory,
  }) : credentials = credentials ?? const WeReadCredentialStore(),
       _clientFactory = clientFactory ?? HttpClient.new;

  final WeReadCredentialStore credentials;
  final HttpClient Function() _clientFactory;
  final Random _random = Random.secure();
  int _loginGeneration = 0;

  Future<WeReadAccount?> restoreAccount() => credentials.readAccount();

  Future<WeReadLoginSession> startLogin() async {
    final cookies = <String, String>{};
    final response = await _request(
      'GET',
      '/api/auth/getLoginUid',
      auth: false,
      cookies: cookies,
    );
    final data = _decodeMap(response.body);
    final uid = data['uid']?.toString();
    if (uid == null || uid.isEmpty) {
      throw const WeReadException('微信读书没有返回登录二维码，请稍后重试');
    }
    return WeReadLoginSession(
      uid: uid,
      generation: ++_loginGeneration,
      cookies: cookies,
    );
  }

  Future<WeReadAccount> completeLogin(
    WeReadLoginSession session, {
    String otp = '',
    Duration timeout = const Duration(minutes: 3),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (session.generation != _loginGeneration) {
        throw const WeReadException('登录二维码已更新');
      }
      WeReadLoginPoll poll;
      try {
        final response = await _request(
          'GET',
          '/api/auth/getLoginInfo',
          query: {'uid': session.uid, if (otp.isNotEmpty) 'otp': otp},
          auth: false,
          cookies: session._cookies,
          timeout: const Duration(seconds: 65),
        );
        poll = parseWeReadLoginPoll(_decodeMap(response.body));
      } on TimeoutException {
        continue;
      } on WeReadException catch (error) {
        if (DateTime.now().isAfter(deadline)) rethrow;
        if (!error.message.contains('超时')) rethrow;
        continue;
      }

      switch (poll.state) {
        case WeReadLoginState.needsOtp:
          throw const WeReadOtpRequiredException();
        case WeReadLoginState.otpNotMatch:
          throw const WeReadOtpRejectedException();
        case WeReadLoginState.otpExpired:
          throw const WeReadException('验证码已过期，请重新生成二维码');
        case WeReadLoginState.expired:
          throw const WeReadException('二维码已过期，请重新生成后扫码');
        case WeReadLoginState.waiting:
          await Future<void>.delayed(const Duration(milliseconds: 600));
          continue;
        case WeReadLoginState.success:
          break;
      }

      final info = poll.payload;
      final vid = poll.vid;
      final accessToken = poll.accessToken;
      final refreshToken = poll.refreshToken;
      if (vid == null ||
          vid.isEmpty ||
          accessToken == null ||
          accessToken.isEmpty) {
        await Future<void>.delayed(const Duration(seconds: 1));
        continue;
      }
      if (session.generation != _loginGeneration) {
        throw const WeReadException('登录二维码已更新');
      }

      // The current web login endpoint returns webLoginVid/accessToken and
      // may also set HttpOnly cookies. The browser itself writes wr_vid and
      // wr_skey from these two fields, so mirror that behavior as a fallback.
      final cookies = session._cookies;
      cookies.putIfAbsent('wr_vid', () => vid);
      cookies.putIfAbsent('wr_skey', () => accessToken);
      if (refreshToken != null && refreshToken.isNotEmpty) {
        cookies.putIfAbsent('wr_rt', () => refreshToken);
      }

      var user = <String, Object?>{};
      try {
        final userResponse = await _request(
          'GET',
          '/api/userInfo',
          query: {'userVid': vid},
          auth: false,
          cookies: cookies,
        );
        user = _unwrapData(_decodeMap(userResponse.body));
      } on WeReadException {
        // The account is already authenticated. Profile metadata is optional
        // and should not turn a successful QR confirmation into a login error.
      }
      final account = WeReadAccount(
        vid: vid,
        name: _firstText([
          user['name'],
          user['userName'],
          info['name'],
          info['userName'],
        ], fallback: '微信读书用户'),
        avatarUrl: _firstNullableText([
          user['avatar'],
          user['avatarUrl'],
          info['avatar'],
        ]),
      );
      await credentials.save(cookies: cookies, account: account);
      return account;
    }
    throw const WeReadException('二维码已过期，请重新生成后扫码');
  }

  Future<void> logout() {
    _loginGeneration++;
    return credentials.clear();
  }

  Future<List<Book>> syncShelf() async {
    final response = await _authenticatedRequest('GET', '/web/shelf/sync');
    final data = _decodeMap(response.body);
    _throwForApiError(data);
    final rawBooks = _asList(data['books']);
    return rawBooks
        .map(_bookFromShelfItem)
        .whereType<Book>()
        .toList(growable: false);
  }

  Future<WeReadCatalog> loadCatalog(String bookId) async {
    await renewSession();
    final responses = await Future.wait([
      _authenticatedRequest('GET', '/web/book/info', query: {'bookId': bookId}),
      _authenticatedRequest(
        'POST',
        '/web/book/chapterInfos',
        body: {
          'bookIds': [bookId],
        },
      ),
      _authenticatedRequest(
        'GET',
        '/web/book/getProgress',
        query: {'bookId': bookId},
      ),
    ]);
    final infoRoot = _decodeMap(responses[0].body);
    _throwForApiError(infoRoot);
    final info = _unwrapData(infoRoot);
    final catalogRoot = _decodeMap(responses[1].body);
    _throwForApiError(catalogRoot);
    final progressRoot = _decodeMap(responses[2].body);
    _throwForApiError(progressRoot);
    final progressData = _unwrapData(progressRoot);
    final progressBook = _asMap(progressData['book']);
    final dataValues = _asList(catalogRoot['data']);
    final catalog = dataValues.isNotEmpty
        ? _asMap(dataValues.first)
        : catalogRoot;
    final nestedBook = _asMap(catalog['book']);
    final rawChapters = _asList(
      catalog['updated'] ?? catalog['chapters'] ?? catalogRoot['updated'],
    );
    final chapters =
        rawChapters
            .map(_asMap)
            .where((value) => value['chapterUid'] != null)
            .map(
              (value) => (
                index: _asInt(value['chapterIdx']) ?? 0,
                wordCount: _asInt(value['wordCount']) ?? 0,
                chapter: Chapter(
                  title: _firstText([
                    value['title'],
                    '第 ${(_asInt(value['chapterIdx']) ?? 0) + 1} 章',
                  ]),
                  content: '',
                  remoteUid: _asInt(value['chapterUid']),
                  isLoaded: false,
                ),
              ),
            )
            .where(
              (value) => value.wordCount > 0 || value.chapter.title != '封面',
            )
            .toList()
          ..sort((a, b) => a.index.compareTo(b.index));
    if (chapters.isEmpty) {
      throw const WeReadException('这本书暂时没有可读取的文字章节');
    }
    return WeReadCatalog(
      title: _firstText([
        info['title'],
        nestedBook['title'],
      ], fallback: '未命名书籍'),
      author: _firstText([
        info['author'],
        nestedBook['author'],
      ], fallback: '未知作者'),
      coverUrl: _firstNullableText([info['cover'], nestedBook['cover']]),
      format: _firstText([
        catalog['format'],
        nestedBook['format'],
        info['format'],
      ], fallback: 'epub').toLowerCase(),
      chapters: chapters.map((value) => value.chapter).toList(),
      progress:
          ((_asDouble(progressBook['progress'] ?? progressData['progress']) ??
                      0) /
                  100)
              .clamp(0, 1),
      currentChapterUid: _asInt(
        progressBook['chapterUid'] ?? progressData['chapterUid'],
      ),
    );
  }

  Future<String> loadChapter({
    required String bookId,
    required int chapterUid,
    String? format,
  }) async {
    await renewSession();
    final bookHash = wereadHashId(bookId);
    final chapterHash = wereadHashId(chapterUid);
    final reader = await _authenticatedRequest(
      'GET',
      '/web/reader/${bookHash}k$chapterHash',
    );
    final psvts = RegExp(
      r'"psvts"\s*:\s*"([^"\\]+)"',
    ).firstMatch(reader.body)?.group(1);
    if (psvts == null || psvts.isEmpty) {
      throw const WeReadException('无法初始化微信读书阅读会话，请重新登录后再试');
    }

    final preferTxt = format?.toLowerCase() == 'txt';
    if (preferTxt) {
      return _loadTxtChapter(bookId, chapterUid, psvts);
    }

    final first = await _chapterShard(
      suffix: 'e_0',
      bookId: bookId,
      chapterUid: chapterUid,
      psvts: psvts,
    );
    if (first.trimLeft().startsWith('{')) {
      return _loadTxtChapter(bookId, chapterUid, psvts);
    }
    final second = await _chapterShard(
      suffix: 'e_1',
      bookId: bookId,
      chapterUid: chapterUid,
      psvts: psvts,
    );
    final third = await _chapterShard(
      suffix: 'e_3',
      bookId: bookId,
      chapterUid: chapterUid,
      psvts: psvts,
    );
    final decoded = decodeWeReadPayload(
      '${_verifiedShard(first)}${_verifiedShard(second)}${_verifiedShard(third)}',
    );
    return wereadHtmlToText(decoded);
  }

  Future<String> _loadTxtChapter(
    String bookId,
    int chapterUid,
    String psvts,
  ) async {
    final first = await _chapterShard(
      suffix: 't_0',
      bookId: bookId,
      chapterUid: chapterUid,
      psvts: psvts,
    );
    final second = await _chapterShard(
      suffix: 't_1',
      bookId: bookId,
      chapterUid: chapterUid,
      psvts: psvts,
    );
    final decoded = decodeWeReadPayload(
      '${_verifiedShard(first)}${_verifiedShard(second)}',
    );
    return wereadHtmlToText(decoded);
  }

  Future<String> _chapterShard({
    required String suffix,
    required String bookId,
    required int chapterUid,
    required String psvts,
  }) async {
    final ct = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final payload = <String, Object?>{
      'b': wereadHashId(bookId),
      'c': wereadHashId(chapterUid),
      'r': pow(_random.nextInt(10000), 2).toInt(),
      'ct': ct,
      'ps': psvts,
      'pc': wereadHashId(ct),
      'sc': 1,
      'prevChapter': false,
      'st': suffix == 'e_2' ? 1 : 0,
    };
    payload['s'] = wereadSignPayload(payload);
    final response = await _authenticatedRequest(
      'POST',
      '/web/book/chapter/$suffix',
      body: payload,
    );
    if (response.body.trimLeft().startsWith('{')) {
      final data = _decodeMap(response.body);
      final code = _asInt(data['errCode']);
      if (code != null && code != 0) _throwForApiError(data);
    }
    return response.body;
  }

  Future<void> renewSession() async {
    final response = await _authenticatedRequest(
      'POST',
      '/web/login/renewal',
      body: {'rq': '%2Fweb%2Fbook%2Fread', 'ql': false},
    );
    final data = _decodeMap(response.body);
    if (_asInt(data['succ']) != 1) {
      _throwForApiError(data);
      throw const WeReadException('微信读书登录续期失败，请重新登录');
    }
  }

  Book? _bookFromShelfItem(Object? raw) {
    final item = _asMap(raw);
    final nested = _asMap(item['book']);
    final data = nested.isEmpty ? item : nested;
    final remoteId = _firstNullableText([data['bookId'], item['bookId']]);
    if (remoteId == null || remoteId.isEmpty) return null;
    final progressValue = _asDouble(
      item['readingProgress'] ?? data['progress'] ?? item['progress'],
    );
    final finished =
        _asInt(data['finishReading'] ?? item['finishReading']) == 1;
    final progress = finished
        ? 1.0
        : ((progressValue ?? 0) > 1
              ? (progressValue ?? 0) / 100
              : (progressValue ?? 0));
    final timestamp = _asInt(
      data['readUpdateTime'] ?? item['readUpdateTime'] ?? item['sort'],
    );
    return Book(
      id: 'weread:$remoteId',
      title: _firstText([data['title'], item['title']], fallback: '未命名书籍'),
      author: _firstText([data['author'], item['author']], fallback: '未知作者'),
      format: BookFormat.epub,
      coverColor: _coverColor(remoteId),
      coverUrl: _firstNullableText([data['cover'], item['cover']]),
      chapters: const [],
      source: BookSource.weread,
      remoteId: remoteId,
      remoteFormat: _firstNullableText([data['format'], item['format']]),
      progress: progress.clamp(0, 1),
      lastOpenedAt: timestamp == null || timestamp <= 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(timestamp * 1000),
    );
  }

  Future<_WeReadResponse> _authenticatedRequest(
    String method,
    String path, {
    Map<String, Object?>? query,
    Map<String, Object?>? body,
  }) async {
    final cookies = await credentials.readCookies();
    if (cookies['wr_vid']?.isEmpty ?? true) {
      throw const WeReadException('请先登录微信读书');
    }
    final response = await _request(
      method,
      path,
      query: query,
      body: body,
      cookies: cookies,
    );
    await credentials.writeCookies(cookies);
    return response;
  }

  Future<_WeReadResponse> _request(
    String method,
    String path, {
    Map<String, Object?>? query,
    Map<String, Object?>? body,
    bool auth = true,
    Map<String, String>? cookies,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final client = _clientFactory()..connectionTimeout = timeout;
    try {
      final uri = Uri.parse('$_wereadBaseUrl$path').replace(
        queryParameters: query?.map(
          (key, value) => MapEntry(key, value.toString()),
        ),
      );
      final request = await client.openUrl(method, uri).timeout(timeout);
      request.headers
        ..set(HttpHeaders.userAgentHeader, _wereadUserAgent)
        ..set(HttpHeaders.acceptHeader, 'application/json, text/plain, */*')
        ..set('Origin', _wereadBaseUrl)
        ..set(HttpHeaders.refererHeader, '$_wereadBaseUrl/');
      final jar =
          cookies ??
          (auth ? await credentials.readCookies() : <String, String>{});
      if (jar.isNotEmpty) {
        request.headers.set(
          HttpHeaders.cookieHeader,
          jar.entries.map((entry) => '${entry.key}=${entry.value}').join('; '),
        );
      }
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(timeout);
      final responseBody = await utf8.decoder
          .bind(response)
          .join()
          .timeout(timeout);
      for (final cookie in response.cookies) {
        jar[cookie.name] = cookie.value;
      }
      if (auth && cookies == null && jar.isNotEmpty) {
        await credentials.writeCookies(jar);
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw WeReadException('微信读书请求失败（${response.statusCode}）');
      }
      return _WeReadResponse(responseBody);
    } on WeReadException {
      rethrow;
    } on TimeoutException {
      rethrow;
    } on SocketException {
      throw const WeReadException('无法连接微信读书，请检查网络后重试');
    } on HandshakeException {
      throw const WeReadException('微信读书安全连接失败，请稍后重试');
    } finally {
      client.close(force: true);
    }
  }
}

class _WeReadResponse {
  const _WeReadResponse(this.body);
  final String body;
}

WeReadLoginPoll parseWeReadLoginPoll(Map<String, Object?> root) {
  var payload = root;
  for (var depth = 0; depth < 4; depth++) {
    if (payload.keys.any(
      const {
        'succeed',
        'logicCode',
        'accessToken',
        'webLoginVid',
        'vid',
      }.contains,
    )) {
      break;
    }
    final nested = [
      payload['data'],
      payload['result'],
      payload['loginInfo'],
    ].whereType<Map>().firstOrNull;
    if (nested == null) break;
    payload = nested.cast<String, Object?>();
  }

  final logicCode = payload['logicCode']?.toString().toUpperCase();
  final vid = _firstNullableText([
    payload['webLoginVid'],
    payload['vid'],
    payload['userVid'],
  ]);
  final accessToken = _firstNullableText([
    payload['accessToken'],
    payload['skey'],
  ]);
  final refreshToken = _firstNullableText([
    payload['refreshToken'],
    payload['rt'],
  ]);
  final succeeded =
      payload['succeed'] == true ||
      payload['success'] == true ||
      (vid != null && accessToken != null);
  final state = succeeded
      ? WeReadLoginState.success
      : switch (logicCode) {
          'NEED_OTP' => WeReadLoginState.needsOtp,
          'OTP_EXPIRED' => WeReadLoginState.otpExpired,
          'OTP_NOT_MATCH' => WeReadLoginState.otpNotMatch,
          'LOGIN_TIMEOUT' => WeReadLoginState.expired,
          _ => WeReadLoginState.waiting,
        };
  return WeReadLoginPoll(
    state: state,
    payload: payload,
    vid: vid,
    accessToken: accessToken,
    refreshToken: refreshToken,
  );
}

String wereadHashId(Object value) {
  final data = value.toString();
  final dataMd5 = md5.convert(utf8.encode(data)).toString();
  var result =
      '${dataMd5.substring(0, 3)}${RegExp(r'^\d+$').hasMatch(data) ? '3' : '4'}2${dataMd5.substring(30)}';
  final chunks = RegExp(r'^\d+$').hasMatch(data)
      ? [
          for (var index = 0; index < data.length; index += 9)
            int.parse(
              data.substring(index, min(index + 9, data.length)),
            ).toRadixString(16),
        ]
      : [data.codeUnits.map((value) => value.toRadixString(16)).join()];
  for (var index = 0; index < chunks.length; index++) {
    final chunk = chunks[index];
    result += chunk.length.toRadixString(16).padLeft(2, '0') + chunk;
    if (index < chunks.length - 1) result += 'g';
  }
  if (result.length < 20) {
    result += dataMd5.substring(0, 20 - result.length);
  }
  return result + md5.convert(utf8.encode(result)).toString().substring(0, 3);
}

String wereadSignPayload(Map<String, Object?> data) {
  final keys = data.keys.toList()..sort();
  final raw = keys
      .map((key) => '$key=${Uri.encodeQueryComponent(data[key].toString())}')
      .join('&');
  var first = 0x15051505;
  var second = 0x15051505;
  for (var index = raw.length - 1; index > 0; index -= 2) {
    first =
        0x7fffffff &
        (first ^ (raw.codeUnitAt(index) << ((raw.length - index) % 30)));
    second =
        0x7fffffff & (second ^ (raw.codeUnitAt(index - 1) << (index % 30)));
  }
  return (first + second).toRadixString(16).toLowerCase();
}

String decodeWeReadPayload(String data) {
  if (data.length <= 1) return '';
  final chars = data.substring(1).split('');
  final length = chars.length;
  final positions = <int>[];
  if (length >= 4 && length < 11) {
    positions.addAll([0, 2]);
  } else if (length >= 11) {
    final tailLength = min(4, (length / 10).ceil());
    final bits = StringBuffer();
    for (var index = length - 1; index >= length - tailLength; index--) {
      final binary = chars[index].codeUnitAt(0).toRadixString(2);
      bits.write(int.parse(binary, radix: 4));
    }
    final modulus = length - tailLength - 2;
    final digitLength = modulus.toString().length;
    final bitString = bits.toString();
    var index = 0;
    while (positions.length < 10 && index + digitLength < bitString.length) {
      positions.add(
        int.parse(bitString.substring(index, index + digitLength)) % modulus,
      );
      positions.add(
        int.parse(bitString.substring(index + 1, index + 1 + digitLength)) %
            modulus,
      );
      index += digitLength;
    }
  }
  for (var index = positions.length - 1; index >= 1; index -= 2) {
    for (var offset = 1; offset >= 0; offset--) {
      final first = positions[index] + offset;
      final second = positions[index - 1] + offset;
      if (first >= chars.length || second >= chars.length) continue;
      final value = chars[first];
      chars[first] = chars[second];
      chars[second] = value;
    }
  }
  try {
    return utf8.decode(
      base64Url.decode(base64Url.normalize(chars.join())),
      allowMalformed: true,
    );
  } catch (_) {
    throw const WeReadException('微信读书章节解码失败，接口可能已经更新');
  }
}

String wereadHtmlToText(String source) {
  final withBreaks = source
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</p\s*>', caseSensitive: false), '\n\n')
      .replaceAll(RegExp(r'</h[1-6]\s*>', caseSensitive: false), '\n\n');
  final document = html_parser.parse(withBreaks);
  for (final element in document.querySelectorAll('script,style,noscript')) {
    element.remove();
  }
  return (document.body?.text ?? document.documentElement?.text ?? '')
      .replaceAll('\u00a0', ' ')
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .replaceAll(RegExp(r' *\n *'), '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

String _verifiedShard(String value) {
  if (value.length <= 32) {
    throw const WeReadException('微信读书没有返回完整章节，可能尚未购买或会员已过期');
  }
  final header = value.substring(0, 32);
  final body = value.substring(32);
  final digest = md5.convert(utf8.encode(body)).toString().toUpperCase();
  if (digest != header.toUpperCase()) {
    throw const WeReadException('微信读书章节校验失败，请稍后重试');
  }
  return body;
}

Map<String, Object?> _decodeMap(String raw) {
  try {
    return (jsonDecode(raw) as Map).cast<String, Object?>();
  } catch (_) {
    throw const WeReadException('微信读书返回了无法识别的数据');
  }
}

Map<String, Object?> _unwrapData(Map<String, Object?> value) {
  final data = value['data'];
  return data is Map ? data.cast<String, Object?>() : value;
}

Map<String, Object?> _asMap(Object? value) =>
    value is Map ? value.cast<String, Object?>() : <String, Object?>{};

List<Object?> _asList(Object? value) => value is List ? value : const [];

int? _asInt(Object? value) => switch (value) {
  int number => number,
  num number => number.toInt(),
  String text => int.tryParse(text),
  _ => null,
};

double? _asDouble(Object? value) => switch (value) {
  num number => number.toDouble(),
  String text => double.tryParse(text),
  _ => null,
};

String _firstText(List<Object?> values, {String fallback = ''}) =>
    _firstNullableText(values) ?? fallback;

String? _firstNullableText(List<Object?> values) {
  for (final value in values) {
    final text = value?.toString().trim();
    if (text != null && text.isNotEmpty) return text;
  }
  return null;
}

void _throwForApiError(Map<String, Object?> data) {
  final code = _asInt(data['errCode'] ?? data['errcode']);
  if (code == null || code == 0) return;
  final message = _firstText([
    data['errMsg'],
    data['errmsg'],
  ], fallback: '请求失败');
  if (code == -2012 || code == -2010) {
    throw const WeReadException('微信读书登录已过期，请退出后重新扫码');
  }
  throw WeReadException('微信读书：$message（$code）');
}

int _coverColor(String value) {
  const colors = [0xFF3F5B4E, 0xFF7A4B3A, 0xFF394E68, 0xFF6B5A39, 0xFF57466B];
  final hash = value.codeUnits.fold<int>(0, (sum, unit) => sum + unit);
  return colors[hash % colors.length];
}
