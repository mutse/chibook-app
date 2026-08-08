import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_state.dart';
import '../../core/models.dart';
import '../../core/theme.dart';

class ShelfPage extends ConsumerWidget {
  const ShelfPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appControllerProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '书架',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 25),
        ),
        actions: [
          IconButton(
            tooltip: '搜索',
            onPressed: () => context.push('/search'),
            icon: const Icon(Icons.search),
          ),
          _ViewButton(
            icon: Icons.grid_view_rounded,
            active: state.isGrid,
            onTap: () => ref.read(appControllerProvider.notifier).setGrid(true),
          ),
          _ViewButton(
            icon: Icons.view_agenda_outlined,
            active: !state.isGrid,
            onTap: () =>
                ref.read(appControllerProvider.notifier).setGrid(false),
          ),
          const SizedBox(width: 10),
        ],
      ),
      body: !state.initialized
          ? const Center(child: CircularProgressIndicator())
          : state.books.isEmpty
          ? const _EmptyShelf()
          : state.isGrid
          ? _BookGrid(books: state.books)
          : _BookList(books: state.books),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showImport(context, ref),
        backgroundColor: AppColors.seal,
        foregroundColor: Colors.white,
        child: const Icon(Icons.add),
      ),
    );
  }

  Future<void> _showImport(BuildContext context, WidgetRef ref) async {
    var selectedFormat = BookFormat.txt;
    final format = await showModalBottomSheet<BookFormat>(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '导入本地书籍',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
                ),
                const SizedBox(height: 14),
                Row(
                  children: BookFormat.values
                      .map(
                        (value) => Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: _FormatChip(
                              value.name.toUpperCase(),
                              selected: value == selectedFormat,
                              onTap: () =>
                                  setModalState(() => selectedFormat = value),
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 18),
                FilledButton(
                  onPressed: () => Navigator.pop(context, selectedFormat),
                  child: Text('选择 ${selectedFormat.name.toUpperCase()} 文件'),
                ),
                const SizedBox(height: 8),
                Text(
                  selectedFormat == BookFormat.pdf
                      ? 'PDF 使用固定版式阅读，仅支持整体缩放。'
                      : 'TXT 与 EPUB 支持字号、行距和阅读主题调整。',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: AppColors.graphite),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (format == null || !context.mounted) return;
    try {
      final success = await ref
          .read(appControllerProvider.notifier)
          .importBook(format: format);
      if (context.mounted && success) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('书籍已导入到本地书架')));
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导入失败：$error')));
      }
    }
  }
}

class _ViewButton extends StatelessWidget {
  const _ViewButton({
    required this.icon,
    required this.active,
    required this.onTap,
  });
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 3),
    child: IconButton.filledTonal(
      onPressed: onTap,
      style: IconButton.styleFrom(
        backgroundColor: active
            ? AppColors.bamboo
            : Theme.of(context).cardColor,
        foregroundColor: active ? Colors.white : null,
      ),
      icon: Icon(icon, size: 19),
    ),
  );
}

class _BookGrid extends StatelessWidget {
  const _BookGrid({required this.books});
  final List<Book> books;

  @override
  Widget build(BuildContext context) => GridView.builder(
    padding: const EdgeInsets.fromLTRB(18, 12, 18, 100),
    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: 3,
      childAspectRatio: .57,
      crossAxisSpacing: 13,
      mainAxisSpacing: 18,
    ),
    itemCount: books.length,
    itemBuilder: (_, index) => _GridBook(book: books[index]),
  );
}

class _GridBook extends ConsumerWidget {
  const _GridBook({required this.book});
  final Book book;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listening = ref.watch(
      appControllerProvider.select(
        (state) => state.activeAudioBookId == book.id,
      ),
    );
    return GestureDetector(
      onTap: () => context.push('/reader/${book.id}'),
      onLongPress: () => _showMultiSelect(context, ref, book.id),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(child: _BookCover(book: book)),
                if (book.progress > 0)
                  Positioned(
                    right: 7,
                    top: 7,
                    child: _ProgressSeal(progress: book.progress),
                  ),
                if (book.isPinned)
                  const Positioned(
                    right: 8,
                    bottom: 8,
                    child: Icon(Icons.push_pin, color: Colors.white, size: 16),
                  ),
                Positioned(
                  left: 5,
                  top: 5,
                  child: IconButton.filled(
                    tooltip: '书籍菜单',
                    visualDensity: VisualDensity.compact,
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.black38,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(28, 28),
                      padding: EdgeInsets.zero,
                    ),
                    onPressed: () => _bookMenu(context, ref, book),
                    icon: const Icon(Icons.more_horiz, size: 17),
                  ),
                ),
                if (listening)
                  const Positioned(left: 6, bottom: 6, child: _ListeningTag()),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            book.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
          ),
          Text(
            book.author,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10.5, color: AppColors.graphite),
          ),
        ],
      ),
    );
  }
}

