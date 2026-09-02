import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../core/models.dart';

class ZLibraryException implements Exception {
  const ZLibraryException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ZLibraryAccount {
  const ZLibraryAccount({required this.name, required this.email});

  final String name;
  final String email;
}

class ZLibraryBook {
  const ZLibraryBook({
    required this.id,
    required this.hash,
    required this.title,
    required this.author,
    required this.format,
    this.year = '',
    this.language = '',
    this.fileSize = '',
    this.coverUrl,
  });

  final String id;
  final String hash;
  final String title;
  final String author;
  final BookFormat format;
  final String year;
  final String language;
  final String fileSize;
  final String? coverUrl;

  factory ZLibraryBook.fromJson(Map<String, Object?> json) {
    final extension = _text(json['extension']).toLowerCase();
    final format = BookFormat.values
        .where((value) => value.name == extension)
        .firstOrNull;
    if (format == null) {
      throw const FormatException('不支持的电子书格式');
    }
    final title = _text(json['title']);
    final author = _text(json['author']);
    return ZLibraryBook(
      id: _text(json['id']),
      hash: _text(json['hash']),
      title: title.isEmpty ? '未命名书籍' : title,
      author: author.isEmpty ? '未知作者' : author,
      format: format,
      year: _text(json['year']),
      language: _text(json['language']),
      // The search API sends `filesize` as a byte count and `filesizeString`
      // as the label the tile shows; never cast either one, the numbers arrive
      // as JSON ints and a failed cast would drop the whole result.
      fileSize: _fileSizeLabel(json['filesizeString'], json['filesize']),
      coverUrl: _httpsUrl(json['cover']),
    );
  }
}

/// Decodes a `/eapi/book/search` payload into the books this app can open.
///
/// Entries that are malformed, unidentifiable, or in a format the readers do
/// not support are skipped rather than failing the whole search.
List<ZLibraryBook> parseZLibrarySearchResults(Map<String, Object?> payload) {
  final books = payload['books'];
  if (books is! List) return const [];
  return books
      .whereType<Map>()
      .map((item) {
        try {
          return ZLibraryBook.fromJson(item.cast<String, Object?>());
        } catch (_) {
          return null;
        }
      })
      .whereType<ZLibraryBook>()
      .where((book) => book.id.isNotEmpty && book.hash.isNotEmpty)
      .toList();
}

class ZLibraryService {
  ZLibraryService({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _domains = [
    'z-library.ec',
    'z-library.sk',
    'zh.z-library.sk',
    '1lib.sk',
  ];
  static const _domainKey = 'erdu.zlibrary.domain';
  static const _userIdKey = 'erdu.zlibrary.user_id';
  static const _userKeyKey = 'erdu.zlibrary.user_key';
  static const _nameKey = 'erdu.zlibrary.name';
  static const _emailKey = 'erdu.zlibrary.email';
  static const _uuid = Uuid();
  static const _maxRedirects = 3;
  static const _userAgent =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';

  final FlutterSecureStorage _storage;
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);

  /// Challenge cookies handed out by the anti-bot layer, kept per host so a
  /// mirror's cookie is never replayed to a different one.
  final Map<String, Map<String, String>> _cookieJar = {};

  String? _domain;
  String? _userId;
  String? _userKey;

  Future<ZLibraryAccount?> restoreAccount() async {
    final values = await Future.wait([
      _storage.read(key: _domainKey),
      _storage.read(key: _userIdKey),
      _storage.read(key: _userKeyKey),
      _storage.read(key: _nameKey),
      _storage.read(key: _emailKey),
    ]);
    if (values[0]?.isEmpty != false ||
        values[1]?.isEmpty != false ||
        values[2]?.isEmpty != false) {
      return null;
    }
    _domain = values[0];
    _userId = values[1];
    _userKey = values[2];
    return ZLibraryAccount(name: values[3] ?? '', email: values[4] ?? '');
  }

  Future<ZLibraryAccount> login({
    required String email,
    required String password,
  }) async {
    if (email.trim().isEmpty || password.isEmpty) {
      throw const ZLibraryException('请输入邮箱和密码');
    }
    final domain = await _resolveDomain();
    final payload = await _requestJson(
      domain: domain,
      method: 'POST',
      path: '/eapi/user/login',
      form: {'email': email.trim(), 'password': password},
      authenticated: false,
    );
    if (!_isSuccess(payload)) {
      throw ZLibraryException(
        _errorMessage(payload, fallback: 'Z-Library 登录失败'),
      );
    }
    final user = _map(payload['user']);
    final userId = '${user['id'] ?? ''}';
    final userKey = user['remix_userkey'] as String? ?? '';
    if (userId.isEmpty || userKey.isEmpty) {
      throw const ZLibraryException('登录响应缺少会话凭证');
    }
    final account = ZLibraryAccount(
      name: user['name'] as String? ?? email.trim(),
      email: user['email'] as String? ?? email.trim(),
    );
    _domain = domain;
    _userId = userId;
    _userKey = userKey;
    await Future.wait([
      _storage.write(key: _domainKey, value: domain),
      _storage.write(key: _userIdKey, value: userId),
      _storage.write(key: _userKeyKey, value: userKey),
      _storage.write(key: _nameKey, value: account.name),
      _storage.write(key: _emailKey, value: account.email),
    ]);
    return account;
  }

  Future<void> logout() async {
    _domain = null;
    _userId = null;
    _userKey = null;
    await Future.wait([
      _storage.delete(key: _domainKey),
      _storage.delete(key: _userIdKey),
      _storage.delete(key: _userKeyKey),
      _storage.delete(key: _nameKey),
      _storage.delete(key: _emailKey),
    ]);
  }

  Future<List<ZLibraryBook>> search(String query) async {
    _requireSession();
    final value = query.trim();
    if (value.isEmpty) return const [];
    final payload = await _authenticatedJson(
      method: 'POST',
      path: '/eapi/book/search',
      formEntries: [
        MapEntry('message', value),
        const MapEntry('page', '1'),
        const MapEntry('limit', '20'),
        for (final format in BookFormat.values)
          MapEntry('extensions[]', format.name),
      ],
    );
    if (!_isSuccess(payload)) {
      throw ZLibraryException(_errorMessage(payload, fallback: '搜索失败，请稍后重试'));
    }
    return parseZLibrarySearchResults(payload);
  }

  Future<String> download(ZLibraryBook book) async {
    _requireSession();
    final payload = await _authenticatedJson(
      method: 'GET',
      path:
          '/eapi/book/${Uri.encodeComponent(book.id)}/${Uri.encodeComponent(book.hash)}/file',
    );
    if (!_isSuccess(payload)) {
      throw ZLibraryException(_errorMessage(payload, fallback: '无法获取下载地址'));
    }
    final file = _map(payload['file']);
    final rawLink =
        file['downloadLink'] ??
        payload['downloadLink'] ??
        payload['url'] ??
        payload['link'];
    if (rawLink is! String || rawLink.isEmpty) {
      throw const ZLibraryException('服务未返回可用的下载地址');
    }
    final base = Uri.https(_domain!, '');
    final uri = base.resolve(rawLink);
    if (uri.scheme != 'https') {
      throw const ZLibraryException('下载地址不是安全的 HTTPS 链接');
    }

    final temporary = await getTemporaryDirectory();
    final target = File(
      '${temporary.path}/zlibrary-${_uuid.v4()}.${book.format.name}',
    );
    final staging = File('${target.path}.part');
    try {
      final request = await _client
          .getUrl(uri)
          .timeout(const Duration(seconds: 15));
      // The EAPI returns a signed CDN URL. Do not leak account tokens to that
      // third-party host; the signed URL itself authorizes this transfer.
      _addHeaders(request, host: uri.host, authenticated: false);
      request.followRedirects = true;
      request.maxRedirects = 5;
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.drain<void>();
        throw ZLibraryException('下载失败（HTTP ${response.statusCode}）');
      }
      final contentType = response.headers.contentType?.mimeType.toLowerCase();
      if (contentType == 'text/html' || contentType == 'application/json') {
        await response.drain<void>();
        throw const ZLibraryException('下载地址返回了网页而不是电子书文件');
      }
      const maximumBytes = 500 * 1024 * 1024;
      if (response.contentLength > maximumBytes) {
        await response.drain<void>();
        throw const ZLibraryException('文件超过 500 MB，已取消下载');
      }
      final sink = staging.openWrite();
      var received = 0;
      try {
        await for (final chunk in response) {
          received += chunk.length;
          if (received > maximumBytes) {
            throw const ZLibraryException('文件超过 500 MB，已取消下载');
          }
          sink.add(chunk);
        }
      } finally {
        await sink.close();
      }
      if (!await staging.exists() || await staging.length() == 0) {
        throw const ZLibraryException('下载得到的文件为空');
      }
      await staging.rename(target.path);
      return target.path;
    } catch (_) {
      if (await staging.exists()) await staging.delete();
      if (await target.exists()) await target.delete();
      rethrow;
    }
  }

