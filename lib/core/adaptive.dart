import 'package:flutter/material.dart';

/// Material 3 window size class。
///
/// 判定一律基于**当前窗口宽度**（`LayoutBuilder` 的约束宽），不是物理屏幕宽度：
/// iPad Split View 下窗口宽 != 屏幕宽，用 `MediaQuery.sizeOf(context).width`
/// 会把 1/3 分屏误判成大屏。
enum FormFactor {
  /// < 600dp：手机竖屏、iPad Slide Over。底部导航，单栏。
  compact,

  /// 600–839dp：手机横屏、小尺寸 iPad 竖屏、Split View 1/2。侧边导航，单栏限宽。
  medium,

  /// >= 840dp：iPad 横屏、平板横屏、展开态折叠屏。侧边导航展开，常驻侧栏。
  expanded;

  bool get isCompact => this == FormFactor.compact;

  /// 是否使用侧边导航栏（`NavigationRail`）取代底部 `NavigationBar`。
  bool get usesRail => this != FormFactor.compact;

  /// 是否呈现常驻侧栏（阅读器目录/划线）。
  bool get hasSidebar => this == FormFactor.expanded;
}

const double _mediumBreakpoint = 600;
const double _expandedBreakpoint = 840;

/// 纯函数便于单测；调用方传入约束宽度而非 `BuildContext`。
FormFactor formFactorOf(double width) {
  if (width >= _expandedBreakpoint) return FormFactor.expanded;
  if (width >= _mediumBreakpoint) return FormFactor.medium;
  return FormFactor.compact;
}

/// 正文最大行宽。超过这个宽度中文正文一行字数过多，回视困难。
const double maxReadingColumnWidth = 680;

/// 在 [available] 宽度内计算正文列宽：窄屏占满，宽屏限宽并留出对称页边距。
double readingColumnWidth(double available) {
  if (available <= 0) return 0;
  if (available <= maxReadingColumnWidth) return available;
  return maxReadingColumnWidth;
}

/// 弹层在大屏改为对话框。
///
/// compact 保持底部弹层；medium/expanded 用居中对话框，避免出现横贯 iPad
/// 整个宽度的 sheet，也避免按屏幕高度百分比定高在分屏下比例失真。
Future<T?> showAdaptiveSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool scrollable = false,
  Color? backgroundColor,
  double dialogWidth = 460,
  double dialogMaxHeight = 620,
}) {
  final form = formFactorOf(MediaQuery.sizeOf(context).width);
  if (form.isCompact) {
    return showModalBottomSheet<T>(
      context: context,
      showDragHandle: true,
      isScrollControlled: scrollable,
      backgroundColor: backgroundColor,
      // 滚动型弹层限制最大高度而不是写死屏幕百分比。
      constraints: scrollable
          ? BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .82)
          : null,
      builder: builder,
    );
  }
  return showDialog<T>(
    context: context,
    builder: (dialogContext) => Dialog(
      backgroundColor: backgroundColor,
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: dialogWidth,
          maxHeight: dialogMaxHeight,
        ),
        child: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: builder(dialogContext),
        ),
      ),
    ),
  );
}
