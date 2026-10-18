import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/models_new/video/video_tag/data.dart';
import 'package:PiliPlus/pages/listening/lyrics.dart';
import 'package:PiliPlus/pages/listening/models.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

void main() {
  test('song name uses BGM tags and ignores ambiguous category tags', () {
    expect(
      songTagName([VideoTagItem(tagName: '发现测试曲', tagType: 'bgm')], '视频'),
      '测试曲',
    );
    expect(
      songTagName([
        VideoTagItem(tagName: '音乐'),
        VideoTagItem(tagName: '翻唱'),
      ], '音乐翻唱'),
      isNull,
    );
    expect(songTagName([VideoTagItem(tagName: '测试曲')], '歌手《测试曲》现场'), '测试曲');
  });
  test('LRC timestamps support repeated lines, fractions and silent intro', () {
    final lines = lrcLines(
      '[ar:synthetic test]\n[00:01.2][00:03.025]test line\n[00:05]last',
    );
    expect(lines.map((e) => e.start.inMilliseconds), [1200, 3025, 5000]);
    expect(lyricIndex(lines, const Duration(seconds: 1), Duration.zero), -1);
    expect(lyricIndex(lines, const Duration(seconds: 4), Duration.zero), 1);
    expect(
      lyricIndex(lines, const Duration(seconds: 4), const Duration(seconds: 2)),
      0,
    );
  });
  test('subtitle gaps have no active lyric', () {
    final lines = subtitleLines([
      {'from': 1.5, 'to': 2, 'content': 'synthetic'},
      {'from': 4, 'to': 5, 'content': 'test'},
    ]);
    expect(lyricIndex(lines, const Duration(seconds: 3), Duration.zero), -1);
  });
  test('translation splits on Unicode boundaries under 500 bytes', () {
    final text = List.filled(400, 'あ😀').join();
    final parts = ListeningLyrics.chunks(text);
    expect(parts.join(), text);
    expect(parts.every((e) => utf8.encode(e).length <= 450), isTrue);
  });
  test(
    'translations survive service restart and failures are not cached',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'listening-lyrics-',
      );
      Hive.init(directory.path);
      GStorage.localCache = await Hive.openBox('localCache');
      var calls = 0;
      var fail = false;
      Dio client() => Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              calls++;
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: {
                    'responseStatus': fail ? 429 : 200,
                    'responseData': {'translatedText': '测试译文'},
                  },
                ),
              );
            },
          ),
        );
      final first = ListeningLyrics(translation: client());
      expect(await first.translateLine('synthetic test', 'en'), '测试译文');
      first.close();
      final second = ListeningLyrics(translation: client());
      expect(await second.translateLine('synthetic test', 'en'), '测试译文');
      expect(calls, 1);
      fail = true;
      await expectLater(
        second.translateLine('another test', 'en'),
        throwsStateError,
      );
      fail = false;
      expect(await second.translateLine('another test', 'en'), '测试译文');
      expect(calls, 3);
      const original = LyricTrack(
        label: 'original',
        source: 'test',
        lines: [LyricLine(Duration.zero, 'synthetic')],
        priority: 0,
        confirmed: true,
      );
      const translated = LyricTrack(
        label: 'translated',
        source: 'test',
        lines: [LyricLine(Duration.zero, '测试')],
        priority: 1,
        original: original,
      );
      final song = ListeningSong(
        id: '1',
        name: 'test',
        original: const SongSource(
          bvid: 'BV1',
          aid: 1,
          cid: 1,
          page: 1,
          title: 'test',
        ),
      );
      await second.save(song, original);
      await second.save(song, translated);
      expect(second.saved(song)?.priority, 0);
      expect(
        second.saved(song, translation: true)?.original?.lines.single.text,
        'synthetic',
      );
      const subtitle = LyricTrack(
        label: 'old subtitle',
        source: 'video',
        lines: [],
      );
      await second.save(song, subtitle);
      expect(second.saved(song), isNull);
      await second.save(
        song,
        const LyricTrack(
          label: 'old subtitle translation',
          source: 'video',
          lines: [],
          priority: 1,
          original: subtitle,
        ),
      );
      expect(second.saved(song, translation: true), isNull);
      second.close();
      await Hive.close();
      await directory.delete(recursive: true);
    },
  );
}