  Future<Map<String, Object?>> _authenticatedJson({
    required String method,
    required String path,
    List<MapEntry<String, String>>? formEntries,
  }) async {
    final candidates = <String>[
      ?_domain,
      ..._domains.where((value) => value != _domain),
    ];
    Object? lastError;
    for (final domain in candidates) {
      try {
        final result = await _requestJson(
          domain: domain,
          method: method,
          path: path,
          formEntries: formEntries,
        );
        _domain = domain;
        await _storage.write(key: _domainKey, value: domain);
        return result;
      } catch (error) {
        lastError = error;
      }
    }
    throw ZLibraryException('无法连接 Z-Library：${lastError ?? '网络不可用'}');
  }

  Future<String> _resolveDomain() async {
    for (final domain in _domains) {
      try {
        final payload = await _requestJson(
          domain: domain,
          method: 'GET',
          path: '/eapi/info/domains',
          authenticated: false,
        );
        if (payload.containsKey('domains')) return domain;
      } catch (_) {
        // Try the next advertised endpoint without consuming a login attempt.
      }
    }
    throw const ZLibraryException('当前无法连接 Z-Library，请稍后重试');
  }

  Future<Map<String, Object?>> _requestJson({
    required String domain,
    required String method,
    required String path,
    Map<String, String>? form,
    List<MapEntry<String, String>>? formEntries,
    bool authenticated = true,
  }) async {
    final response = await _send(
      uri: Uri.https(domain, path),
      method: method,
      body: method == 'POST'
          ? _encodeForm(formEntries ?? form?.entries.toList() ?? const [])
          : null,
      authenticated: authenticated,
    );
    final body = await utf8.decoder.bind(response).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ZLibraryException('服务返回 HTTP ${response.statusCode}');
    }
    try {
      return _map(jsonDecode(body));
    } catch (_) {
      throw const ZLibraryException('服务返回了无法识别的内容');
    }
  }