class _BookList extends ConsumerWidget {
  const _BookList({required this.books});
  final List<Book> books;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ListView.separated(
    padding: const EdgeInsets.fromLTRB(18, 8, 18, 100),
    itemCount: books.length,
    separatorBuilder: (_, _) => const Divider(height: 24),
    itemBuilder: (_, index) {
      final book = books[index];
      return ListTile(
        contentPadding: EdgeInsets.zero,
        leading: SizedBox(width: 54, height: 76, child: _BookCover(book: book)),
        title: Text(
          book.title,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: Text(
          '${book.author}\n已读 ${(book.progress * 100).round()}%',
          style: const TextStyle(height: 1.6),
        ),
        isThreeLine: true,
        trailing: IconButton(
          icon: const Icon(Icons.more_horiz),
          onPressed: () => _bookMenu(context, ref, book),
        ),
        onTap: () => context.push('/reader/${book.id}'),
        onLongPress: () => _showMultiSelect(context, ref, book.id),
      );
    },
  );
}

class _BookCover extends StatelessWidget {
  const _BookCover({required this.book});
  final Book book;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(7),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color(book.coverColor).withValues(alpha: .88),
          Color(book.coverColor).withValues(alpha: .55),
          const Color(0xFF1F201D),
        ],
      ),
      boxShadow: const [
        BoxShadow(color: Colors.black26, blurRadius: 12, offset: Offset(0, 7)),
      ],
    ),
    child: Padding(
      padding: const EdgeInsets.all(10),
      child: Align(
        alignment: Alignment.bottomLeft,
        child: Text(
          book.title,
          maxLines: 3,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
            height: 1.3,
          ),
        ),
      ),
    ),
  );
}

class _ProgressSeal extends StatelessWidget {
  const _ProgressSeal({required this.progress});
  final double progress;

  @override
  Widget build(BuildContext context) => Container(
    width: 32,
    height: 32,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .93),
      shape: BoxShape.circle,
      border: Border.all(color: AppColors.seal, width: 1.4),
    ),
    child: Text(
      '${(progress * 100).round()}%',
      style: const TextStyle(
        color: AppColors.seal,
        fontWeight: FontWeight.w800,
        fontSize: 8,
      ),
    ),
  );
}

class _FormatChip extends StatelessWidget {
  const _FormatChip(this.text, {required this.selected, required this.onTap});
  final String text;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(10),
    child: Container(
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: selected ? AppColors.bambooSoft : null,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: selected ? AppColors.bamboo : Theme.of(context).dividerColor,
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: selected ? AppColors.bamboo : AppColors.graphite,
          fontWeight: FontWeight.w800,
        ),
      ),
    ),
  );
}

class _ListeningTag extends StatelessWidget {
  const _ListeningTag();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
    decoration: BoxDecoration(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(999),
    ),
    child: const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.graphic_eq, color: Color(0xFF7CE0A6), size: 13),
        SizedBox(width: 3),
        Text('正在听', style: TextStyle(color: Colors.white, fontSize: 9)),
      ],
    ),
  );
}

class _EmptyShelf extends StatelessWidget {
  const _EmptyShelf();
  @override
  Widget build(BuildContext context) => const Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.menu_book_rounded, size: 70, color: AppColors.graphite),
        SizedBox(height: 14),
        Text('书架还是空的'),
        Text(
          '点击右下角导入 TXT、EPUB 或 PDF',
          style: TextStyle(color: AppColors.graphite),
        ),
      ],
    ),
  );
}

Future<void> _bookMenu(BuildContext context, WidgetRef ref, Book book) async {
  final action = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.push_pin_outlined),
            title: Text(book.isPinned ? '取消置顶' : '置顶'),
            onTap: () => Navigator.pop(context, 'pin'),
          ),
          ListTile(
            leading: const Icon(Icons.headphones_outlined),
            title: const Text('开始听书'),
            onTap: () => Navigator.pop(context, 'listen'),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: AppColors.seal),
            title: const Text('从书架删除', style: TextStyle(color: AppColors.seal)),
            onTap: () => Navigator.pop(context, 'delete'),
          ),
        ],
      ),
    ),
  );
  if (action == 'pin') {
    await ref.read(appControllerProvider.notifier).togglePinned(book.id);
  }
  if (action == 'listen' && context.mounted) context.push('/player/${book.id}');
  if (action == 'delete') {
    await ref.read(appControllerProvider.notifier).removeBook(book.id);
  }
}

Future<void> _showMultiSelect(
  BuildContext context,
  WidgetRef ref,
  String initialId,
) async {
  final selected = <String>{initialId};
  final books = ref.read(appControllerProvider).books;
  final action = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => StatefulBuilder(
      builder: (context, setModalState) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .7,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '已选择 ${selected.length} 本',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => setModalState(() {
                        if (selected.length == books.length) {
                          selected.clear();
                        } else {
                          selected.addAll(books.map((book) => book.id));
                        }
                      }),
                      child: Text(
                        selected.length == books.length ? '取消全选' : '全选',
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  itemCount: books.length,
                  itemBuilder: (_, index) {
                    final book = books[index];
                    return CheckboxListTile(
                      value: selected.contains(book.id),
                      title: Text(book.title),
                      subtitle: Text(book.author),
                      secondary: Icon(
                        book.format == BookFormat.pdf
                            ? Icons.picture_as_pdf_outlined
                            : Icons.menu_book_outlined,
                      ),
                      onChanged: (checked) => setModalState(() {
                        checked == true
                            ? selected.add(book.id)
                            : selected.remove(book.id);
                      }),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: selected.isEmpty
                            ? null
                            : () => Navigator.pop(sheetContext, 'pin'),
                        icon: const Icon(Icons.push_pin_outlined),
                        label: const Text('置顶'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.seal,
                        ),
                        onPressed: selected.isEmpty
                            ? null
                            : () => Navigator.pop(sheetContext, 'delete'),
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('删除'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  if (action == 'pin') {
    for (final id in selected) {
      final book = ref
          .read(appControllerProvider)
          .books
          .firstWhere((item) => item.id == id);
      if (!book.isPinned) {
        await ref.read(appControllerProvider.notifier).togglePinned(id);
      }
    }
  } else if (action == 'delete' && context.mounted) {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('删除 ${selected.length} 本书？'),
        content: const Text('书籍将从本地书架移除，相关划线也会一并删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(appControllerProvider.notifier).removeBooks(selected);
    }
  }
}
