import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_state.dart';
import '../../core/models.dart';
import '../../core/theme.dart';

class ProfilePage extends ConsumerStatefulWidget {
  const ProfilePage({super.key});
  @override
  ConsumerState<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends ConsumerState<ProfilePage> {
  bool _month = false;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appControllerProvider);
    final settings = state.settings;
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '我的',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 24),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 4, 18, 30),
        children: [
          const Row(
            children: [
              CircleAvatar(
                radius: 29,
                backgroundColor: AppColors.ink,
                child: Text(
                  '游',
                  style: TextStyle(
                    color: Color(0xFFF3DAD3),
                    fontWeight: FontWeight.w800,
                    fontSize: 21,
                  ),
                ),
              ),
              SizedBox(width: 14),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '游客读者',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 19),
                  ),
                  SizedBox(height: 3),
                  Text(
                    '所有数据仅保存在本机',
                    style: TextStyle(color: AppColors.graphite, fontSize: 11),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 22),
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(15),
              side: BorderSide(color: Theme.of(context).dividerColor),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Row(
                    children: [
                      ChoiceChip(
                        label: const Text('本周'),
                        selected: !_month,
                        onSelected: (_) => setState(() => _month = false),
                        selectedColor: AppColors.bamboo,
                        labelStyle: TextStyle(
                          color: !_month ? Colors.white : null,
                        ),
                      ),
                      const SizedBox(width: 8),
                      ChoiceChip(
                        label: const Text('本月'),
                        selected: _month,
                        onSelected: (_) => setState(() => _month = true),
                        selectedColor: AppColors.bamboo,
                        labelStyle: TextStyle(
                          color: _month ? Colors.white : null,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: _Stat(
                          value: _month ? '21h' : '4.5h',
                          label: '阅读时长',
                        ),
                      ),
                      Expanded(
                        child: _Stat(
                          value: _month ? '28h' : '6.2h',
                          label: '听书时长',
                        ),
                      ),
                      const Expanded(
                        child: _Stat(value: '12', label: '连续天数'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          _SettingsCard(
            children: [
              _SettingTile(
                icon: Icons.edit_note,
                title: '我的笔记与划线',
                value: state.highlights.isEmpty
                    ? null
                    : '${state.highlights.length}',
                onTap: () => _showHighlights(context, ref),
              ),
              _SettingTile(
                icon: Icons.history,
                title: '听书历史',
                onTap: () => _message(
                  context,
                  state.activeAudioBookId == null ? '暂无听书历史' : '已记录最近的听书进度',
                ),
              ),
              _SettingTile(
                icon: Icons.cleaning_services_outlined,
                title: '清理缓存',
                value: '128 MB',
                onTap: () => _message(context, '缓存已清理'),
              ),
            ],
          ),
          const SizedBox(height: 18),
          _SettingsCard(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 15, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '全局主题（与阅读器同步）',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
                child: Row(
                  children: ReaderTheme.values
                      .map(
                        (theme) => _ThemeDot(
                          theme: theme,
                          selected: theme == settings.theme,
                          onTap: () => ref
                              .read(appControllerProvider.notifier)
                              .setSettings(settings.copyWith(theme: theme)),
                        ),
                      )
                      .toList(),
                ),
              ),
              _SettingTile(
                icon: Icons.record_voice_over_outlined,
                title: 'TTS 默认发音人',
                value: '系统中文语音',
                onTap: () => _message(context, '发音人由系统 TTS 提供'),
              ),
              _SettingTile(
                icon: Icons.speed,
                title: 'TTS 默认语速',
                value: '1.0x',
                onTap: () => _message(context, '可在听书页实时调整'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});
  final String value;
  final String label;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text(
        value,
        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 3),
      Text(
        label,
        style: const TextStyle(fontSize: 10, color: AppColors.graphite),
      ),
    ],
  );
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Card(
    elevation: 0,
    margin: EdgeInsets.zero,
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(15),
      side: BorderSide(color: Theme.of(context).dividerColor),
    ),
    child: Column(children: children),
  );
}

class _SettingTile extends StatelessWidget {
  const _SettingTile({
    required this.icon,
    required this.title,
    this.value,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String? value;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon, size: 21),
    title: Text(title, style: const TextStyle(fontSize: 14)),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (value != null)
          Text(
            value!,
            style: const TextStyle(fontSize: 11, color: AppColors.graphite),
          ),
        const Icon(Icons.chevron_right, size: 18, color: AppColors.graphite),
      ],
    ),
    onTap: onTap,
  );
}

class _ThemeDot extends StatelessWidget {
  const _ThemeDot({
    required this.theme,
    required this.selected,
    required this.onTap,
  });
  final ReaderTheme theme;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final color = switch (theme) {
      ReaderTheme.light => AppColors.paper,
      ReaderTheme.dark => const Color(0xFF1B1A17),
      ReaderTheme.eye => AppColors.eye,
    };
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 34,
        height: 34,
        margin: const EdgeInsets.only(right: 13),
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? AppColors.seal : Theme.of(context).dividerColor,
            width: selected ? 3 : 1,
          ),
        ),
      ),
    );
  }
}

void _message(BuildContext context, String message) => ScaffoldMessenger.of(
  context,
).showSnackBar(SnackBar(content: Text(message)));

Future<void> _showHighlights(BuildContext context, WidgetRef ref) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => Consumer(
      builder: (context, ref, _) {
        final state = ref.watch(appControllerProvider);
        final highlights = state.highlights;
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .72,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Text(
                    '我的笔记与划线',
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: highlights.isEmpty
                      ? const Center(child: Text('还没有划线或笔记'))
                      : ListView.separated(
                          padding: const EdgeInsets.all(16),
                          itemCount: highlights.length,
                          separatorBuilder: (_, _) => const Divider(height: 24),
                          itemBuilder: (_, index) {
                            final item = highlights[index];
                            final books = state.books.where(
                              (book) => book.id == item.bookId,
                            );
                            final title = books.isEmpty
                                ? '已删除书籍'
                                : books.first.title;
                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                '“${item.excerpt}”',
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                item.note == null
                                    ? title
                                    : '$title\n笔记：${item.note}',
                              ),
                              isThreeLine: item.note != null,
                              trailing: IconButton(
                                tooltip: '删除',
                                onPressed: () => ref
                                    .read(appControllerProvider.notifier)
                                    .removeHighlight(item.id),
                                icon: const Icon(Icons.delete_outline),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}
