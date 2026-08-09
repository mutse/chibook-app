import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_state.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import '../../services/tts_audio_handler.dart';
import '../../services/cloud_tts_service.dart';

class TtsSettingsPage extends ConsumerStatefulWidget {
  const TtsSettingsPage({super.key});

  @override
  ConsumerState<TtsSettingsPage> createState() => _TtsSettingsPageState();
}

class _TtsSettingsPageState extends ConsumerState<TtsSettingsPage> {
  final _keyController = TextEditingController();
  final _endpointController = TextEditingController();
  final _previewTts = FlutterTts();
  late TtsSettings _draft;
  bool _initialized = false;
  bool _obscureKey = true;
  bool _testing = false;
  String? _status;
  String? _previewing;
  List<_VoiceOption> _voices = _fallbackVoices;
  final _credentials = const TtsCredentialStore();
  final _cloudTts = CloudTtsService();
  int _cacheBytes = 0;
  Map<String, int> _bookCacheBytes = const {};

  static const _fallbackVoices = <_VoiceOption>[
    _VoiceOption(name: '知性女声', locale: 'zh-CN'),
    _VoiceOption(name: '温润男声', locale: 'zh-CN'),
    _VoiceOption(name: '清亮少年音', locale: 'zh-CN'),
  ];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _draft = ref.read(appControllerProvider).ttsSettings;
    _endpointController.text = _draft.endpoint;
    _previewTts.setLanguage('zh-CN');
    _previewTts.setCompletionHandler(() {
      if (mounted) setState(() => _previewing = null);
    });
    _previewTts.setCancelHandler(() {
      if (mounted) setState(() => _previewing = null);
    });
    _loadApiKey();
    _refreshVoices();
    _loadCacheSize();
    _initialized = true;
  }

  @override
  void dispose() {
    _keyController.dispose();
    _endpointController.dispose();
    _previewTts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: IconButton(
        onPressed: () => context.pop(),
        icon: const Icon(Icons.arrow_back_ios_new, size: 18),
      ),
      title: const Text(
        'TTS API 设置',
        style: TextStyle(fontWeight: FontWeight.w800, fontSize: 19),
      ),
    ),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
      children: [
        const _SectionTitle('朗读引擎'),
        ...TtsProvider.values.map(
          (provider) => _ProviderCard(
            provider: provider,
            selected: _draft.provider == provider,
            enabled:
                provider == TtsProvider.builtin ||
                provider == TtsProvider.openai,
            onTap: () => _selectProvider(provider),
          ),
        ),
        if (_draft.isCloud) ...[
          const _SectionTitle('接口配置'),
          Card(
            elevation: 0,
            margin: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: Theme.of(context).dividerColor),
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _keyController,
                    obscureText: _obscureKey,
                    decoration: InputDecoration(
                      labelText: 'API Key',
                      hintText: '粘贴你的 API Key',
                      suffixIcon: IconButton(
                        onPressed: () =>
                            setState(() => _obscureKey = !_obscureKey),
                        icon: Icon(
                          _obscureKey ? Icons.visibility : Icons.visibility_off,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _endpointController,
                    decoration: InputDecoration(
                      labelText: '接入地区 / Endpoint',
                      hintText: _endpointHint(_draft.provider),
                    ),
                  ),
                  const SizedBox(height: 14),
                  FilledButton(
                    onPressed: _testing ? null : _validateConfiguration,
                    child: Text(_testing ? '正在检查…' : '验证配置'),
                  ),
                  if (_status != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _status!,
                      style: TextStyle(
                        color: _status!.startsWith('连接成功')
                            ? AppColors.bamboo
                            : AppColors.seal,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  const Text(
                    'OpenAI 语音由 AI 合成，并非真人录音。播放时会按段生成 MP3 并缓存在本机。',
                    style: TextStyle(color: AppColors.graphite, fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
        ],
        const _SectionTitle('发音人'),
        Card(
          elevation: 0,
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: _voices.map((voice) {
              final selected =
                  _draft.systemVoiceId == voice.id ||
                  (_draft.systemVoiceId == null &&
                      _draft.voiceName == voice.name);
              return ListTile(
                selected: selected,
                selectedTileColor: AppColors.bambooSoft,
                title: Text(
                  voice.name,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(voice.locale),
                trailing: _draft.provider == TtsProvider.builtin
                    ? OutlinedButton(
                        onPressed: () => _preview(voice),
                        child: Text(_previewing == voice.id ? '停止' : '试听'),
                      )
                    : const Icon(Icons.check_circle_outline),
                onTap: () => setState(
                  () => _draft = _draft.copyWith(
                    voiceName: voice.name,
                    systemVoiceId: voice.isSystem ? voice.id : null,
                    clearSystemVoiceId: !voice.isSystem,
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        const _SectionTitle('默认语速'),
        Wrap(
          spacing: 8,
          children: [.5, 1.0, 1.5, 2.0]
              .map(
                (speed) => ChoiceChip(
                  label: Text('${speed}x'),
                  selected: _draft.speed == speed,
                  onSelected: (_) =>
                      setState(() => _draft = _draft.copyWith(speed: speed)),
                  selectedColor: AppColors.bamboo,
                  labelStyle: TextStyle(
                    color: _draft.speed == speed ? Colors.white : null,
                  ),
                ),
              )
              .toList(),
        ),
        if (_draft.provider == TtsProvider.openai) ...[
          const _SectionTitle('云端音频缓存'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('已缓存音频'),
            subtitle: Text(_formatBytes(_cacheBytes)),
            trailing: TextButton(
              onPressed: _cacheBytes == 0 ? null : _clearCache,
              child: const Text('全部清理'),
            ),
          ),
          ...ref
              .watch(appControllerProvider)
              .books
              .where((book) => (_bookCacheBytes[book.id] ?? 0) > 0)
              .map(
                (book) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(book.title),
                  subtitle: Text(_formatBytes(_bookCacheBytes[book.id] ?? 0)),
                  trailing: IconButton(
                    tooltip: '清理本书缓存',
                    onPressed: () => _clearBookCache(book),
                    icon: const Icon(Icons.delete_outline),
                  ),
                ),
              ),
        ],
      ],
    ),
    bottomNavigationBar: SafeArea(
      minimum: const EdgeInsets.fromLTRB(18, 10, 18, 12),
      child: FilledButton(
        onPressed: _save,
        style: FilledButton.styleFrom(backgroundColor: AppColors.ink),
        child: const Text('保存设置'),
      ),
    ),
  );

  Future<void> _validateConfiguration() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _testing = true;
      _status = null;
    });
    final key = _keyController.text.trim();
    final endpoint = _endpointController.text.trim();
    if (key.isEmpty || endpoint.isEmpty) {
      setState(() {
        _testing = false;
        _status = '请填写 API Key 和 Endpoint';
      });
      return;
    }
    try {
      await _cloudTts.validateOpenAi(apiKey: key, endpoint: endpoint);
      if (mounted) setState(() => _status = '连接成功，配置可用');
    } catch (error) {
      if (mounted) setState(() => _status = error.toString());
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _loadApiKey() async {
    final key = await _credentials.readOpenAiKey();
    if (mounted) _keyController.text = key;
  }

  void _selectProvider(TtsProvider provider) {
    setState(() {
      _draft = _draft.copyWith(provider: provider);
      if (provider == TtsProvider.openai &&
          _endpointController.text.trim().isEmpty) {
        _endpointController.text = CloudTtsService.defaultEndpoint;
      }
      if (provider == TtsProvider.openai) {
        _voices = _openAiVoices;
      }
      _status = null;
    });
    if (provider == TtsProvider.builtin) _loadVoices();
  }

  void _refreshVoices() {
    if (_draft.provider == TtsProvider.openai) {
      _voices = _openAiVoices;
    } else {
      _loadVoices();
    }
  }

  Future<void> _loadVoices() async {
    final raw = await _previewTts.getVoices;
    if (raw is! List || !mounted) return;
    final values = raw
        .whereType<Map>()
        .map(
          (voice) => _VoiceOption(
            name: voice['name']?.toString() ?? '',
            locale: voice['locale']?.toString() ?? '',
            isSystem: true,
          ),
        )
        .where(
          (voice) =>
              voice.name.isNotEmpty &&
              voice.locale.toLowerCase().startsWith('zh'),
        )
        .take(12)
        .toList();
    if (values.isNotEmpty) setState(() => _voices = values);
  }

  Future<void> _loadCacheSize() async {
    final bytes = await _cloudTts.cacheSize();
    final books = ref.read(appControllerProvider).books;
    final entries = <String, int>{};
    for (final book in books) {
      final size = await _cloudTts.cacheSize(bookId: book.id);
      if (size > 0) entries[book.id] = size;
    }
    if (mounted) {
      setState(() {
        _cacheBytes = bytes;
        _bookCacheBytes = entries;
      });
    }
  }

  Future<void> _clearCache() async {
    await ttsAudioHandler.pause();
    await _cloudTts.clearCache();
    await _loadCacheSize();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('云端音频缓存已清理')));
    }
  }

  Future<void> _clearBookCache(Book book) async {
    if (ttsAudioHandler.currentBookId == book.id) {
      await ttsAudioHandler.pause();
    }
    await _cloudTts.clearCache(bookId: book.id);
    await _loadCacheSize();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已清理《${book.title}》的音频缓存')));
    }
  }

  Future<void> _preview(_VoiceOption voice) async {
    if (_previewing == voice.id) {
      await _previewTts.stop();
      if (mounted) setState(() => _previewing = null);
      return;
    }
    await _previewTts.stop();
    if (voice.isSystem) {
      await _previewTts.setVoice({'name': voice.name, 'locale': voice.locale});
    }
    await _previewTts.setSpeechRate((_draft.speed * .5).clamp(.1, 1));
    await _previewTts.setPitch(switch (voice.name) {
      '温润男声' => .85,
      '清亮少年音' => 1.18,
      _ => 1.02,
    });
    setState(() => _previewing = voice.id);
    await _previewTts.speak('山水有清音，欢迎使用耳读。');
  }

  Future<void> _save() async {
    final value = _draft.copyWith(
      apiKey: _keyController.text.trim(),
      endpoint: _endpointController.text.trim(),
    );
    await ref.read(appControllerProvider.notifier).setTtsSettings(value);
    await ttsAudioHandler.applySettings(value);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('TTS 设置已保存')));
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 18, bottom: 9),
    child: Text(
      text,
      style: const TextStyle(
        color: AppColors.graphite,
        fontSize: 12,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

class _ProviderCard extends StatelessWidget {
  const _ProviderCard({
    required this.provider,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final TtsProvider provider;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (name, description) = switch (provider) {
      TtsProvider.builtin => ('系统内置语音', '无需联网，音质和可用音色因设备而异'),
      TtsProvider.aliyun => ('阿里云 · 智能语音', '支持普通话、方言和多种情感发音人'),
      TtsProvider.azure => ('Azure Speech', '神经网络语音，中英混排表现稳定'),
      TtsProvider.openai => ('OpenAI TTS', '自然度较高，使用量按服务商规则计费'),
    };
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 9),
      color: selected ? AppColors.bambooSoft : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(13),
        side: BorderSide(
          color: selected ? AppColors.bamboo : Theme.of(context).dividerColor,
        ),
      ),
      child: ListTile(
        enabled: enabled,
        title: Text(name, style: const TextStyle(fontWeight: FontWeight.w800)),
        subtitle: Text(description),
        trailing: Chip(
          label: Text(
            provider == TtsProvider.builtin
                ? '免费'
                : enabled
                ? '云端'
                : '待接入',
          ),
          visualDensity: VisualDensity.compact,
        ),
        onTap: onTap,
      ),
    );
  }
}

String _endpointHint(TtsProvider provider) => switch (provider) {
  TtsProvider.aliyun => '如 cn-shanghai',
  TtsProvider.azure => '如 eastasia',
  TtsProvider.openai => 'https://api.openai.com/v1',
  TtsProvider.builtin => '',
};

class _VoiceOption {
  const _VoiceOption({
    required this.name,
    required this.locale,
    this.isSystem = false,
  });

  final String name;
  final String locale;
  final bool isSystem;
  String get id => '$name|$locale';
}

const _openAiVoices = <_VoiceOption>[
  _VoiceOption(name: 'Marin', locale: 'AI · 推荐'),
  _VoiceOption(name: 'Cedar', locale: 'AI · 推荐'),
  _VoiceOption(name: 'Coral', locale: 'AI'),
  _VoiceOption(name: 'Alloy', locale: 'AI'),
  _VoiceOption(name: 'Ash', locale: 'AI'),
  _VoiceOption(name: 'Ballad', locale: 'AI'),
  _VoiceOption(name: 'Echo', locale: 'AI'),
  _VoiceOption(name: 'Fable', locale: 'AI'),
  _VoiceOption(name: 'Nova', locale: 'AI'),
  _VoiceOption(name: 'Onyx', locale: 'AI'),
  _VoiceOption(name: 'Sage', locale: 'AI'),
  _VoiceOption(name: 'Shimmer', locale: 'AI'),
  _VoiceOption(name: 'Verse', locale: 'AI'),
];

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}
