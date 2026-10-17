import 'dart:convert';

import 'package:PiliPlus/pages/listening/models.dart';
import 'package:flutter_test/flutter_test.dart';

const original = SongSource(
  bvid: 'BV-original',
  aid: 1,
  cid: 11,
  page: 2,
  title: '原视频标题',
  cover: 'https://example.com/cover.jpg',
);
const replacement = SongSource(
  bvid: 'BV-replacement',
  aid: 2,
  cid: 22,
  page: 1,
  title: '替代版本',
);

void main() {
  test(
    'source replacement survives restart without losing song name or original',
    () {
      final song = ListeningSong(
        id: 'song',
        name: '歌曲名',
        original: original,
        folderIds: {100, 200},
        ownerMid: 123,
        error: '原视频已失效',
      );
      song.replace(replacement);
      song.pendingFavoriteSync = true;
      final restored = ListeningSong.fromJson(
        jsonDecode(jsonEncode(song.toJson())) as Map,
      );
      expect(restored.name, '歌曲名');
      expect(restored.original.key, original.key);
      expect(restored.original.title, original.title);
      expect(restored.source.key, replacement.key);
      expect(restored.previousSources.single.key, original.key);
      expect(restored.folderIds, {100, 200});
      expect(restored.ownerMid, 123);
      expect(restored.pendingFavoriteSync, isTrue);
      expect(restored.error, isNull);
    },
  );

  test('multiple selected parts are separate songs; duplicate imports merge folders', () {
    final list = ListeningPlaylist(id: 'list', name: '歌单');
    list.add(
      ListeningSong(id: '1', name: 'P2', original: original, folderIds: {100}),
    );
    list.add(
      ListeningSong(
        id: '2',
        name: 'P3',
        original: const SongSource(
          bvid: 'BV-original',
          aid: 1,
          cid: 12,
          page: 3,
          title: '原视频标题',
        ),
      ),
    );
    expect(
      list.add(
        ListeningSong(
          id: '3',
          name: '重复',
          original: original,
          folderIds: {200},
        ),
      ),
      isFalse,
    );
    expect(list.songs.length, 2);
    expect(list.songs.first.folderIds, {100, 200});
    final restored = ListeningPlaylist.fromJson(
      jsonDecode(jsonEncode(list.toJson())) as Map,
    );
    expect(restored.songs.map((e) => e.source.cid), [11, 12]);
  });

  test(
    'invalid video placeholder retains identity and supports later replacement',
    () {
      final song = ListeningSong(
        id: 'lost',
        name: '可编辑的歌曲名',
        original: const SongSource(
          bvid: 'BV-lost',
          aid: 3,
          cid: 0,
          page: 1,
          title: '已失效视频',
        ),
        error: '失效',
      );
      song.replace(replacement);
      expect(song.original.cid, 0);
      expect(song.original.bvid, 'BV-lost');
      expect(song.source.cid, 22);
      expect(song.name, '可编辑的歌曲名');
    },
  );
}