  /// Sends one API call, following same-host redirects by hand.
  ///
  /// `HttpClient` never auto-follows a redirect for POST and keeps no cookie
  /// jar, while the anti-bot layer in front of several mirrors answers the
  /// first call with a 307 back to the same URL plus a cookie that has to be
  /// replayed. Without both pieces every search against those mirrors fails.
  Future<HttpClientResponse> _send({
    required Uri uri,
    required String method,
    required String? body,
    required bool authenticated,
  }) async {
    var target = uri;
    var verb = method;
    var payload = body;
    for (var hop = 0; hop <= _maxRedirects; hop++) {
      final request = verb == 'POST'
          ? await _client.postUrl(target).timeout(const Duration(seconds: 10))
          : await _client.getUrl(target).timeout(const Duration(seconds: 10));
      _addHeaders(request, host: target.host, authenticated: authenticated);
      request.followRedirects = false;
      // The anti-bot layer answers before reading the POST body, which leaves
      // the pooled connection out of sync. `_client` is shared for the whole
      // session, so reusing that socket would poison every later call to the
      // host; a fresh connection per request is cheap at this call volume.
      request.persistentConnection = false;
      if (verb == 'POST') {
        request.headers.contentType = ContentType(
          'application',
          'x-www-form-urlencoded',
        );
        request.write(payload ?? '');
      }
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      _storeCookies(target.host, response);
      final next = _redirectTarget(response, target);
      if (next == null) return response;
      await response.drain<void>();
      if (response.statusCode != HttpStatus.temporaryRedirect &&
          response.statusCode != HttpStatus.permanentRedirect) {
        verb = 'GET';
        payload = null;
      }
      target = next;
    }
    throw const ZLibraryException('服务重定向次数过多');
  }

