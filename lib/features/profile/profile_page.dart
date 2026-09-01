import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_state.dart';
import '../../core/adaptive.dart';
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
    final cutoff = DateTime.now().subtract(Duration(days: _month ? 30 : 7));
    final listenedSeconds = state.listeningRecords
        .where((record) => record.updatedAt.isAfter(cutoff))
        .fold<int>(0, (sum, record) => sum + record.listenedSeconds);
    // 原本这里是写死的 '21h'/'4.5h' 与 '12'。改为由真实本机数据推导，
    // 与"所有数据仅保存在本机"的定位一致。
    final openedBooks = state.books
        .where(
          (book) =>
              book.lastOpenedAt != null && book.lastOpenedAt!.isAfter(cutoff),
        )
        .length;
    final streak = _readingStreak(state.books, state.listeningRecords);
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '我的',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 24),
        ),
      ),
      // 大屏限宽：设置项横贯整个 iPad 宽度既难点击也不像原生平板应用。
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: maxReadingColumnWidth),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 30),
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 29,
                    backgroundColor: AppColors.ink,
                    backgroundImage: state.weReadAccount?.avatarUrl == null
                        ? null
                        : NetworkImage(state.weReadAccount!.avatarUrl!),
                    child: state.weReadAccount?.avatarUrl == null
                        ? Text(
                            state.weReadAccount?.name.isNotEmpty == true
                                ? state.weReadAccount!.name.substring(0, 1)
                                : '游',
                            style: const TextStyle(
                              color: Color(0xFFF3DAD3),
                              fontWeight: FontWeight.w800,
                              fontSize: 21,
                            ),
                          )
                        : null,
                  ),
                  const SizedBox(width: 14),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        state.weReadAccount?.name ?? '游客读者',
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 19,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        state.weReadAccount == null
                            ? '本地阅读数据仅保存在本机'
                            : '微信读书书架已连接',
                        style: const TextStyle(
                          color: AppColors.graphite,
                          fontSize: 11,
                        ),
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
                              value: '$openedBooks',
                              label: _month ? '本月在读' : '本周在读',
                            ),
                          ),
                          Expanded(
                            child: _Stat(
                              value: _durationLabel(listenedSeconds),
                              label: '听书时长',
                            ),
                          ),
                          Expanded(
                            child: _Stat(value: '$streak', label: '连续天数'),
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
                    icon: Icons.auto_stories_outlined,
                    title: '微信读书',
                    value: state.weReadAccount?.name ?? '未登录',
                    onTap: () => context.push('/settings/weread'),
                  ),
                  _SettingTile(
                    icon: Icons.cloud_download_outlined,
                    title: 'Z-Library',
                    value: state.zLibraryAccount == null ? '未登录' : '已连接',
                    onTap: () => context.push('/settings/zlibrary'),
                  ),
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
                    value: state.listeningRecords.isEmpty
                        ? null
                        : '${state.listeningRecords.length}',
                    onTap: () => _showListeningHistory(context, ref),
                  ),
                  _SettingTile(
                    icon: Icons.cleaning_services_outlined,
                    title: '清理缓存',
                    value: '0 MB',
                    onTap: () => _message(context, '系统 TTS 不产生音频缓存'),
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
                    value: state.ttsSettings.voiceName,
                    onTap: () => context.push('/settings/tts'),
                  ),
                  _SettingTile(
                    icon: Icons.speed,
                    title: 'TTS 默认语速',
                    value: '${state.ttsSettings.speed}x',
                    onTap: () => context.push('/settings/tts'),
                  ),
                  _SettingTile(
                    icon: Icons.cloud_outlined,
                    title: 'TTS API 设置',
                    value: switch (state.ttsSettings.provider) {
                      TtsProvider.builtin => '系统内置',
                      TtsProvider.aliyun => '阿里云',
                      TtsProvider.azure => '微软在线（免密）',
                      TtsProvider.openai => 'OpenAI',
                    },
                    onTap: () => context.push('/settings/tts'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _durationLabel(int seconds) {
  if (seconds < 60) return '${seconds}s';
  if (seconds < 3600) return '${seconds ~/ 60}m';
  return '${(seconds / 3600).toStringAsFixed(1)}h';
}

/// 连续阅读/听书天数：从今天（或昨天）向前数，只要当天有打开书籍或有
/// 听书记录就算一天，遇到空白日即中断。全部基于本机真实数据。
int _readingStreak(List<Book> books, List<ListeningRecord> records) {
  final days = <DateTime>{};
  void add(DateTime? time) {
    if (time == null) return;
    days.add(DateTime(time.year, time.month, time.day));
  }

  for (final book in books) {
    add(book.lastOpenedAt);
  }
  for (final record in records) {
    add(record.updatedAt);
  }
  if (days.isEmpty) return 0;
  final now = DateTime.now();
  var cursor = DateTime(now.year, now.month, now.day);
  // 今天还没有记录时从昨天起算，避免"今天还没读"就把连续天数清零。
  if (!days.contains(cursor)) {
    cursor = cursor.subtract(const Duration(days: 1));
    if (!days.contains(cursor)) return 0;
  }
  var streak = 0;
  while (days.contains(cursor)) {
    streak++;
    cursor = cursor.subtract(const Duration(days: 1));
  }
  return streak;
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
  await showAdaptiveSheet<void>(
    context: context,
    scrollable: true,
    builder: (context) => Consumer(
      builder: (context, ref, _) {
        final state = ref.watch(appControllerProvider);
        final highlights = state.highlights;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
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
              Flexible(
                child: highlights.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(child: Text('还没有划线或笔记')),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
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
        );
      },
    ),
  );
}

Future<void> _showListeningHistory(BuildContext context, WidgetRef ref) async {
  await showAdaptiveSheet<void>(
    context: context,
    scrollable: true,
    builder: (context) => Consumer(
      builder: (context, ref, _) {
        final state = ref.watch(appControllerProvider);
        final records = state.listeningRecords;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 12, 10),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '听书历史',
                        style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: records.isEmpty
                          ? null
                          : () => ref
                                .read(appControllerProvider.notifier)
                                .clearListeningHistory(),
                      child: const Text('清空'),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: records.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(child: Text('暂无听书历史')),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        padding: const EdgeInsets.all(16),
                        itemCount: records.length,
                        separatorBuilder: (_, _) => const Divider(),
                        itemBuilder: (_, index) {
                          final record = records[index];
                          final books = state.books.where(
                            (book) => book.id == record.bookId,
                          );
                          if (books.isEmpty) return const SizedBox.shrink();
                          final book = books.first;
                          if (book.chapters.isEmpty) {
                            return ListTile(
                              leading: const Icon(Icons.warning_amber),
                              title: Text(book.title),
                              subtitle: const Text('此书没有可播放章节'),
                            );
                          }
                          final chapter = record.chapterIndex.clamp(
                            0,
                            book.chapters.length - 1,
                          );
                          return ListTile(
                            leading: const Icon(Icons.headphones_outlined),
                            title: Text(book.title),
                            subtitle: Text(
                              '${book.chapters[chapter].title} · ${_durationLabel(record.listenedSeconds)}',
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () {
                              Navigator.pop(context);
                              context.push('/player/${book.id}');
                            },
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    ),
  );
}
