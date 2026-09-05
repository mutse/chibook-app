import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chibook/services/weread_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:test/test.dart';

void main() {
  late _FakeStorage storage;
  late _FakeHttpClient http;
  late WeReadService service;

  setUp(() async {
    storage = _FakeStorage();
    http = _FakeHttpClient();
    service = WeReadService(
      credentials: WeReadCredentialStore(storage: storage),
      clientFactory: () => http,
    );
    await storage.write(
      key: 'erdu.weread.cookie.v1',
      value: jsonEncode({'wr_vid': '42', 'wr_skey': 'old', 'wr_rt': 'rt'}),
    );
  });

  Future<Map<String, String>> cookies() async =>
      (jsonDecode((await storage.read(key: 'erdu.weread.cookie.v1'))!) as Map)
          .cast<String, String>();

  test(
    'expired session key is renewed through wr_rt and the call retried',
    () async {
      http.enqueue('/web/shelf/sync', body: '{"errCode":-2012,"errMsg":"x"}');
      http.enqueue(
        '/web/login/renewal',
        body: '{"succ":1,"accessToken":"fresh","refreshToken":"rt2"}',
      );
      http.enqueue(
        '/web/shelf/sync',
        body: '{"books":[{"bookId":"1","title":"书","author":"人"}]}',
      );

      final books = await service.syncShelf();

      expect(books.map((book) => book.remoteId), ['1']);
      expect(http.paths, [
        '/web/shelf/sync',
        '/web/login/renewal',
        '/web/shelf/sync',
      ]);
      final jar = await cookies();
      expect(jar['wr_skey'], 'fresh');
      expect(jar['wr_rt'], 'rt2');
      expect(http.sentCookies.last, contains('wr_skey=fresh'));
    },
  );

  test(
    'HTTP 401 also triggers renewal and Set-Cookie tokens are kept',
    () async {
      http.enqueue('/web/shelf/sync', status: 401, body: '{"errCode":-2010}');
      http.enqueue(
        '/web/login/renewal',
        body: '{"succ":1}',
        cookies: [Cookie('wr_skey', 'from-cookie')],
      );
      http.enqueue('/web/shelf/sync', body: '{"books":[]}');

      await service.syncShelf();

      expect((await cookies())['wr_skey'], 'from-cookie');
    },
  );

  test('user only sees the expiry error when renewal itself fails', () async {
    http.enqueue('/web/shelf/sync', body: '{"errCode":-2012}');
    http.enqueue('/web/login/renewal', body: '{"succ":0,"errCode":-2012}');

    await expectLater(
      service.syncShelf(),
      throwsA(isA<WeReadSessionExpiredException>()),
    );
    expect(http.paths, ['/web/shelf/sync', '/web/login/renewal']);
    // The refresh token must survive so a later attempt can still renew.
    expect((await cookies())['wr_rt'], 'rt');
  });

  test('deletion cookies never wipe stored tokens', () async {
    http.enqueue(
      '/web/shelf/sync',
      body: '{"books":[]}',
      cookies: [
        Cookie('wr_rt', '')..maxAge = 0,
        Cookie('wr_skey', 'x')
          ..expires = DateTime.now().subtract(const Duration(days: 1)),
      ],
    );

    await service.syncShelf();

    final jar = await cookies();
    expect(jar['wr_rt'], 'rt');
    expect(jar['wr_skey'], 'old');
  });

  test('proactive renewal is throttled and never throws', () async {
    http.enqueue('/web/login/renewal', body: '{"succ":1}');

    await service.renewSession();
    await service.renewSession();
    expect(http.paths, ['/web/login/renewal']);

    http.paths.clear();
    final failing = WeReadService(
      credentials: WeReadCredentialStore(storage: storage),
      clientFactory: () => http,
    );
    http.enqueue('/web/login/renewal', status: 500, body: 'boom');
    await failing.renewSession();
  });
}

class _FakeStorage implements FlutterSecureStorage {
  final Map<String, String> _values = {};

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _values[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _values.remove(key);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _Canned {
  _Canned(this.path, this.status, this.body, this.cookies);
  final String path;
  final int status;
  final String body;
  final List<Cookie> cookies;
}

class _FakeHttpClient implements HttpClient {
  final List<_Canned> _queue = [];
  final List<String> paths = [];
  final List<String> sentCookies = [];

  void enqueue(
    String path, {
    int status = 200,
    required String body,
    List<Cookie> cookies = const [],
  }) => _queue.add(_Canned(path, status, body, cookies));

  @override
  set connectionTimeout(Duration? value) {}

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    if (_queue.isEmpty) fail('unexpected request ${url.path}');
    final next = _queue.removeAt(0);
    if (next.path != url.path) {
      fail('expected ${next.path} but got ${url.path}');
    }
    paths.add(url.path);
    return _FakeRequest(next, sentCookies);
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this._canned, this._sentCookies);
  final _Canned _canned;
  final List<String> _sentCookies;
  @override
  final HttpHeaders headers = _FakeHeaders();

  @override
  void write(Object? object) {}

  @override
  Future<HttpClientResponse> close() async {
    _sentCookies.add(headers.value(HttpHeaders.cookieHeader) ?? '');
    return _FakeResponse(_canned);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _FakeHeaders implements HttpHeaders {
  final Map<String, String> _values = {};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      _values[name.toLowerCase()] = value.toString();

  @override
  String? value(String name) => _values[name.toLowerCase()];

  @override
  set contentType(ContentType? value) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  _FakeResponse(this._canned);
  final _Canned _canned;

  @override
  int get statusCode => _canned.status;

  @override
  List<Cookie> get cookies => _canned.cookies;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(utf8.encode(_canned.body)).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
