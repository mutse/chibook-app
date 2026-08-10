import 'package:chibook/core/adaptive.dart';
import 'package:test/test.dart';

void main() {
  test('form factor follows Material 3 window size class boundaries', () {
    expect(formFactorOf(0), FormFactor.compact);
    expect(formFactorOf(320), FormFactor.compact);
    expect(formFactorOf(599.9), FormFactor.compact);
    expect(formFactorOf(600), FormFactor.medium);
    expect(formFactorOf(839.9), FormFactor.medium);
    expect(formFactorOf(840), FormFactor.expanded);
    expect(formFactorOf(1366), FormFactor.expanded);
  });

  test('real device widths map to the intended layout', () {
    // iPhone 竖屏 / iPad Slide Over：底栏 + 单栏。
    expect(formFactorOf(393).usesRail, isFalse);
    expect(formFactorOf(320).usesRail, isFalse);
    // iPad mini 竖屏 744、iPad 10.9" 竖屏 820：侧边导航但仍是单栏。
    expect(formFactorOf(744).usesRail, isTrue);
    expect(formFactorOf(744).hasSidebar, isFalse);
    expect(formFactorOf(820).hasSidebar, isFalse);
    // iPad Pro 13" 竖屏 1032、iPad 横屏 1180/1366：常驻侧栏。
    expect(formFactorOf(1032).hasSidebar, isTrue);
    expect(formFactorOf(1180).hasSidebar, isTrue);
    expect(formFactorOf(1366).hasSidebar, isTrue);
  });

  test('reading column is capped on wide windows but fills narrow ones', () {
    expect(readingColumnWidth(390), 390);
    expect(readingColumnWidth(maxReadingColumnWidth), maxReadingColumnWidth);
    expect(readingColumnWidth(1366), maxReadingColumnWidth);
    expect(readingColumnWidth(0), 0);
    expect(readingColumnWidth(-10), 0);
  });
}
