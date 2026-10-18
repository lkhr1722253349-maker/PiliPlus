import 'package:PiliPlus/pages/listening/compact_lyrics.dart';
import 'package:PiliPlus/pages/listening/controller.dart';
import 'package:PiliPlus/pages/listening/lyrics.dart';
import 'package:PiliPlus/pages/listening/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  for (final size in [const Size(360, 640), const Size(1000, 800)]) {
    testWidgets('three lyrics lines highlight the current line at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = ListeningController();
      controller.activeLyrics.value = const LyricTrack(
        label: 'test',
        source: 'test',
        lines: [
          LyricLine(Duration.zero, 'previous'),
          LyricLine(Duration(seconds: 1), 'current'),
          LyricLine(Duration(seconds: 2), 'next'),
          LyricLine(Duration(seconds: 3), 'later'),
        ],
      );
      controller.position.value = const Duration(milliseconds: 1500);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: CompactListeningLyrics(controller: controller)),
        ),
      );
      expect(find.text('previous'), findsOneWidget);
      expect(find.text('current'), findsOneWidget);
      expect(find.text('next'), findsOneWidget);
      expect(find.text('later'), findsNothing);
      expect(find.byType(ImageFiltered), findsNWidgets(2));
      final center = tester.getCenter(find.text('current')).dx;
      expect(
        center,
        size.width < 600
            ? closeTo(size.width / 2, 1)
            : greaterThan(size.width / 2),
      );
      controller.position.value = const Duration(milliseconds: 2500);
      await tester.pump();
      expect(find.text('later'), findsOneWidget);
      expect(find.text('previous'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  test('translated title is separate from the search title and invalidated on rename', () {
    final song = ListeningSong(
      id: 'test',
      name: 'Test song',
      chineseName: '测试歌曲',
      translatedNameSource: 'Test song',
      original: const SongSource(
        bvid: 'BV1',
        aid: 1,
        cid: 1,
        page: 1,
        title: 'video',
      ),
    );
    expect(song.displayName, 'Test song（测试歌曲）');
    expect(ListeningSong.fromJson(song.toJson()).displayName, song.displayName);
    expect(song.name, 'Test song');
    song.name = 'Another song';
    expect(song.displayName, 'Another song');
    expect(ListeningLyrics.nameLanguage('中文歌名'), isNull);
    expect(ListeningLyrics.nameLanguage('春日影（かな）'), 'ja');
  });
}
