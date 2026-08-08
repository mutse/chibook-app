import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../app/app_state.dart';
import '../../core/models.dart';
import '../../core/theme.dart';

class ReaderPage extends ConsumerWidget {
  const ReaderPage({required this.bookId, super.key});
  final String bookId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final books = ref.watch(appControllerProvider.select((s) => s.books));
    final matches = books.where((e) => e.id == bookId);
    if (matches.isEmpty) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final book = matches.first;
    if (book.format == BookFormat.pdf) return PdfReaderPage(book: book);
    return ReflowReaderPage(book: book);
  }
}

class ReflowReaderPage extends ConsumerStatefulWidget {
  const ReflowReaderPage({required this.book, super.key});
  final Book book;

  @override
  ConsumerState<ReflowReaderPage> createState() => _ReflowReaderPageState();
}

class _ReflowReaderPageState extends ConsumerState<ReflowReaderPage> {
  late final PageController _pages;
  late int _chapter;
  bool _chrome = false;

  @override
  void initState() {
    super.initState();
    _chapter = widget.book.chapterIndex.clamp(
      0,
      widget.book.chapters.length - 1,
    );
    _pages = PageController(initialPage: _chapter);
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appControllerProvider.select((s) => s.settings));
    final background = switch (settings.theme) {
      ReaderTheme.dark => const Color(0xFF1B1A17),
      ReaderTheme.eye => AppColors.eye,
      ReaderTheme.light => AppColors.paper,
    };
    final foreground = switch (settings.theme) {
      ReaderTheme.dark => const Color(0xFFD8D0BE),
      ReaderTheme.eye => AppColors.eyeInk,
      ReaderTheme.light => AppColors.ink,
    };
    return Scaffold(
      backgroundColor: background,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) {
          final width = MediaQuery.sizeOf(context).width;
          if (details.localPosition.dx < width * .25 && _pages.hasClients) {
            _pages.previousPage(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOut,
            );
          } else if (details.localPosition.dx > width * .75 &&
              _pages.hasClients) {
            _pages.nextPage(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOut,
            );
          } else {
            setState(() => _chrome = !_chrome);
          }
        },
        child: Stack(
          children: [
            SafeArea(
              child: PageView.builder(
                controller: _pages,
                itemCount: widget.book.chapters.length,
                onPageChanged: (index) {
                  setState(() => _chapter = index);
                  ref
                      .read(appControllerProvider.notifier)
                      .updateProgress(
                        widget.book.id,
                        index,
                        (index + 1) / widget.book.chapters.length,
                      );
                },
                itemBuilder: (_, index) => _ChapterPage(
                  bookId: widget.book.id,
                  chapter: widget.book.chapters[index],
                  chapterIndex: index,
                  settings: settings,
                  color: foreground,
                  page: index + 1,
                  count: widget.book.chapters.length,
                ),
              ),
            ),
            if (settings.brightness < 1)
              Positioned.fill(
                child: IgnorePointer(
                  child: ColoredBox(
                    color: Colors.black.withValues(
                      alpha: (1 - settings.brightness) * .62,
                    ),
                  ),
                ),
              ),
            _ReaderTopBar(
              visible: _chrome,
              title: widget.book.chapters[_chapter].title,
              onBack: () => context.pop(),
              onContents: _showContents,
            ),
            _ReaderBottomBar(
              visible: _chrome,
              onContents: _showContents,
              onSettings: _showSettings,
            ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 240),
              right: 16,
              bottom: _chrome ? 104 : 30,
              child: FloatingActionButton.extended(
                heroTag: 'listen-${widget.book.id}',
                onPressed: () => context.push('/player/${widget.book.id}'),
                backgroundColor: AppColors.bamboo,
                foregroundColor: Colors.white,
                icon: const Icon(Icons.play_arrow_rounded, size: 19),
                label: const Text('听书'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showContents() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: widget.book.chapters.length,
          itemBuilder: (_, index) => ListTile(
            selected: index == _chapter,
            selectedColor: AppColors.seal,
            leading: Text('${index + 1}'.padLeft(2, '0')),
            title: Text(widget.book.chapters[index].title),
            trailing: index == _chapter
                ? const Icon(Icons.bookmark, color: AppColors.seal)
                : null,
            onTap: () {
              Navigator.pop(context);
              _pages.animateToPage(
                index,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
              );
            },
          ),
        ),
      ),
    );
  }

  void _showSettings() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => const _ReaderSettingsSheet(),
    );
  }
}

