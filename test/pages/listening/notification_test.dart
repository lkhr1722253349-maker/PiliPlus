import 'dart:io';

import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/services/audio_handler.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'listening notification exposes previous, next and mode actions',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'listening-notification-',
      );
      Hive.init(directory.path);
      GStorage.setting = await Hive.openBox('setting');
      final handler = VideoPlayerServiceHandler()..enableBackgroundPlay = true;
      handler.setListeningMediaItem(
        const MediaItem(id: 'listening:test', title: 'song'),
      );
      var changes = 0;
      handler.onListeningMode = () => changes++;
      handler.updateListeningMode('shuffle');
      handler.onUpdateState(
        PlayerStatus.playing,
        false,
        false,
        position: Duration.zero,
        speed: 1,
      );
      final state = handler.playbackState.value;
      expect(state.controls.map((e) => e.label), [
        '上一首',
        'Pause',
        '下一首',
        '随机播放',
      ]);
      expect(state.shuffleMode, AudioServiceShuffleMode.all);
      expect(state.androidCompactActionIndices, [0, 1, 2]);
      await handler.customAction('listeningMode');
      expect(changes, 1);
      handler.clearListeningMediaItem();
      await handler.customAction('listeningMode');
      expect(changes, 1);
      await Hive.close();
      await directory.delete(recursive: true);
    },
  );
}
