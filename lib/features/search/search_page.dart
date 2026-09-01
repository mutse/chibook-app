import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_state.dart';
import '../../core/adaptive.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import '../../services/zlibrary_service.dart';

enum _SearchScope { shelf, zLibrary }

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _controller = TextEditingController();
  final Set<String> _downloading = {};
  String _query = '';
  String _lastOnlineQuery = '';
  String? _onlineError;
  List<ZLibraryBook> _onlineResults = const [];
  _SearchScope _scope = _SearchScope.shelf;
  bool _searching = false;
  int _operation = 0;

  @override
  void dispose() {
    _operation++;
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appControllerProvider);
    final query = _query.trim().toLowerCase();
    final localMatches = query.isEmpty
        ? const <Book>[]
        : state.books
              .where(
                (book) =>
                    book.title.toLowerCase().contains(query) ||
                    book.author.toLowerCase().contains(query),
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
          textInputAction: TextInputAction.search,
          onChanged: (value) => setState(() {
            _query = value;
            if (value.trim() != _lastOnlineQuery) {
              _onlineResults = const [];
              _lastOnlineQuery = '';
              _onlineError = null;
            }
          }),
          onSubmitted: (_) => _submitSearch(),
          decoration: InputDecoration(
            hintText: _scope == _SearchScope.shelf
                ? '搜索书架中的书名 / 作者'
                : '搜索 Z-Library 书名 / 作者 / ISBN',
            prefixIcon: const Icon(Icons.search, size: 20),
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    onPressed: () {
                      _operation++;
                      _controller.clear();
                      setState(() {
                        _query = '';
                        _onlineError = null;
                        _onlineResults = const [];
                        _lastOnlineQuery = '';
                        _searching = false;
                      });
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
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: maxReadingColumnWidth),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 6),
                child: SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<_SearchScope>(
                    segments: const [
                      ButtonSegment(
                        value: _SearchScope.shelf,
                        icon: Icon(Icons.shelves, size: 17),
                        label: Text('本地书架'),
                      ),
                      ButtonSegment(
                        value: _SearchScope.zLibrary,
                        icon: Icon(Icons.cloud_download_outlined, size: 17),
                        label: Text('Z-Library'),
                      ),
                    ],
                    selected: {_scope},
                    onSelectionChanged: (value) {
                      _operation++;
                      setState(() {
                        _scope = value.single;
                        _onlineError = null;
                        _searching = false;
                      });
                    },
                  ),
                ),
              ),
              Expanded(
                child: _scope == _SearchScope.shelf
                    ? _buildLocalResults(state, localMatches, query)
                    : _buildOnlineResults(state),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLocalResults(AppState state, List<Book> matches, String query) {
    if (query.isEmpty) {
      return _RecentSearches(values: state.recentSearches, onTap: _useRecent);
    }
    if (matches.isEmpty) {
      return const _EmptyResult(
        icon: Icons.search_off_rounded,
        message: '书架中没有找到相关书籍',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(18),
      itemCount: matches.length,
      separatorBuilder: (_, _) => const Divider(height: 22),
      itemBuilder: (_, index) {
        final book = matches[index];
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: _LocalCover(book: book),
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
    );
  }

  Widget _buildOnlineResults(AppState state) {
    if (state.zLibraryAccount == null) {
      return _OnlineLoginPrompt(
        onLogin: () => context.push('/settings/zlibrary'),
      );
    }
    if (_searching) return const Center(child: CircularProgressIndicator());
    if (_onlineError case final message?) {
      return _OnlineError(message: message, onRetry: _submitSearch);
    }
    if (_query.trim().isEmpty) {
      return _RecentSearches(values: state.recentSearches, onTap: _useRecent);
    }
    if (_lastOnlineQuery.isEmpty) {
      return const _EmptyResult(
        icon: Icons.manage_search,
        message: '输入关键词后按键盘上的“搜索”',
      );
    }
    if (_onlineResults.isEmpty) {
      return const _EmptyResult(
        icon: Icons.search_off_rounded,
        message: 'Z-Library 中没有找到支持的 TXT、EPUB 或 PDF',
      );
    }
    return ListView.separated(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 30),
      itemCount: _onlineResults.length,
      separatorBuilder: (_, _) => const Divider(height: 22),
      itemBuilder: (_, index) {
        final book = _onlineResults[index];
        return _OnlineBookTile(
          book: book,
          downloading: _downloading.contains(book.id),
          onDownload: () => _download(book),
        );
      },
    );
  }

  void _useRecent(String value) {
    _controller.text = value;
    setState(() => _query = value);
    if (_scope == _SearchScope.zLibrary) _submitSearch();
  }

  Future<void> _submitSearch() async {
    final query = _query.trim();
    if (query.isEmpty) return;
    ref.read(appControllerProvider.notifier).addSearch(query);
    if (_scope != _SearchScope.zLibrary) return;
    final operation = ++_operation;
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _onlineError = null;
    });
    try {
      final results = await ref
          .read(appControllerProvider.notifier)
          .searchZLibrary(query);
      if (!mounted || operation != _operation) return;
      setState(() {
        _onlineResults = results;
        _lastOnlineQuery = query;
      });
    } catch (error) {
      if (!mounted || operation != _operation) return;
      setState(() => _onlineError = error.toString());
    } finally {
      if (mounted && operation == _operation) {
        setState(() => _searching = false);
      }
    }
  }

  Future<void> _download(ZLibraryBook book) async {
    if (_downloading.contains(book.id)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('下载《${book.title}》？'),
        content: const Text('请确认此书属于公版、开放授权内容，或你已合法取得下载与使用权。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认并下载'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _downloading.add(book.id));
    try {
      final imported = await ref
          .read(appControllerProvider.notifier)
          .downloadZLibraryBook(book);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('《${imported.title}》已下载到本地书架'),
          action: SnackBarAction(
            label: '打开',
            onPressed: () => context.push('/reader/${imported.id}'),
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('下载失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _downloading.remove(book.id));
    }
  }
}

class _LocalCover extends StatelessWidget {
  const _LocalCover({required this.book});

  final Book book;

  @override
  Widget build(BuildContext context) => Container(
    width: 45,
    height: 62,
    decoration: BoxDecoration(
      color: Color(book.coverColor),
      borderRadius: BorderRadius.circular(5),
    ),
    alignment: Alignment.bottomLeft,
    padding: const EdgeInsets.all(6),
    child: Text(
      book.title.characters.firstOrNull ?? '书',
      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
    ),
  );
}

class _OnlineBookTile extends StatelessWidget {
  const _OnlineBookTile({
    required this.book,
    required this.downloading,
    required this.onDownload,
  });

  final ZLibraryBook book;
  final bool downloading;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: SizedBox(
      width: 48,
      height: 66,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: book.coverUrl == null
            ? const ColoredBox(
                color: AppColors.bambooSoft,
                child: Icon(Icons.menu_book, color: AppColors.bamboo),
              )
            : Image.network(
                book.coverUrl!,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const ColoredBox(
                  color: AppColors.bambooSoft,
                  child: Icon(Icons.menu_book, color: AppColors.bamboo),
                ),
              ),
      ),
    ),
    title: Text(
      book.title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontWeight: FontWeight.w800),
    ),
    subtitle: Text(
      [
        book.author,
        book.year,
        book.format.name.toUpperCase(),
        book.fileSize,
      ].where((value) => value.trim().isNotEmpty).join(' · '),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    ),
    trailing: IconButton.filledTonal(
      tooltip: '下载到书架',
      onPressed: downloading ? null : onDownload,
      icon: downloading
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.download_rounded),
    ),
  );
}

class _OnlineLoginPrompt extends StatelessWidget {
  const _OnlineLoginPrompt({required this.onLogin});

  final VoidCallback onLogin;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.lock_outline, size: 52, color: AppColors.graphite),
          const SizedBox(height: 12),
          const Text(
            '登录后搜索 Z-Library',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          const Text(
            '登录凭证将保存在系统安全存储中',
            style: TextStyle(color: AppColors.graphite),
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: onLogin,
            icon: const Icon(Icons.login),
            label: const Text('前往登录'),
          ),
        ],
      ),
    ),
  );
}

class _OnlineError extends StatelessWidget {
  const _OnlineError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.cloud_off_outlined,
            size: 52,
            color: AppColors.graphite,
          ),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ],
      ),
    ),
  );
}

class _EmptyResult extends StatelessWidget {
  const _EmptyResult({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 54, color: AppColors.graphite),
        const SizedBox(height: 12),
        Text(message, style: const TextStyle(color: AppColors.graphite)),
      ],
    ),
  );
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