class _ChapterPage extends StatelessWidget {
  const _ChapterPage({
    required this.bookId,
    required this.chapter,
    required this.chapterIndex,
    required this.settings,
    required this.color,
    required this.page,
    required this.count,
  });
  final String bookId;
  final Chapter chapter;
  final int chapterIndex;
  final ReaderSettings settings;
  final Color color;
  final int page;
  final int count;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(25, 58, 25, 22),
    child: Column(
      children: [
        Text(
          chapter.title,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.w800,
            fontSize: settings.fontSize + 2,
          ),
        ),
        const SizedBox(height: 24),
        Expanded(
          child: SingleChildScrollView(
            child: SelectableText(
              chapter.content,
              contextMenuBuilder: (context, editableState) {
                final selection = editableState.textEditingValue.selection;
                Future<void> save({required bool withNote}) async {
                  if (!selection.isValid || selection.isCollapsed) return;
                  final start = selection.start.clamp(
                    0,
                    chapter.content.length,
                  );
                  final end = selection.end.clamp(
                    start,
                    chapter.content.length,
                  );
                  final excerpt = chapter.content.substring(start, end);
                  String? note;
                  if (withNote) {
                    note = await _requestNote(context);
                    if (note == null || !context.mounted) return;
                  }
                  await ProviderScope.containerOf(context)
                      .read(appControllerProvider.notifier)
                      .addHighlight(
                        bookId: bookId,
                        excerpt: excerpt,
                        location: ReadingLocation.text(
                          chapterIndex: chapterIndex,
                          startOffset: start,
                          endOffset: end,
                        ),
                        note: note,
                      );
                  editableState.hideToolbar();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(withNote ? '笔记已保存' : '划线已保存')),
                    );
                  }
                }

                return AdaptiveTextSelectionToolbar.buttonItems(
                  anchors: editableState.contextMenuAnchors,
                  buttonItems: [
                    ...editableState.contextMenuButtonItems,
                    ContextMenuButtonItem(
                      label: '划线',
                      onPressed: () => save(withNote: false),
                    ),
                    ContextMenuButtonItem(
                      label: '笔记',
                      onPressed: () => save(withNote: true),
                    ),
                  ],
                );
              },
              style: TextStyle(
                color: color,
                fontSize: settings.fontSize,
                height: settings.lineHeight,
                letterSpacing: .35,
              ),
            ),
          ),
        ),
        Text(
          '$page / $count',
          style: TextStyle(color: color.withValues(alpha: .52), fontSize: 10),
        ),
      ],
    ),
  );
}

class _ReaderTopBar extends StatelessWidget {
  const _ReaderTopBar({
    required this.visible,
    required this.title,
    required this.onBack,
    required this.onContents,
  });
  final bool visible;
  final String title;
  final VoidCallback onBack;
  final VoidCallback onContents;

