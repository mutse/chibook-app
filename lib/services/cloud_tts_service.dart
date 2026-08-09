import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../core/models.dart';

class TtsCredentialStore {
  static const _openAiKey = 'erdu.tts.openai.api_key.v1';
  const TtsCredentialStore();

  static const _storage = FlutterSecureStorage();

  Future<String> readOpenAiKey() async =>
      (await _storage.read(key: _openAiKey)) ?? '';

  Future<void> writeOpenAiKey(String value) async {
    final key = value.trim();
    if (key.isEmpty) {
      await _storage.delete(key: _openAiKey);
    } else {
      await _storage.write(key: _openAiKey, value: key);
    }
  }
}

class CloudTtsException implements Exception {
  const CloudTtsException(this.message);
  final String message;

  @override
  String toString() => message;
}

class TextChunk {
  const TextChunk({required this.text, required this.start, required this.end});

  final String text;
  final int start;
  final int end;
}

class CloudTtsService {
  CloudTtsService({TtsCredentialStore? credentials})
    : _credentials = credentials ?? const TtsCredentialStore();

  static const defaultEndpoint = 'https://api.openai.com/v1';
  static const model = 'gpt-4o-mini-tts';
  final TtsCredentialStore _credentials;

  List<TextChunk> splitText(String text, {int maxCharacters = 1200}) {
    if (text.isEmpty) return const [];
    final chunks = <TextChunk>[];
    var start = 0;
    while (start < text.length) {
      var end = (start + maxCharacters).clamp(0, text.length);
      if (end < text.length) {
        final floor = start + (maxCharacters * .55).round();
        for (var i = end; i >= floor; i--) {
          if ('。！？；\n.!?;'.contains(text[i - 1])) {
            end = i;
            break;
          }
        }
      }
      chunks.add(
        TextChunk(text: text.substring(start, end), start: start, end: end),
      );
      start = end;
    }
    return chunks;
  }

  Future<void> validateOpenAi({
    required String apiKey,
    String endpoint = '',
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(
        Uri.parse('${_normalizeEndpoint(endpoint)}/models/$model'),
      );
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${apiKey.trim()}',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      final body = await utf8.decoder.bind(response).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw CloudTtsException(_errorMessage(response.statusCode, body));
      }
    } on CloudTtsException {
      rethrow;
    } on TimeoutException {
      throw const CloudTtsException('连接超时，请检查网络或 Endpoint');
    } catch (error) {
      throw CloudTtsException('无法连接 OpenAI：$error');
    } finally {
      client.close(force: true);
    }
  }

  Future<File> audioFor({
    required Book book,
    required int chapterIndex,
    required TextChunk chunk,
    required TtsSettings settings,
  }) async {
    final key = await _credentials.readOpenAiKey();
    if (key.isEmpty) {
      throw const CloudTtsException('请先在 TTS 设置中保存 OpenAI API Key');
    }
    final voice = openAiVoiceId(settings.voiceName);
    final digest = sha256
        .convert(utf8.encode('$model\u0000$voice\u0000${chunk.text}'))
        .toString();
    final root = await _cacheRoot();
    final directory = Directory('${root.path}/${_safe(book.id)}/$chapterIndex');
    await directory.create(recursive: true);
    final file = File(
      '${directory.path}/${voice}_${digest.substring(0, 24)}.mp3',
    );
    if (await file.exists() && await file.length() > 128) return file;

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    final partial = File('${file.path}.part');
    try {
      final request = await client.postUrl(
        Uri.parse('${_normalizeEndpoint(settings.endpoint)}/audio/speech'),
      );
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
      request.write(
        jsonEncode({
          'model': model,
          'voice': voice,
          'input': chunk.text,
          'instructions': '用自然、清晰、沉稳的普通话朗读，忠实保留原文语气。',
          'response_format': 'mp3',
        }),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 90),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = await utf8.decoder.bind(response).join();
        throw CloudTtsException(_errorMessage(response.statusCode, body));
      }
      await response.pipe(partial.openWrite());
      if (await partial.length() <= 128) {
        throw const CloudTtsException('云端返回的音频为空');
      }
      return partial.rename(file.path);
    } on CloudTtsException {
      if (await partial.exists()) await partial.delete();
      rethrow;
    } catch (error) {
      if (await partial.exists()) await partial.delete();
      throw CloudTtsException('生成云端语音失败：$error');
    } finally {
      client.close(force: true);
    }
  }

  Future<int> cacheSize({String? bookId}) async {
    final root = await _cacheRoot();
    final target = bookId == null
        ? root
        : Directory('${root.path}/${_safe(bookId)}');
    if (!await target.exists()) return 0;
    var bytes = 0;
    await for (final entity in target.list(recursive: true)) {
      if (entity is File && entity.path.endsWith('.mp3')) {
        bytes += await entity.length();
      }
    }
    return bytes;
  }

  Future<void> clearCache({String? bookId}) async {
    final root = await _cacheRoot();
    final target = bookId == null
        ? root
        : Directory('${root.path}/${_safe(bookId)}');
    if (await target.exists()) await target.delete(recursive: true);
  }

  Future<Directory> _cacheRoot() async {
    final support = await getApplicationSupportDirectory();
    final root = Directory('${support.path}/tts_cache');
    await root.create(recursive: true);
    return root;
  }

  String _normalizeEndpoint(String value) {
    final trimmed = value.trim();
    final endpoint = trimmed.isEmpty ? defaultEndpoint : trimmed;
    return endpoint.replaceFirst(RegExp(r'/+$'), '');
  }

  String _safe(String value) =>
      value.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');

  String _errorMessage(int status, String body) {
    try {
      final json = jsonDecode(body) as Map<String, Object?>;
      final error = json['error'] as Map?;
      final message = error?['message']?.toString();
      if (message != null && message.isNotEmpty) {
        return 'OpenAI ($status)：$message';
      }
    } catch (_) {}
    return 'OpenAI 请求失败（HTTP $status）';
  }
}

String openAiVoiceId(String name) {
  const ids = {
    'Marin': 'marin',
    'Cedar': 'cedar',
    'Coral': 'coral',
    'Alloy': 'alloy',
    'Ash': 'ash',
    'Ballad': 'ballad',
    'Echo': 'echo',
    'Fable': 'fable',
    'Nova': 'nova',
    'Onyx': 'onyx',
    'Sage': 'sage',
    'Shimmer': 'shimmer',
    'Verse': 'verse',
  };
  return ids[name] ?? 'marin';
}
