import 'package:PiliPlus/pages/listening/lyrics.dart';
import 'package:PiliPlus/pages/listening/song_name.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('title segmentation', () {
    test('splits a bracketed and hyphenated title into candidates', () {
      final parts = titleCandidates('【初音ミク】千本桜-初音ミク');
      expect(parts, contains('千本桜'));
      expect(parts, contains('初音ミク'));
      expect(parts, isNot(contains('初音')));
    });

    test('splits an unspaced Chinese title on the hyphen', () {
      final parts = titleCandidates('周杰伦-晴天');
      expect(parts, contains('晴天'));
      expect(parts, contains('周杰伦'));
      expect(parts, contains('周杰伦-晴天'));
    });

    test('drops generic words and keeps the remaining field', () {
      final parts = titleCandidates('晴天 翻唱 完整版');
      expect(parts, contains('晴天'));
      expect(parts.any((e) => e.contains('翻唱')), isFalse);
      expect(parts.any((e) => e.contains('完整版')), isFalse);
    });

    test('strips HTML highlight before splitting', () {
      final parts = titleCandidates('<em>晴天</em> - 现场版');
      expect(parts, contains('晴天'));
    });
  });

  group('consensus with segmentation', () {
    test('finds the song inside unquoted hyphenated titles', () {
      final result = inferSongName([
        '周杰伦-晴天',
        '周杰伦-晴天 现场',
        '歌手甲-晴天 翻唱',
        '晴天 完整版',
      ]);
      expect(result?.name, '晴天');
    });

    test('finds a Japanese name hidden in brackets', () {
      final result = inferSongName([
        '【初音ミク】千本桜',
        '「千本桜」を歌ってみた',
        '千本桜 - 初音ミク',
        '【千本桜】ピアノ',
      ]);
      expect(result?.name, '千本桜');
    });
  });

  group('traditional Chinese needs no translation', () {
    test('traditional-only names are not translated', () {
      expect(ListeningLyrics.nameLanguage('我們'), isNull);
      expect(ListeningLyrics.nameLanguage('愛你'), isNull);
      expect(ListeningLyrics.nameLanguage('後來'), isNull);
      expect(ListeningLyrics.nameLanguage('說好的幸福呢'), isNull);
    });

    test('simplified Chinese names are not translated', () {
      expect(ListeningLyrics.nameLanguage('我们'), isNull);
      expect(ListeningLyrics.nameLanguage('爱你'), isNull);
      expect(ListeningLyrics.nameLanguage('后来'), isNull);
    });

    test('kanji-only Japanese still uses the Japanese context', () {
      // 純漢字の題名: only the video context proves it is Japanese.
      expect(ListeningLyrics.nameLanguage('夜', context: 'よる に かける'), 'ja');
      expect(ListeningLyrics.nameLanguage('夜'), isNull);
    });

    test('a traditional name with Japanese context stays untranslated', () {
      expect(
        ListeningLyrics.nameLanguage('我們', context: '【歌ってみた】'),
        isNull,
        reason: 'a Chinese name must not be sent as Japanese',
      );
    });

    test('kana and hangul are still detected', () {
      expect(ListeningLyrics.nameLanguage('千本桜'), isNull);
      expect(ListeningLyrics.nameLanguage('さくら'), 'ja');
      expect(ListeningLyrics.nameLanguage('봄날'), 'ko');
      expect(ListeningLyrics.nameLanguage('Lemon'), 'en');
    });

    test('isChinese classifies script correctly', () {
      expect(ListeningLyrics.isChinese('我們'), isTrue);
      expect(ListeningLyrics.isChinese('我们'), isTrue);
      expect(ListeningLyrics.isChinese('さくら'), isFalse);
      expect(ListeningLyrics.isChinese('Lemon'), isFalse);
      expect(ListeningLyrics.isChinese('봄날'), isFalse);
    });
  });
}
