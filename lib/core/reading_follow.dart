import 'models.dart';

/// 让当前朗读行停在视口上方约三分之一处，同时保证目标不越过滚动边界。
double readingFollowScrollTarget({
  required double contentOffset,
  required double minScrollExtent,
  required double maxScrollExtent,
  required double viewportDimension,
  double viewportAlignment = .32,
}) => (contentOffset - viewportDimension * viewportAlignment)
    .clamp(minScrollExtent, maxScrollExtent)
    .toDouble();

/// 从当前章节向 [direction] 方向寻找下一章可朗读文本。
///
/// PDF 的封面、插图和空白页通常没有文字层。连续播放遇到这些页面时应跳过，
/// 而不是用“当前章节没有可朗读文本”中断整本书。
int? nextReadableChapterIndex(
  List<Chapter> chapters, {
  required int currentIndex,
  required int direction,
}) {
  if (chapters.isEmpty || direction == 0) return null;
  var index = currentIndex + direction.sign;
  while (index >= 0 && index < chapters.length) {
    if (chapters[index].content.trim().isNotEmpty) return index;
    index += direction.sign;
  }
  return null;
}
