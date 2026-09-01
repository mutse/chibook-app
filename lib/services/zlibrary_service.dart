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
    final extension = (json['extension'] as String? ?? '').toLowerCase();
    final format = BookFormat.values
        .where((value) => value.name == extension)
        .firstOrNull;
    if (format == null) {
      throw const FormatException('不支持的电子书格式');
    }
    return ZLibraryBook(
      id: '${json['id'] ?? ''}',
      hash: json['hash'] as String? ?? '',
      title: json['title'] as String? ?? '未命名书籍',
      author: json['author'] as String? ?? '未知作者',
      format: format,
      year: '${json['year'] ?? ''}',
      language: json['language'] as String? ?? '',
      fileSize: json['filesize'] as String? ?? '',
      coverUrl: _httpsUrl(json['cover']),
    );
  }
}

class ZLibraryService {
  ZLibraryService({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _domains = ['z-library.ec', 'z-library.sk', '1lib.sk'];
  static const _domainKey = 'erdu.zlibrary.domain';
  static const _userIdKey = 'erdu.zlibrary.user_id';
  static const _userKeyKey = 'erdu.zlibrary.user_key';
  static const _nameKey = 'erdu.zlibrary.name';
  static const _emailKey = 'erdu.zlibrary.email';
  static const _uuid = Uuid();
  static const _userAgent =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';

  final FlutterSecureStorage _storage;
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);

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
    final books = payload['books'] as List<Object?>? ?? const [];
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
      _addHeaders(request, authenticated: false);
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
          followRedirects: false,
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
    bool followRedirects = true,
  }) async {
    final uri = Uri.https(domain, path);
    final request = method == 'POST'
        ? await _client.postUrl(uri).timeout(const Duration(seconds: 10))
        : await _client.getUrl(uri).timeout(const Duration(seconds: 10));
    _addHeaders(request, authenticated: authenticated);
    request.followRedirects = followRedirects;
    if (method == 'POST') {
      request.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
      );
      final entries = formEntries ?? form?.entries.toList() ?? const [];
      request.write(
        entries
            .map(
              (entry) =>
                  '${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(entry.value)}',
            )
            .join('&'),
      );
    }
    final response = await request.close().timeout(const Duration(seconds: 30));
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

  void _addHeaders(HttpClientRequest request, {required bool authenticated}) {
    request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
    request.headers.set(
      HttpHeaders.acceptHeader,
      'application/json, text/plain, */*',
    );
    final cookies = <String>['siteLanguageV2=en'];
    if (authenticated) {
      _requireSession();
      request.headers.set('remix-userid', _userId!);
      request.headers.set('remix-userkey', _userKey!);
      cookies.add('remix_userid=$_userId');
      cookies.add('remix_userkey=$_userKey');
    }
    request.headers.set(HttpHeaders.cookieHeader, cookies.join('; '));
  }

  void _requireSession() {
    if (_userId?.isEmpty != false || _userKey?.isEmpty != false) {
      throw const ZLibraryException('请先登录 Z-Library');
    }
  }
}

Map<String, Object?> _map(Object? value) =>
    value is Map ? value.cast<String, Object?>() : const {};

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
