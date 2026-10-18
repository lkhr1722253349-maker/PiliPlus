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
      final calls = <String>[];
      handler.bindListeningSession(
        play: () async => calls.add('play'),
        pause: () async => calls.add('pause'),
        next: () async => calls.add('next'),
        previous: () async => calls.add('previous'),
        seek: (_) async => calls.add('seek'),
        mode: () => changes++,
      );
      handler.onPlay = () async => calls.add('wrong player');
      handler.onSkipToNext = () => calls.add('wrong next');
      handler.updateListeningMode('shuffle');
      handler.onUpdateState(
        PlayerStatus.playing,
        false,
        false,
        position: Duration.zero,
        speed: 1,
        listening: true,
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
      await handler.play();
      await handler.pause();
      await handler.skipToNext();
      await handler.skipToPrevious();
      await handler.seek(const Duration(seconds: 3));
      await handler.fastForward();
      await handler.rewind();
      expect(calls, [
        'play',
        'pause',
        'next',
        'previous',
        'seek',
        'next',
        'previous',
      ]);
      handler.onUpdateState(
        PlayerStatus.paused,
        false,
        false,
        position: Duration.zero,
        speed: 1,
      );
      handler.clear();
      expect(handler.playbackState.value.playing, isTrue);
      expect(handler.mediaItem.value?.id, 'listening:test');
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
