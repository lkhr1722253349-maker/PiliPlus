import 'dart:io';

import 'package:PiliPlus/pages/listening/controller.dart';
import 'package:PiliPlus/pages/listening/models.dart';
import 'package:PiliPlus/pages/listening/view.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';

class _UiController extends ListeningController {
  @override
  Future<void> save() async {
    playlists.refresh();
  }
}

void main() {
  late Directory directory;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('piliplus-listening-ui-');
    Hive.init(directory.path);
    GStorage.localCache = await Hive.openBox('localCache');
    GStorage.video = await Hive.openBox('video');
    GStorage.setting = await Hive.openBox('setting');
    Get.testMode = true;
  });
  tearDown(() {
    Get.delete<ListeningController>(force: true);
  });
  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  for (final size in [const Size(360, 640), const Size(1000, 500)]) {
    testWidgets('listening page fits $size and creates a playlist', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Get.put<ListeningController>(_UiController(), permanent: true);
      await tester.pumpWidget(const GetMaterialApp(home: ListeningPage()));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('听视频歌单'), findsNothing);
      expect(find.text('我的歌单'), findsOneWidget);
      expect(find.byTooltip('播放倍速'), findsNothing);
      await tester.tap(find.text('收起列表'));
      await tester.pump(const Duration(milliseconds: 140));
      expect(find.byType(AnimatedCrossFade), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('展开列表'), findsOneWidget);
      expect(find.byIcon(Icons.album_outlined), findsNothing);
      expect(
        tester.getSize(find.byTooltip('播放')).height,
        greaterThanOrEqualTo(60),
      );
      await tester.tap(find.text('展开列表'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('列表循环'));
      await tester.pump();
      expect(find.byTooltip('随机播放'), findsOneWidget);
      await tester.tap(find.byTooltip('随机播放'));
      await tester.pump();
      expect(find.byTooltip('单曲循环'), findsOneWidget);
      await tester.tap(find.byTooltip('添加视频'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('从我的收藏夹导入'), findsOneWidget);
      await tester.tap(find.text('从 BV 号 / 链接导入'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(TextField), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('我的歌单'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('新建歌单'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(Get.find<ListeningController>().playlists.length, 1);
      await tester.tap(find.text('我的歌单'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('新建歌单'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(find.byType(TextField), '夜间歌单');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(Get.find<ListeningController>().selected.name, '夜间歌单');
      await tester.tap(find.text('夜间歌单'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('歌单操作：夜间歌单'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重命名'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(find.byType(TextField), '睡前');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(Get.find<ListeningController>().selected.name, '睡前');
      await tester.tap(find.text('睡前'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('歌单操作：睡前'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(Get.find<ListeningController>().selected.name, '我的歌单');
      final player = Get.find<ListeningController>();
      final playingList = player.selected;
      playingList.songs.addAll(
        List.generate(
          100,
          (i) => ListeningSong(
            id: 'song-$i',
            name: '曲目 $i',
            original: SongSource(
              bvid: 'bv$i',
              aid: i + 1,
              cid: i + 1,
              page: 1,
              title: '视频 $i',
            ),
          ),
        ),
      );
      player.current.value = playingList.songs[90];
      await player.createPlaylist('其他歌单');
      await tester.pumpAndSettle();
      player.focusCurrentSong();
      await tester.pumpAndSettle();
      expect(player.selected.id, playingList.id);
      expect(find.widgetWithText(ListTile, '曲目 90'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
  }
}
