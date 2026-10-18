import 'dart:io';

import 'package:PiliPlus/pages/listening/controller.dart';
import 'package:PiliPlus/pages/listening/lyrics.dart';
import 'package:PiliPlus/pages/listening/lyrics_view.dart';
import 'package:PiliPlus/pages/listening/models.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';

class FakeSearch extends LyricsSearch {
  final queries = <String>[];
  @override
  Future<List<LyricCandidate>> search(String name) async {
    queries.add(name);
    return [
      LyricCandidate({
        'trackName': name,
        'artistName': 'Test artist',
        'syncedLyrics': '[00:01]synthetic line\n[00:10]another synthetic line\n[00:20]third synthetic line\n[00:30]fourth synthetic line\n[00:40]fifth synthetic line\n[00:50]sixth synthetic line',
        'duration': 5,
      }),
    ];
  }
}

class FakeLyrics extends ListeningLyrics {
  @override
  final FakeSearch search = FakeSearch();
  @override
  Future<void> save(ListeningSong song, LyricTrack track) async {}
  @override
  LyricTrack? saved(ListeningSong song, {bool translation = false}) =>
      translation
      ? const LyricTrack(
          label: '已保存译文',
          source: 'test',
          lines: [LyricLine(Duration.zero, '测试译文')],
          priority: 1,
        )
      : null;
}

void main() {
  late Directory directory;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('lyrics-ui-');
    Hive.init(directory.path);
    GStorage.localCache = await Hive.openBox('localCache');
  });
  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });
  for (final size in [const Size(360, 640), const Size(1000, 500)]) {
    testWidgets(
      'lyrics prefers song search over saved translation without fetching subtitles at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final song = ListeningSong(
          id: 'test',
          name: 'test song',
          chineseName: '中文译名',
          translatedNameSource: 'test song',
          original: const SongSource(
            bvid: 'BV1',
            aid: 1,
            cid: 1,
            page: 1,
            title: 'test',
          ),
        );
        final service = FakeLyrics();
        await service.save(
          song,
          const LyricTrack(
            label: '已保存译文',
            source: 'test',
            lines: [LyricLine(Duration.zero, '测试译文')],
            priority: 1,
          ),
        );
        final controller = ListeningController();
        controller.current.value = song;
        await tester.pumpWidget(
          GetMaterialApp(
            home: ListeningLyricsView(
              song: song,
              controller: controller,
              service: service,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(service.search.queries, ['test song']);
        expect(tester.takeException(), isNull);
        expect(find.text('synthetic line'), findsOneWidget);
        final dropdown = tester.widget<DropdownButton<LyricTrack>>(
          find.byType(DropdownButton<LyricTrack>),
        );
        expect(dropdown.value?.priority, 0);
        expect(
          dropdown.items?.map((e) => e.value!.priority),
          containsAll([0, 1]),
        );
        controller.position.value = const Duration(seconds: 2);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<ListTile>(find.widgetWithText(ListTile, 'synthetic line'))
              .selected,
          isTrue,
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
