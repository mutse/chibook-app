import 'package:chibook/core/pdf_text.dart';
import 'package:test/test.dart';

String _repeat(int codePoint, int count) =>
    String.fromCharCode(codePoint) * count;

/// 字体缺 ToUnicode CMap 时 PDFium 逐字返回 0，整页文本就是这个样子。
final _nulPage = '${_repeat(0, 40)}\n${_repeat(0, 36)}';

/// 私用区码点：ToUnicode 存在但指向自造区，复制出来同样不可读。
final _privateUsePage = _repeat(0xe600, 12);

const _replacement = '�';
const _zeroWidthSpace = '​';
const _byteOrderMark = '﻿';

void main() {
  group('isGarbledPdfText', () {
    test('flags a page whose font has no ToUnicode CMap', () {
      // 旧实现只看 isEmpty，这种页面会被当成正文存下来。
      expect(_nulPage.trim().isEmpty, isFalse);
      expect(isGarbledPdfText(_nulPage), isTrue);
    });

    test('flags text mapped into the private use area', () {
      expect(isGarbledPdfText(_privateUsePage), isTrue);
      expect(isGarbledPdfText(String.fromCharCode(0xf0000) * 6), isTrue);
    });

    test('flags replacement characters and stray control codes', () {
      expect(isGarbledPdfText(_replacement * 4), isTrue);
      expect(isGarbledPdfText(_repeat(0x01, 5)), isTrue);
    });

    test('flags text made of extension-block ideographs', () {
      // 映射错位常把正文落到扩展区，正常中文书里不会成片出现这些字。
      final extension = String.fromCharCodes([0x3400, 0x3401, 0x4dbf, 0x20000]);
      expect(isGarbledPdfText(extension), isTrue);
    });

    test('keeps ordinary Chinese pages', () {
      expect(
        isGarbledPdfText('第一章 溪边的白塔静静立着，渡船随水波轻轻晃动。\n茶峒地方凭水依山筑城。'),
        isFalse,
      );
    });

    test('tolerates a few special glyphs inside a good page', () {
      final body = '溪边的白塔静静立着，渡船随水波轻轻晃动，像是在等一个迟迟未归的人。' * 3;
      expect(isGarbledPdfText('$body${_repeat(0xe600, 2)}'), isFalse);
    });

    test('flags a long Chinese page that has no punctuation at all', () {
      // CMap 整体错位：映射出的全是合法汉字，但连标点都变成了汉字。
      final scrambled = '蹴罅骈氅犒糅畲耨镤黻鬻纛饕' * 12;
      expect(scrambled.length, greaterThan(100));
      expect(isGarbledPdfText(scrambled), isTrue);
    });

    test('keeps an unpunctuated line that is merely short', () {
      // 标题、书名和目录条目没有标点很正常，不能因此判定乱码。
      expect(isGarbledPdfText('茶峒地方凭水依山筑城'), isFalse);
    });

    test('keeps a long Chinese page that is normally punctuated', () {
      final prose = '溪边的白塔静静立着，渡船随水波轻轻晃动，像是在等一个迟迟未归的人。' * 5;
      expect(isGarbledPdfText(prose), isFalse);
    });

    test('keeps ordinary Latin pages', () {
      expect(
        isGarbledPdfText(
          'I went to the woods because I wished to live deliberately, '
          'to front only the essential facts of life.',
        ),
        isFalse,
      );
    });

    test('reports an empty page as not garbled', () {
      expect(isGarbledPdfText(''), isFalse);
      expect(isGarbledPdfText('   \n\n  '), isFalse);
    });
  });

  group('cleanPdfPageText', () {
    test('drops unmapped characters instead of storing them as text', () {
      expect(cleanPdfPageText(_nulPage), '');
      expect(cleanPdfPageText(_privateUsePage), '');
      expect(cleanPdfPageText(_replacement * 3), '');
    });

    test('drops invisible characters', () {
      expect(
        cleanPdfPageText('$_byteOrderMark近山的一面$_zeroWidthSpace，城墙俨然如一条长蛇。'),
        '近山的一面，城墙俨然如一条长蛇。',
      );
    });

    test('removes the spaces PDFium inserts between ideographs', () {
      expect(cleanPdfPageText('溪 边 的 白 塔 静 静 立 着'), '溪边的白塔静静立着');
      expect(cleanPdfPageText('渡船 随水波 轻轻晃动 ，像是 在等人。'), '渡船随水波轻轻晃动，像是在等人。');
    });

    test('keeps spaces between Latin words', () {
      expect(cleanPdfPageText('I  went   to the woods'), 'I went to the woods');
      expect(cleanPdfPageText('见 Walden 第 3 页'), '见 Walden 第 3 页');
    });

    test('normalizes CRLF without inventing a paragraph break', () {
      expect(cleanPdfPageText('第一段结束。\r\n第二段开始。'), '第一段结束。\n第二段开始。');
      expect(cleanPdfPageText('单独回车。\r下一行。'), '单独回车。\n下一行。');
    });

    test('joins lines that the page layout cut mid-sentence', () {
      const raw =
          '那一年江南的雨下得格外久，檐角滴水的声音像是数不尽\n'
          '的更漏。院中的海棠开得静默，无人问起。';
      expect(
        cleanPdfPageText(raw),
        '那一年江南的雨下得格外久，檐角滴水的声音像是数不尽的更漏。院中的海棠开得静默，无人问起。',
      );
    });

    test('keeps the break after a finished sentence', () {
      const raw =
          '院中的海棠开得静默，无人问起，也无人叹惜。\n'
          '他在灯下坐了许久，将旧稿又翻了一遍。';
      expect(cleanPdfPageText(raw), raw);
    });

    test('does not glue short headings or page numbers onto the body', () {
      const raw =
          '第三回\n'
          '12\n'
          '那一年江南的雨下得格外久，檐角滴水的声音像是数不尽的更漏';
      expect(cleanPdfPageText(raw), raw);
    });

    test('joins wrapped Latin lines with a space', () {
      const raw = 'I went to the woods because I wished to live\ndeliberately.';
      expect(
        cleanPdfPageText(raw),
        'I went to the woods because I wished to live deliberately.',
      );
    });

    test('collapses runs of blank lines but keeps paragraph breaks', () {
      expect(cleanPdfPageText('第一段。\n\n\n\n第二段。'), '第一段。\n\n第二段。');
    });

    test('is idempotent', () {
      const raw =
          '那一年江南的雨下得格外久，檐角 滴水的声音\r\n'
          '像是数不尽的更漏。\n\n\n院中的海棠开得静 默。';
      final once = cleanPdfPageText(raw);
      expect(cleanPdfPageText(once), once);
    });
  });
}
