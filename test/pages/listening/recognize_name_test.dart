import 'dart:io';

import 'package:PiliPlus/models/search/result.dart';
import 'package:PiliPlus/pages/listening/controller.dart';
import 'package:PiliPlus/pages/listening/models.dart';
import 'package:PiliPlus/pages/listening/song_name.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

class _RecognizeController extends ListeningController {
  final List<String> queries = [];
  int searches = 0;

  @override
  Future<void> save() async {}

  @override
  Future<List<SearchVideoItemModel>> search(String keyword, int page) async {
    searches++;
    queries.add(keyword);
    // Five videos that all carry the same song name, as a real search would.
    return [
      _video('BV1', '甲《春日影》翻唱'),
      _video('BV2', '乙「春日影」现场'),
      _video('BV3', '丙 - 春日影 - 完整版'),
      _video('BV4', '丁【春日影】高清'),
      _video('BV5', '其他歌曲'),
    ];
  }
}

SearchVideoItemModel _video(String bvid, String title) =>
    SearchVideoItemModel.fromJson({
      'bvid': bvid,
      'aid': 1,
      'title': title,
      'author': 'up',
      'mid': 1,
    });

ListeningSong _song(
  String id,
  String name, {
  bool nameEdited = false,
  String? namedSource,
}) => ListeningSong(
  id: id,
  name: name,
  nameEdited: nameEdited,
  namedSource: namedSource,
  original: SongSource(
    bvid: 'BV$id',
    aid: 1,
    cid: 1,
    page: 1,
    title: '原视频标题$id',
  ),
);

void main() {
  late Directory directory;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('piliplus-recognize-');
    Hive.init(directory.path);
    GStorage.localCache = await Hive.openBox('localCache');
  });
  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('a raw video title is replaced by the consensus name', () async {
    final controller = _RecognizeController();
    final song = _song('a', 'BV 视频标题');
    controller.playlists.value = [
      ListeningPlaylist(id: 'list', name: 'list', songs: [song]),
    ];
    final applied = await controller.recognizeSongName(song);
    expect(applied, isTrue);
    expect(song.name, '春日影');
    expect(song.namedSource, song.source.key);
    // Recognition only touches the display name.
    expect(song.original.title, '原视频标题a');
    expect(song.source.bvid, 'BVa');
    expect(song.nameEdited, isFalse);
  });

  test('a manual name is never replaced by recognition', () async {
    final controller = _RecognizeController();
    final song = _song('b', '用户手改的名字', nameEdited: true);
    controller.playlists.value = [
      ListeningPlaylist(id: 'list', name: 'list', songs: [song]),
    ];
    final applied = await controller.recognizeSongName(song);
    expect(applied, isFalse);
    expect(song.name, '用户手改的名字');
    expect(controller.searches, 0);
  });

  test('automatic recognition names songs once per source', () async {
    final controller = _RecognizeController();
    final raw = _song('c', 'c 的标题');
    final manual = _song('d', '手改', nameEdited: true);
    controller.playlists.value = [
      ListeningPlaylist(id: 'list', name: 'list', songs: [raw, manual]),
    ];
    await controller.recognizeSongNames(limit: 5);
    expect(raw.name, '春日影');
    expect(manual.name, '手改');
    expect(controller.searches, 1);
    // The marker keeps the recognised song from being searched again.
    final done = controller.searches;
    await controller.recognizeSongNames(limit: 5);
    expect(controller.searches, done);
    expect(GStorage.localCache.get('listeningNameSearch:${raw.source.key}'), '春日影');
  });

  test('a song already named by its BGM tag is left alone', () async {
    final controller = _RecognizeController();
    final song = _song('e', '官方歌名', namedSource: 'BGe:1');
    controller.playlists.value = [
      ListeningPlaylist(id: 'list', name: 'list', songs: [song]),
    ];
    await controller.recognizeSongNames(limit: 5);
    expect(song.name, '官方歌名');
    expect(controller.searches, 0);
  });

  test('consensus thresholds still reject a single stray title', () {
    expect(
      inferSongName(['春日影', '春日影', '春日影']),
      isNull,
      reason: 'fewer than four videos cannot confirm a name',
    );
  });
}
