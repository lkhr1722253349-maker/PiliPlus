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
}
