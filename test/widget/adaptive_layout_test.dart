import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chibook/core/adaptive.dart';

/// 三档约束下的骨架验证。
///
/// 阅读器、播放器和 AppShell 都直接引用全局 `ttsAudioHandler`，而它由
/// `main()` 中的 `AudioService.init` 赋值，在纯 widget 测试里不可用；
/// 这里先覆盖不依赖播放链路的自适应基元，避免为了测试去动"单一播放源"。
Widget _probe({required void Function(FormFactor form) onBuild}) => MaterialApp(
  home: LayoutBuilder(
    builder: (context, constraints) {
      // 与 AppShell 相同：单个顶层 LayoutBuilder 按约束宽度在两套
      // Scaffold 之间选择，不依赖 MediaQuery 全屏尺寸。
      final form = formFactorOf(constraints.maxWidth);
      onBuild(form);
      const destinations = [
        (icon: Icons.menu_book_outlined, label: '阅读'),
        (icon: Icons.auto_stories_outlined, label: '书架'),
      ];
      final content = Center(
        child: SizedBox(
          width: readingColumnWidth(
            form.usesRail ? constraints.maxWidth - 80 : constraints.maxWidth,
          ),
          child: const Text('正文'),
        ),
      );
      if (!form.usesRail) {
        return Scaffold(
          body: content,
          bottomNavigationBar: NavigationBar(
            destinations: [
              for (final item in destinations)
                NavigationDestination(
                  icon: Icon(item.icon),
                  label: item.label,
                ),
            ],
          ),
        );
      }
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: 0,
              extended: form == FormFactor.expanded,
              minExtendedWidth: 168,
              destinations: [
                for (final item in destinations)
                  NavigationRailDestination(
                    icon: Icon(item.icon),
                    label: Text(item.label),
                  ),
              ],
            ),
            Expanded(child: content),
          ],
        ),
      );
    },
  ),
);

void main() {
  Future<FormFactor> pumpAt(WidgetTester tester, Size size) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late FormFactor observed;
    await tester.pumpWidget(_probe(onBuild: (form) => observed = form));
    await tester.pumpAndSettle();
    return observed;
  }

  testWidgets('compact keeps the bottom bar and no rail', (tester) async {
    final form = await pumpAt(tester, const Size(390, 844));

    expect(form, FormFactor.compact);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('medium swaps the bottom bar for a rail', (tester) async {
    final form = await pumpAt(tester, const Size(768, 1024));

    expect(form, FormFactor.medium);
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('expanded extends the rail and caps the reading column', (
    tester,
  ) async {
    final form = await pumpAt(tester, const Size(1366, 1024));

    expect(form, FormFactor.expanded);
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    final column = tester.getSize(find.text('正文'));
    expect(column.width, lessThanOrEqualTo(maxReadingColumnWidth));
    expect(tester.takeException(), isNull);
  });

  testWidgets('iPad Split View 1/3 degrades back to the compact layout', (
    tester,
  ) async {
    // Slide Over / 1/3 分屏窗口只有 ~320dp 宽，必须退回手机形态而不是
    // 因为"设备是 iPad"就继续用 rail。
    final form = await pumpAt(tester, const Size(320, 1024));

    expect(form, FormFactor.compact);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('resizing from expanded to compact rebuilds without error', (
    tester,
  ) async {
    await pumpAt(tester, const Size(1180, 820));
    expect(find.byType(NavigationRail), findsOneWidget);

    // 模拟 iPad 旋转 / 拖动分屏分隔条。
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
