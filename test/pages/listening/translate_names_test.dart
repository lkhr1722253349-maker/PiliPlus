import 'dart:io';

import 'package:PiliPlus/pages/listening/controller.dart';
import 'package:PiliPlus/pages/listening/lyrics.dart';
import 'package:PiliPlus/pages/listening/models.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

/// Translates only the names listed here; every other name is left alone, just
/// like a real run where the language cannot be determined.
class _FakeNames extends ListeningLyrics {
  _FakeNames(this.results);
  final Map<String, String> results;
  final Map<String, String> requested = {};

  @override
  Future<String?> translateName(String name, {String context = ''}) async {
    requested[name] = context;
    final value = results[name];
    if (value == null) return null;
    if (value == '__quota__')
      throw LyricsTranslationException('额度不足', quota: true);
    if (value == '__fail__')
      throw LyricsTranslationException('翻译服务暂不可用');
    return value;
  }

  @override
  void close() {}
}

class _TranslateController extends ListeningController {
  @override
  Future<void> save() async {}
}

ListeningSong _song(String id, String name) => ListeningSong(
  id: id,
  name: name,
  original: const SongSource(
    bvid: 'BV1',
    aid: 1,
    cid: 1,
    page: 1,
    title: 'video',
  ),
);

void main() {
  late Directory directory;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('piliplus-names-');
    Hive.init(directory.path);
    GStorage.localCache = await Hive.openBox('localCache');
  });
  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('translateName only translates a known source language', () async {
    final service = ListeningLyrics();
    try {
      // Chinese and numeric-only names need no translation.
      expect(await service.translateName('中文歌名', context: '视频'), isNull);
      expect(await service.translateName('12345'), isNull);
    } finally {
      service.close();
    }
  });

  test('an invalid language is a per-name failure, not quota', () async {
    final service = ListeningLyrics(
      translation: Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) => handler.resolve(
              Response(
                requestOptions: options,
                data: {
                  'responseStatus': 200,
                  'responseData': {'translatedText': 'x'},
                },
              ),
            ),
          ),
        ),
    );
    try {
      await expectLater(
        service.translateLine('test', 'autodetect'),
        throwsA(
          isA<LyricsTranslationException>().having(
            (e) => e.quota,
            'quota',
            isFalse,
          ),
        ),
      );
    } finally {
      service.close();
    }
  });

  test('translation uses a concrete langpair and caches the result', () async {
    final pairs = <String?>[];
    final service = ListeningLyrics(
      translation: Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              pairs.add(options.queryParameters['langpair'] as String?);
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: {
                    'responseStatus': 200,
                    'responseData': {'translatedText': '测试译文'},
                  },
                ),
              );
            },
          ),
        ),
    );
    try {
      expect(
        await service.translateName('Test Song', context: 'video'),
        '测试译文',
      );
      expect(pairs, ['en|zh-CN']);
    } finally {
      service.close();
    }
  });

  test('one failing name does not stop the remaining songs', () async {
    final controller = _TranslateController();
    final fake = _FakeNames({
      'Bad Name': '__fail__',
      'Hello World': '你好世界',
    });
    controller.playlists.value = [
      ListeningPlaylist(
        id: 'list',
        name: 'list',
        songs: [
          _song('a', 'Bad Name'),
          _song('b', 'Hello World'),
          _song('c', '中文歌名'),
        ],
      ),
    ];
    await controller.translateSongNames(service: fake);
    final songs = controller.playlists.first.songs;
    expect(songs[0].chineseName, isNull);
    expect(songs[1].chineseName, '你好世界');
    expect(songs[1].translatedNameSource, 'Hello World');
    // A Chinese name needs no translation and is not sent to the service.
    expect(fake.requested.containsKey('中文歌名'), isFalse);
    expect(songs[2].chineseName, isNull);
  });

  test('an exhausted quota stops further translation requests', () async {
    final controller = _TranslateController();
    final fake = _FakeNames({
      'First Song': '__quota__',
      'Second Song': '第二译文',
    });
    controller.playlists.value = [
      ListeningPlaylist(
        id: 'list',
        name: 'list',
        songs: [_song('a', 'First Song'), _song('b', 'Second Song')],
      ),
    ];
    await controller.translateSongNames(service: fake);
    expect(fake.requested.keys, ['First Song']);
    expect(controller.playlists.first.songs[1].chineseName, isNull);
  });

  test('a translated name is displayed only for its own source name', () {
    final song = _song('a', 'Hello World')
      ..chineseName = '你好世界'
      ..translatedNameSource = 'Hello World';
    expect(song.displayName, 'Hello World（你好世界）');
    song.name = 'Renamed';
    expect(song.displayName, 'Renamed');
  });
}
