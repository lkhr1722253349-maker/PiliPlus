import 'dart:io';

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/pages/listening/controller.dart';
import 'package:PiliPlus/pages/listening/models.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

const oldSource = SongSource(
  bvid: 'old',
  aid: 1,
  cid: 11,
  page: 1,
  title: '原作',
);
const newSource = SongSource(
  bvid: 'new',
  aid: 2,
  cid: 22,
  page: 1,
  title: '新音源',
);

class RecordingController extends ListeningController {
  final events = <String>[];
  bool rejectAdd = false;
  bool failRemove = false;
  @override
  Future<void> save() async {
    events.add('save');
  }

  @override
  Future<LoadingState<void>> updateFavorite({
    required String resources,
    String? addIds,
    String? delIds,
  }) async {
    events.add(
      '${addIds != null ? "add" : "remove"}:$resources:${addIds ?? delIds}',
    );
    if (addIds != null && rejectAdd) return const Error('拒绝添加');
    if (delIds != null && failRemove) throw StateError('网络断开');
    return const Success(null);
  }
}

void main() {
  late Directory directory;
  late RecordingController controller;
  late ListeningSong song;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp(
      'piliplus-favorite-sync-',
    );
    Hive.init(directory.path);
    GStorage.setting = await Hive.openBox('setting');
    GStorage.localCache = await Hive.openBox('localCache');
    Accounts.accountMode[AccountType.main.index] = LoginAccount(
      BiliCookieJar.fromJson({'DedeUserID': '123', 'bili_jct': 'csrf'}),
      'key',
      'refresh',
    );
  });
  setUp(() {
    controller = RecordingController();
    song = ListeningSong(
      id: 'song',
      name: '歌曲名',
      original: oldSource,
      folderIds: {100},
      ownerMid: 123,
    );
    controller.playlists.add(
      ListeningPlaylist(id: 'list', name: '歌单', songs: [song]),
    );
  });
  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('favorite replacement adds first, persists retry state, then removes old favorite', () async {
    await controller.replaceSource(song, newSource);
    expect(controller.events, [
      'add:2:2:100',
      'save',
      'remove:1:2:100',
      'save',
    ]);
    expect(song.original.key, oldSource.key);
    expect(song.name, '歌曲名');
    expect(song.pendingFavoriteSync, isFalse);
  });
  test('failed add leaves original source and favorite intact', () async {
    controller.rejectAdd = true;
    await expectLater(
      controller.replaceSource(song, newSource),
      throwsStateError,
    );
    expect(song.source.key, oldSource.key);
    expect(controller.events, ['add:2:2:100']);
  });
  test(
    'network failure removing old favorite keeps durable retry state',
    () async {
      controller.failRemove = true;
      await expectLater(
        controller.replaceSource(song, newSource),
        throwsStateError,
      );
      expect(song.source.key, newSource.key);
      expect(song.pendingFavoriteSync, isTrue);
      expect(controller.events, ['add:2:2:100', 'save', 'remove:1:2:100']);
      controller.failRemove = false;
      await controller.retryFavoriteSync(song);
      expect(song.pendingFavoriteSync, isFalse);
      expect(controller.events.last, 'save');
    },
  );
  test(
    'another selected part keeps original video in the shared favorite folder',
    () async {
      controller.playlists.first.songs.add(
        ListeningSong(
          id: 'part2',
          name: '另一首',
          original: const SongSource(
            bvid: 'old',
            aid: 1,
            cid: 12,
            page: 2,
            title: '原作',
          ),
          folderIds: {100},
          ownerMid: 123,
        ),
      );
      await controller.replaceSource(song, newSource);
      expect(controller.events.where((e) => e.startsWith('remove')), isEmpty);
      expect(song.pendingFavoriteSync, isFalse);
    },
  );
  test(
    'changing account cannot modify imported favorites in the wrong account',
    () async {
      song = ListeningSong(
        id: 'song',
        name: '歌名',
        original: oldSource,
        folderIds: {100},
        ownerMid: 456,
      );
      await expectLater(
        controller.replaceSource(song, newSource),
        throwsStateError,
      );
      expect(controller.events, isEmpty);
    },
  );
}
