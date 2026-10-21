import 'dart:io';

import 'package:PiliPlus/pages/listening/controller.dart';
import 'package:PiliPlus/pages/listening/lyrics.dart';
import 'package:PiliPlus/pages/listening/models.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

/// Serves saved tracks per song name and records every search, so a test can
/// prove when the lyrics were re-matched.
class _StubLyrics extends ListeningLyrics {
  final Map<String, LyricTrack> tracks = {};
  final List<String> searches = [];
  int preferredCalls = 0;

  @override
  Future<LyricTrack?> preferred(
    ListeningSong song, {
    Duration duration = Duration.zero,
    Duration Function()? currentDuration,
  }) async {
    preferredCalls++;
    searches.add(song.name);
    return tracks[song.name];
  }

  @override
  void close() {}
}

class _LyricsController extends ListeningController {
  _LyricsController(this.stub);
  final _StubLyrics stub;
  @override
  ListeningLyrics Function() get newLyrics => () => stub;
}

LyricTrack _track(String name) => LyricTrack(
  label: name,
  source: name,
  lines: [LyricLine(Duration.zero, '$name 第一句')],
  priority: 0,
  matchVersion: 1,
);

ListeningSong _song(String id, String name) => ListeningSong(
  id: id,
  name: name,
  original: SongSource(
    bvid: 'BV$id',
    aid: id.hashCode,
    cid: 1,
    page: 1,
    title: name,
  ),
);

void main() {
  late Directory directory;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('piliplus-lyrics-auto-');
    Hive.init(directory.path);
    GStorage.localCache = await Hive.openBox('localCache');
  });
  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test(
    'switching songs replaces the three-line lyrics automatically',
    () async {
      final stub = _StubLyrics();
      stub.tracks['第一首'] = _track('第一首');
      stub.tracks['第二首'] = _track('第二首');
      final controller = _LyricsController(stub);
      final first = _song('a', '第一首');
      final second = _song('b', '第二首');
      controller.playlists.value = [
        ListeningPlaylist(
          id: 'list',
          name: 'list',
          songs: [first, second],
        ),
      ];

      controller.current.value = first;
      await controller.loadCurrentLyrics();
      expect(controller.activeLyrics.value?.lines.single.text, '第一首 第一句');

      controller.current.value = second;
      await controller.loadCurrentLyrics();
      expect(controller.activeLyrics.value?.lines.single.text, '第二首 第一句');
      expect(stub.searches, ['第一首', '第二首']);
    },
  );

  test('a renamed song is re-matched instead of keeping old lyrics', () async {
    final stub = _StubLyrics();
    stub.tracks['视频标题'] = _track('视频标题');
    stub.tracks['真实歌名'] = _track('真实歌名');
    final controller = _LyricsController(stub);
    final song = _song('a', '视频标题');
    controller.playlists.value = [
      ListeningPlaylist(id: 'list', name: 'list', songs: [song]),
    ];
    controller.current.value = song;
    await controller.loadCurrentLyrics();
    expect(stub.preferredCalls, 1);

    song.name = '真实歌名';
    await controller.save();
    await Future<void>.delayed(Duration.zero);
    expect(stub.preferredCalls, 2);
    expect(stub.searches.last, '真实歌名');
  });

  test('reloading the same song keeps its lines visible', () async {
    final stub = _StubLyrics();
    stub.tracks['歌曲'] = _track('歌曲');
    final controller = _LyricsController(stub);
    final song = _song('a', '歌曲');
    controller.current.value = song;
    await controller.loadCurrentLyrics();
    expect(controller.activeLyrics.value, isNotNull);
    // A second load (e.g. duration retry) must not blank the display.
    final loadingSeen = <bool>[];
    controller.lyricsLoading.listen(loadingSeen.add);
    await controller.loadCurrentLyrics();
    expect(controller.activeLyrics.value, isNotNull);
    expect(controller.lyricsLoading.value, isFalse);
  });

  test('lyrics are cleared when playback stops', () async {
    final stub = _StubLyrics();
    stub.tracks['歌曲'] = _track('歌曲');
    final controller = _LyricsController(stub);
    final song = _song('a', '歌曲');
    controller.current.value = song;
    await controller.loadCurrentLyrics();
    expect(controller.activeLyrics.value, isNotNull);
    controller.current.value = null;
    await controller.loadCurrentLyrics();
    expect(controller.activeLyrics.value, isNull);
    expect(controller.lyricsLoading.value, isFalse);
  });
}