  /// Resolves the hop a redirect points at, or null when the response should be
  /// treated as final. A redirect that leaves the host is refused on purpose:
  /// the mirrors bounce to one another and the session headers are host scoped,
  /// so following one would hand the account key to a different server.
  Uri? _redirectTarget(HttpClientResponse response, Uri from) {
    if (response.statusCode < 300 || response.statusCode >= 400) return null;
    final location = response.headers.value(HttpHeaders.locationHeader);
    if (location == null || location.isEmpty) return null;
    final target = from.resolve(location);
    if (target.scheme != 'https' || target.host != from.host) return null;
    return target;
  }

  void _storeCookies(String host, HttpClientResponse response) {
    final headers = response.headers[HttpHeaders.setCookieHeader];
    if (headers == null) return;
    // Parsed by hand rather than through `response.cookies`, which rejects the
    // loosely formatted attributes some mirrors send.
    final jar = _cookieJar.putIfAbsent(host, () => {});
    for (final header in headers) {
      final pair = header.split(';').first;
      final separator = pair.indexOf('=');
      if (separator <= 0) continue;
      final name = pair.substring(0, separator).trim();
      if (name.isEmpty) continue;
      jar[name] = pair.substring(separator + 1).trim();
    }
  }

  void _addHeaders(
    HttpClientRequest request, {
    required String host,
    required bool authenticated,
  }) {
    request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
    request.headers.set(
      HttpHeaders.acceptHeader,
      'application/json, text/plain, */*',
    );
    final cookies = <String, String>{
      'siteLanguageV2': 'en',
      ...?_cookieJar[host],
    };
    if (authenticated) {
      _requireSession();
      request.headers.set('remix-userid', _userId!);
      request.headers.set('remix-userkey', _userKey!);
      cookies['remix_userid'] = _userId!;
      cookies['remix_userkey'] = _userKey!;
    }
    request.headers.set(
      HttpHeaders.cookieHeader,
      cookies.entries.map((entry) => '${entry.key}=${entry.value}').join('; '),
    );
  }

  void _requireSession() {
    if (_userId?.isEmpty != false || _userKey?.isEmpty != false) {
      throw const ZLibraryException('请先登录 Z-Library');
    }
  }
}

Map<String, Object?> _map(Object? value) =>
    value is Map ? value.cast<String, Object?>() : const {};

/// Reads a JSON scalar as text without casting: the search API types the same
/// field as a string on one record and a number on the next.
String _text(Object? value) => switch (value) {
  String value => value.trim(),
  num() || bool() => '$value',
  _ => '',
};

String _fileSizeLabel(Object? label, Object? bytes) {
  final text = _text(label);
  if (text.isNotEmpty) return text;
  final raw = _text(bytes);
  if (raw.isEmpty) return '';
  final size = double.tryParse(raw);
  // Older payloads carried the readable label in `filesize` itself.
  if (size == null) return raw;
  if (size <= 0) return '';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = size;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  // Two decimals above bytes, matching the `filesizeString` the API sends for
  // most results so the two sources render alike in the list.
  return '${value.toStringAsFixed(unit == 0 ? 0 : 2)} ${units[unit]}';
}

String _encodeForm(List<MapEntry<String, String>> entries) => entries
    .map(
      (entry) =>
          '${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(entry.value)}',
    )
    .join('&');

bool _isSuccess(Map<String, Object?> payload) {
  final value = payload['success'];
  return value == null || value == true || value == 1 || value == '1';
}

String _errorMessage(Map<String, Object?> payload, {required String fallback}) {
  for (final key in const ['message', 'msg', 'error']) {
    final value = payload[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
  }
  return fallback;
}

String? _httpsUrl(Object? value) {
  if (value is! String || value.isEmpty) return null;
  final uri = Uri.tryParse(value);
  return uri?.scheme == 'https' ? value : null;
}
