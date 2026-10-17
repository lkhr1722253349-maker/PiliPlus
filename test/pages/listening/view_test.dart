import 'dart:io';

import 'package:PiliPlus/pages/listening/controller.dart';
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
      expect(find.text('听视频歌单'), findsOneWidget);
      expect(find.byTooltip('导入收藏'), findsOneWidget);
      await tester.tap(find.byTooltip('添加视频'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('我的收藏夹'), findsOneWidget);
      expect(find.text('收藏夹链接（自己或他人）'), findsOneWidget);
      await tester.tap(find.text('收藏夹链接（自己或他人）'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('导入收藏夹链接'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('新建歌单'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(find.byType(TextField), '夜间歌单');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(Get.find<ListeningController>().selected.name, '夜间歌单');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
  }
}
