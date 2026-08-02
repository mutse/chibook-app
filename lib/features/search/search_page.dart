import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_state.dart';
import '../../core/models.dart';
import '../../core/theme.dart';

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});
  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appControllerProvider);
    final query = _query.trim().toLowerCase();
    final matches = query.isEmpty
        ? const <Book>[]
        : state.books
              .where(
                (b) =>
                    b.title.toLowerCase().contains(query) ||
                    b.author.toLowerCase().contains(query),
              )
              .toList();
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => context.pop(),
          icon: const Icon(Icons.arrow_back_ios_new, size: 19),
        ),
        titleSpacing: 0,
        title: TextField(
          controller: _controller,
          autofocus: true,
          onChanged: (v) => setState(() => _query = v),
          onSubmitted: ref.read(appControllerProvider.notifier).addSearch,
          decoration: InputDecoration(
            hintText: '搜索书名 / 作者',
            prefixIcon: const Icon(Icons.search, size: 20),
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    onPressed: () {
                      _controller.clear();
                      setState(() => _query = '');
                    },
                    icon: const Icon(Icons.close, size: 18),
                  ),
            filled: true,
            fillColor: Theme.of(context).cardColor,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(13),
              borderSide: BorderSide.none,
            ),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        actions: const [SizedBox(width: 16)],
      ),
      body: query.isEmpty
          ? _RecentSearches(
              values: state.recentSearches,
              onTap: (value) {
                _controller.text = value;
                setState(() => _query = value);
              },
            )
          : matches.isEmpty
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.search_off_rounded,
                    size: 54,
                    color: AppColors.graphite,
                  ),
                  SizedBox(height: 12),
                  Text(
                    '未找到相关书籍，换个关键词试试',
                    style: TextStyle(color: AppColors.graphite),
                  ),
                ],
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(18),
              itemCount: matches.length,
              separatorBuilder: (_, _) => const Divider(height: 22),
              itemBuilder: (_, i) {
                final book = matches[i];
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Container(
                    width: 45,
                    height: 62,
                    decoration: BoxDecoration(
                      color: Color(book.coverColor),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    alignment: Alignment.bottomLeft,
                    padding: const EdgeInsets.all(6),
                    child: Text(
                      book.title.characters.first,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  title: Text(
                    book.title,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: Text(book.author),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    ref.read(appControllerProvider.notifier).addSearch(_query);
                    context.push('/reader/${book.id}');
                  },
                );
              },
            ),
    );
  }
}

class _RecentSearches extends StatelessWidget {
  const _RecentSearches({required this.values, required this.onTap});
  final List<String> values;
  final ValueChanged<String> onTap;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(20),
    child: Align(
      alignment: Alignment.topLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '最近搜索',
            style: TextStyle(
              color: AppColors.graphite,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 9,
            runSpacing: 9,
            children: values
                .map(
                  (value) => ActionChip(
                    label: Text(value),
                    onPressed: () => onTap(value),
                    backgroundColor: Theme.of(context).cardColor,
                    side: BorderSide(color: Theme.of(context).dividerColor),
                  ),
                )
                .toList(),
          ),
        ],
      ),
    ),
  );
}
