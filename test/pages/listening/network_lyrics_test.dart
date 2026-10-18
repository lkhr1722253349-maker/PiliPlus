import 'package:PiliPlus/pages/listening/lyrics.dart';
import 'package:PiliPlus/pages/listening/models.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const english =
      '[00:01]first synthetic lyric line\n[00:10]second synthetic lyric line\n[00:20]third synthetic lyric line\n[00:30]fourth synthetic lyric line\n[00:40]fifth synthetic lyric line\n[00:50]sixth synthetic lyric line';
  ListeningSong song(String name) => ListeningSong(
    id: 'test',
    name: name,
    original: const SongSource(
      bvid: 'BV1',
      aid: 1,
      cid: 1,
      page: 1,
      title: 'video',
    ),
  );

  test(
    'rejects sparse, wrong language and wrong duration automatic lyrics',
    () {
      expect(
        plausibleSongLyrics(song('test'), lrcLines('[00:01]hello'), ''),
        isFalse,
      );
      expect(plausibleSongLyrics(song('テスト'), lrcLines(english), ''), isFalse);
      expect(
        plausibleSongLyrics(
          song('test'),
          lrcLines(english),
          '',
          duration: const Duration(seconds: 60),
          candidateDuration: 180,
        ),
        isFalse,
      );
      expect(
        plausibleSongLyrics(
          song('test'),
          lrcLines(english),
          '',
          duration: const Duration(seconds: 60),
          candidateDuration: 60,
        ),
        isTrue,
      );
    },
  );

  test(
    'music platform search obtains synced lyrics using original query',
    () async {
      final requests = <RequestOptions>[];
      final music = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requests.add(options);
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: options.path.endsWith('/get')
                      ? {
                          'result': {
                            'songs': [
                              {
                                'id': 123,
                                'name': 'test song',
                                'duration': 60000,
                                'artists': [
                                  {'name': 'Test artist'},
                                ],
                              },
                              {'id': 456, 'name': 'unavailable song'},
                            ],
                          },
                        }
                      : options.queryParameters['id'] == 123
                      ? {
                          'lrc': {'lyric': english},
                          'tlyric': {'lyric': '[00:01]第一句中文'},
                        }
                      : {'nolyric': true},
                ),
              );
            },
          ),
        );
      final search = LyricsSearch(music: music);
      final found = await search.search('test song');
      expect(requests.first.queryParameters['s'], 'test song');
      expect(found.single.provider, '网易云音乐');
      expect(found.single.artist, 'Test artist');
      expect(found.single.duration, 60);
      expect(lrcLines(found.single.lrc).length, 6);
      expect(lrcLines(found.single.translatedLrc).single.text, '第一句中文');
      search.close();
    },
  );

  test('manual lyric confirmation survives persistence', () {
    const track = LyricTrack(
      label: 'chosen',
      source: '网易云音乐',
      lines: [],
      priority: 0,
      confirmed: true,
    );
    expect(LyricTrack.fromJson(track.toJson()).confirmed, isTrue);
  });
  test('duplicate original song releases do not block matching a full-length video', () {
    final full = english.replaceAll('[00:50]', '[02:50]');
    LyricCandidate version(String artist, int duration, String lrc) =>
        LyricCandidate({
          'trackName': '壱雫空',
          'artistName': artist,
          'duration': duration,
          'syncedLyrics': lrc,
        });
    final candidates = [
      version('MyGO!!!!!', 190, full),
      version('MyGO!!!!!', 190, full),
      version('Cover artist', 85, english),
    ];
    expect(
      selectSongLyrics(
        song('壱雫空'),
        candidates,
        duration: const Duration(seconds: 190),
      )?.artist,
      'MyGO!!!!!',
    );
    expect(selectSongLyrics(song('壱雫空'), candidates), isNull);
    expect(
      selectSongLyrics(
        song('different song'),
        candidates,
        duration: const Duration(seconds: 190),
      ),
      isNull,
    );
  });
  test('bilingual timestamps align without shifting missing translations', () {
    final lines = bilingualLines(
      lrcLines('[00:01]first\n[00:03]second\n[00:05]third'),
      lrcLines('[00:01.010]第一句\n[00:05]第三句'),
    );
    expect(lines.map((e) => e.translation), ['第一句', '', '第三句']);
    final original = LyricTrack(
      label: 'original',
      source: 'test',
      lines: lines,
    );
    expect(
      LyricTrack.fromJson(original.toJson()).lines.first.translation,
      '第一句',
    );
    final translated = LyricTrack(
      label: 'translated',
      source: 'test',
      original: original,
      lines: lrcLines('[00:01]第一句\n[00:03]第二句\n[00:05]第三句'),
      priority: 1,
    );
    expect(translated.displayLines.map((e) => e.text), [
      'first',
      'second',
      'third',
    ]);
    expect(translated.displayLines[1].translation, '第二句');
  });
}