  @override
  Widget build(BuildContext context) => AnimatedPositioned(
    duration: const Duration(milliseconds: 240),
    left: 0,
    right: 0,
    top: visible ? 0 : -110,
    child: Material(
      color: Theme.of(context).scaffoldBackgroundColor.withValues(alpha: .97),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 58,
          child: Row(
            children: [
              IconButton(
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back_ios_new, size: 19),
              ),
              Expanded(
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                onPressed: onContents,
                icon: const Icon(Icons.more_horiz),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _ReaderBottomBar extends StatelessWidget {
  const _ReaderBottomBar({
    required this.visible,
    required this.onContents,
    required this.onSettings,
  });
  final bool visible;
  final VoidCallback onContents;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) => AnimatedPositioned(
    duration: const Duration(milliseconds: 240),
    left: 0,
    right: 0,
    bottom: visible ? 0 : -130,
    child: Material(
      color: Theme.of(context).cardColor,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 78,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _ReaderAction(
                icon: Icons.format_list_bulleted,
                label: '目录',
                onTap: onContents,
              ),
              _ReaderAction(
                icon: Icons.brightness_6_outlined,
                label: '亮度',
                onTap: onSettings,
              ),
              _ReaderAction(
                icon: Icons.text_fields,
                label: '设置',
                onTap: onSettings,
              ),
              _ReaderAction(
                icon: Icons.brightness_2_outlined,
                label: '主题',
                onTap: onSettings,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _ReaderAction extends StatelessWidget {
  const _ReaderAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkResponse(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 21),
          const SizedBox(height: 5),
          Text(label, style: const TextStyle(fontSize: 10)),
        ],
      ),
    ),
  );
}

class _ReaderSettingsSheet extends ConsumerWidget {
  const _ReaderSettingsSheet();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appControllerProvider.select((s) => s.settings));
    final controller = ref.read(appControllerProvider.notifier);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('字号', style: TextStyle(fontWeight: FontWeight.w700)),
            Row(
              children: [
                const Text('A', style: TextStyle(fontSize: 13)),
                Expanded(
                  child: Slider(
                    value: settings.fontSize,
                    min: 14,
                    max: 24,
                    onChanged: (v) =>
                        controller.setSettings(settings.copyWith(fontSize: v)),
                  ),
                ),
                const Text('A', style: TextStyle(fontSize: 23)),
              ],
            ),
            const SizedBox(height: 8),
            const Text('亮度', style: TextStyle(fontWeight: FontWeight.w700)),
            Row(
              children: [
                const Icon(Icons.brightness_low_outlined, size: 18),
                Expanded(
                  child: Slider(
                    value: settings.brightness,
                    min: .35,
                    max: 1,
                    onChanged: (value) => controller.setSettings(
                      settings.copyWith(brightness: value),
                    ),
                  ),
                ),
                const Icon(Icons.brightness_high_outlined, size: 18),
              ],
            ),
            const SizedBox(height: 8),
            const Text('行距', style: TextStyle(fontWeight: FontWeight.w700)),
            Slider(
              value: settings.lineHeight,
              min: 1.45,
              max: 2.35,
              onChanged: (v) =>
                  controller.setSettings(settings.copyWith(lineHeight: v)),
            ),
            const SizedBox(height: 8),
            const Text('主题', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            Row(
              children: ReaderTheme.values
                  .map(
                    (theme) => Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: _ThemeChoice(
                          theme: theme,
                          selected: theme == settings.theme,
                          onTap: () => controller.setSettings(
                            settings.copyWith(theme: theme),
                          ),
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }
}

class _ThemeChoice extends StatelessWidget {
  const _ThemeChoice({
    required this.theme,
    required this.selected,
    required this.onTap,
  });
  final ReaderTheme theme;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final (label, color, foreground) = switch (theme) {
      ReaderTheme.light => ('日间', AppColors.paper, AppColors.ink),
      ReaderTheme.dark => (
        '夜间',
        const Color(0xFF1B1A17),
        const Color(0xFFD8D0BE),
      ),
      ReaderTheme.eye => ('护眼', AppColors.eye, AppColors.eyeInk),
    };
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? AppColors.seal : Colors.transparent,
            width: 2,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(color: foreground, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}

Future<String?> _requestNote(BuildContext context) async {
  final controller = TextEditingController();
  final result = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('添加笔记'),
      content: TextField(
        controller: controller,
        autofocus: true,
        minLines: 2,
        maxLines: 5,
        decoration: const InputDecoration(hintText: '写下此刻的想法…'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final value = controller.text.trim();
            if (value.isNotEmpty) Navigator.pop(dialogContext, value);
          },
          child: const Text('保存'),
        ),
      ],
    ),
  );
  controller.dispose();
  return result;
}

class PdfReaderPage extends ConsumerStatefulWidget {
  const PdfReaderPage({required this.book, super.key});
  final Book book;

  @override
  ConsumerState<PdfReaderPage> createState() => _PdfReaderPageState();
}

class _PdfReaderPageState extends ConsumerState<PdfReaderPage> {
  int _pageCount = 1;

  Book get book => widget.book;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(book.title),
      actions: [
        IconButton(
          tooltip: '听书',
          onPressed: () {
            if (book.chapters.isNotEmpty) {
              context.push('/player/${book.id}');
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('此 PDF 未提取到文本；扫描版 PDF 暂不支持听书。')),
              );
            }
          },
          icon: const Icon(Icons.headphones_outlined),
        ),
      ],
    ),
    body: book.filePath == null
        ? const Center(child: Text('PDF 文件路径不可用'))
        : Stack(
            children: [
              PdfViewer.file(
                book.filePath!,
                initialPageNumber: book.chapterIndex + 1,
                params: PdfViewerParams(
                  onViewerReady: (document, _) {
                    if (mounted) {
                      setState(() => _pageCount = document.pages.length);
                    }
                  },
                  onPageChanged: (pageNumber) {
                    if (pageNumber == null) return;
                    ref
                        .read(appControllerProvider.notifier)
                        .updateProgress(
                          book.id,
                          pageNumber - 1,
                          (pageNumber / _pageCount).clamp(0, 1),
                        );
                  },
                ),
              ),
              Positioned(
                left: 14,
                right: 14,
                bottom: 14,
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'PDF 为固定版式：支持缩放与翻页，不提供字号和行距调整。',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
  );
}
