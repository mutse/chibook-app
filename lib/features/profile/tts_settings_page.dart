import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_state.dart';
import '../../core/models.dart';
import '../../core/theme.dart';

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

  static const _voices = <(String, String)>[
    ('知性女声', '标准普通话 · 沉稳'),
    ('温润男声', '标准普通话 · 叙事感'),
    ('清亮少年音', '轻快语调'),
  ];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _draft = ref.read(appControllerProvider).ttsSettings;
    _keyController.text = _draft.apiKey;
    _endpointController.text = _draft.endpoint;
    _previewTts.setLanguage('zh-CN');
    _previewTts.setCompletionHandler(() {
      if (mounted) setState(() => _previewing = null);
    });
    _previewTts.setCancelHandler(() {
      if (mounted) setState(() => _previewing = null);
    });
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
            onTap: () => setState(() {
              _draft = _draft.copyWith(provider: provider);
              _status = null;
            }),
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
                        color: _status!.startsWith('配置完整')
                            ? AppColors.bamboo
                            : AppColors.seal,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  const Text(
                    '这里只检查配置完整性；云端引擎尚未接入播放链路，听书会继续使用系统语音。',
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
              final selected = _draft.voiceName == voice.$1;
              return ListTile(
                selected: selected,
                selectedTileColor: AppColors.bambooSoft,
                title: Text(
                  voice.$1,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(voice.$2),
                trailing: OutlinedButton(
                  onPressed: () => _preview(voice.$1),
                  child: Text(_previewing == voice.$1 ? '停止' : '试听'),
                ),
                onTap: () => setState(
                  () => _draft = _draft.copyWith(voiceName: voice.$1),
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
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;
    final key = _keyController.text.trim();
    final endpoint = _endpointController.text.trim();
    setState(() {
      _testing = false;
      _status = key.isEmpty || endpoint.isEmpty
          ? '请填写 API Key 和 Endpoint'
          : '配置完整，保存后生效';
    });
  }

  Future<void> _preview(String voiceName) async {
    if (_previewing == voiceName) {
      await _previewTts.stop();
      if (mounted) setState(() => _previewing = null);
      return;
    }
    await _previewTts.stop();
    await _previewTts.setSpeechRate((_draft.speed * .5).clamp(.1, 1));
    await _previewTts.setPitch(switch (voiceName) {
      '温润男声' => .85,
      '清亮少年音' => 1.18,
      _ => 1.02,
    });
    setState(() => _previewing = voiceName);
    await _previewTts.speak('山水有清音，欢迎使用耳读。');
  }

  Future<void> _save() async {
    final value = _draft.copyWith(
      apiKey: _keyController.text.trim(),
      endpoint: _endpointController.text.trim(),
    );
    await ref.read(appControllerProvider.notifier).setTtsSettings(value);
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
    required this.onTap,
  });

  final TtsProvider provider;
  final bool selected;
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
        title: Text(name, style: const TextStyle(fontWeight: FontWeight.w800)),
        subtitle: Text(description),
        trailing: Chip(
          label: Text(provider == TtsProvider.builtin ? '免费' : '云端'),
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
