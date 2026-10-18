import 'dart:io' show File, Platform;
import 'dart:ui' show PlatformDispatcher;

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/grpc/bilibili/app/listener/v1.pb.dart' show DetailItem;
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/live/live_room_info_h5/data.dart';
import 'package:PiliPlus/models_new/pgc/pgc_info_model/episode.dart';
import 'package:PiliPlus/models_new/video/video_detail/data.dart';
import 'package:PiliPlus/models_new/video/video_detail/page.dart';
import 'package:PiliPlus/pages/common/common_intro_controller.dart';
import 'package:PiliPlus/pages/video/introduction/local/controller.dart';
import 'package:PiliPlus/pages/video/introduction/pgc/controller.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/controller.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/utils/android/bindings.g.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:audio_service/audio_service.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:get/get_core/src/get_main.dart';
import 'package:get/get_instance/src/extension_instance.dart';
import 'package:path/path.dart' as path;

Future<VideoPlayerServiceHandler> initAudioService() {
  return AudioService.init(
    builder: VideoPlayerServiceHandler.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.example.piliplus.audio',
      androidNotificationChannelName: 'Audio Service ${Constants.appName}',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
      fastForwardInterval: Duration(seconds: 10),
      rewindInterval: Duration(seconds: 10),
      androidNotificationChannelDescription: 'Media notification channel',
      androidNotificationIcon: 'drawable/ic_notification_icon',
    ),
  );
}

typedef _StatusConfig = (
  PlayerStatus status,
  bool isBuffering,
  bool isLive,
  double speed,
);

class VideoPlayerServiceHandler extends BaseAudioHandler with SeekHandler {
  static final List<MediaItem> _item = [];
  bool enableBackgroundPlay = Pref.enableBackgroundPlay;

  Future<void>? Function()? onPlay;
  Future<void>? Function()? onPause;
  Future<void>? Function(Duration position)? onSeek;
  void Function()? onSkipToNext;
  void Function()? onSkipToPrevious;
  void Function()? onListeningMode;
  String listeningMode = 'list';
  bool _listening = false;
  Future<void> Function()? _listeningPlay,
      _listeningPause,
      _listeningNext,
      _listeningPrevious;
  Future<void> Function(Duration)? _listeningSeek;

  void bindListeningSession({
    required Future<void> Function() play,
    required Future<void> Function() pause,
    required Future<void> Function() next,
    required Future<void> Function() previous,
    required Future<void> Function(Duration) seek,
    required void Function() mode,
  }) {
    _listeningPlay = play;
    _listeningPause = pause;
    _listeningNext = next;
    _listeningPrevious = previous;
    _listeningSeek = seek;
    onListeningMode = mode;
  }

  void updateListeningMode(String mode) {
    listeningMode = mode;
    _lastConfig = null;
  }

  @override
  Future<dynamic> customAction(
    String name, [
    Map<String, dynamic>? extras,
  ]) async {
    if (_listening && name == 'listeningMode') onListeningMode?.call();
  }

  @override
  Future<void> play() {
    if (_listening) return _listeningPlay?.call() ?? Future.value();
    return onPlay?.call() ??
        PlPlayerController.playIfExists() ??
        Future.syncValue(null);
  }

  @override
  Future<void> pause() {
    if (_listening) return _listeningPause?.call() ?? Future.value();
    return onPause?.call() ??
        PlPlayerController.pauseIfExists() ??
        Future.syncValue(null);
  }

  CommonIntroController? _findIntroController() {
    final playOwner = PlPlayerController.playOwner;
    if (playOwner != null) {
      final tag = playOwner.tag;
      try {
        return switch (playOwner.type) {
          UgcIntroController => Get.find<UgcIntroController>(tag: tag),
          PgcIntroController => Get.find<PgcIntroController>(tag: tag),
          LocalIntroController => Get.find<LocalIntroController>(tag: tag),
          _ => throw UnimplementedError(playOwner.type.toString()),
        };
      } catch (_) {
        if (kDebugMode) rethrow;
      }
    }
    return null;
  }

  @override
  Future<void> skipToNext() {
    if (_listening) return _listeningNext?.call() ?? Future.value();
    final func = onSkipToNext ?? _findIntroController()?.nextPlay;
    return func == null ? Future.syncValue(null) : Future.sync(func);
  }

  @override
  Future<void> skipToPrevious() {
    if (_listening) return _listeningPrevious?.call() ?? Future.value();
    final func = onSkipToPrevious ?? _findIntroController()?.prevPlay;
    return func == null ? Future.syncValue(null) : Future.sync(func);
  }

  @override
  Future<void> fastForward() => _listening ? skipToNext() : super.fastForward();

  @override
  Future<void> rewind() => _listening ? skipToPrevious() : super.rewind();

  @override
  Future<void> seek(Duration position) {
    if (_listening) return _listeningSeek?.call(position) ?? Future.value();
    return onSeek?.call(position) ??
        PlPlayerController.seekToIfExists(position, isSeek: false) ??
        Future.syncValue(null);
  }

  void setMediaItem(MediaItem newMediaItem) {
    if (_listening && !newMediaItem.id.startsWith('listening:')) return;
    if (!enableBackgroundPlay) return;
    // if (kDebugMode) {
    //   debugPrint("此时调用栈为：");
    //   debugPrint(newMediaItem);
    //   debugPrint(newMediaItem.title);
    //   debugPrint(StackTrace.current.toString());
    // }
    if (!mediaItem.isClosed) mediaItem.add(newMediaItem);
  }

  void setListeningMediaItem(MediaItem item) {
    _listening = true;
    _lastConfig = null;
    _item.removeWhere((e) => e.id.startsWith('listening:'));
    _item.add(item);
    setMediaItem(item);
  }

  void clearListeningMediaItem() {
    _listening = false;
    _listeningPlay = _listeningPause = _listeningNext = _listeningPrevious =
        null;
    _listeningSeek = null;
    onListeningMode = null;
    _lastConfig = null;
    _item.removeWhere((e) => e.id.startsWith('listening:'));
    if (_item.isNotEmpty) setMediaItem(_item.last);
  }

  Duration? _lastPos;
  _StatusConfig? _lastConfig;
  void onUpdateState(
    PlayerStatus status,
    bool isBuffering,
    bool isLive, {
    required Duration position,
    required double speed,
    String? debugLabel,
    bool listening = false,
  }) {
    if (_listening && !listening) return;
    if (!enableBackgroundPlay || _item.isEmpty) {
      return;
    }

    if (onPlay != null && debugLabel == 'onVideoPaused') return;

    final newConfig = (status, isBuffering, isLive, speed);
    if (_lastConfig == newConfig) {
      if (_lastPos != null) {
        final pos = position.inSeconds;
        final lastPos = _lastPos!.inSeconds;
        _lastPos = position;
        if (pos == lastPos && pos != 0) return;
      }
    }
    _lastConfig = newConfig;

    final AudioProcessingState processingState;
    final bool playing;
    switch (status) {
      case .completed:
        playing = false;
        processingState = .completed;
      case .playing:
        playing = true;
        processingState = isBuffering ? .buffering : .ready;
      case .paused:
        playing = isBuffering;
        processingState = isBuffering ? .buffering : .ready;
    }
    _updateState(
      processingState,
      playing,
      isLive,
      position: position,
      speed: speed,
    );
  }

  void _updateState(
    AudioProcessingState state,
    bool playing,
    bool isLive, {
    required Duration position,
    required double speed,
  }) {
    playbackState.add(
      playbackState.value.copyWith(
        processingState: state,
        updatePosition: position,
        speed: speed,
        controls: [
          if (_listening)
            const MediaControl(
              androidIcon: 'drawable/ic_listening_previous',
              label: '上一首',
              action: .skipToPrevious,
            )
          else if (!isLive)
            const MediaControl(
              androidIcon: 'drawable/ic_player_rewind_10s',
              label: 'Rewind',
              action: .rewind,
            ),
          if (playing)
            const MediaControl(
              androidIcon: 'drawable/ic_player_pause',
              label: 'Pause',
              action: .pause,
            )
          else
            const MediaControl(
              androidIcon: 'drawable/ic_player_play',
              label: 'Play',
              action: .play,
            ),
          if (_listening) ...[
            const MediaControl(
              androidIcon: 'drawable/ic_listening_next',
              label: '下一首',
              action: .skipToNext,
            ),
            MediaControl.custom(
              androidIcon: 'drawable/ic_listening_$listeningMode',
              label: switch (listeningMode) {
                'shuffle' => '随机播放',
                'single' => '单曲循环',
                _ => '列表循环',
              },
              name: 'listeningMode',
            ),
          ] else if (!isLive)
            const MediaControl(
              androidIcon: 'drawable/ic_player_fast_forward_10s',
              label: 'Fast Forward',
              action: .fastForward,
            ),
        ],
        playing: playing,
        androidCompactActionIndices: _listening ? const [0, 1, 2] : null,
        repeatMode: !_listening
            ? AudioServiceRepeatMode.none
            : listeningMode == 'single'
            ? AudioServiceRepeatMode.one
            : AudioServiceRepeatMode.all,
        shuffleMode: _listening && listeningMode == 'shuffle'
            ? AudioServiceShuffleMode.all
            : AudioServiceShuffleMode.none,
        systemActions: const {.seek},
      ),
    );
    if (Platform.isAndroid &&
        (AndroidHelper.isPipMode ||
            PlPlayerController.instance?.isAutoEnterPip == true)) {
      AndroidHelper.updatePipActions(
        PlatformDispatcher.instance.engineId!,
        isLive,
        playing,
      );
    }
  }

  void onVideoDetailChange(
    dynamic data,
    int cid,
    String herotag, {
    String? artist,
    String? cover,
  }) {
    if (!enableBackgroundPlay) return;
    // if (kDebugMode) {
    //   debugPrint('当前调用栈为：');
    //   debugPrint(StackTrace.current);
    // }
    if (data == null) return;

    Uri getUri(String? cover) => Uri.parse(ImageUtils.safeThumbnailUrl(cover));

    late final id = '$cid$herotag';
    final MediaItem mediaItem;
    switch (data) {
      case VideoDetailData(:final pages):
        if (pages != null && pages.length > 1) {
          final current = pages.firstWhereOrNull((e) => e.cid == cid);
          mediaItem = MediaItem(
            id: id,
            title: current?.part ?? '',
            artist: data.owner?.name,
            duration: Duration(seconds: current?.duration ?? 0),
            artUri: getUri(data.pic),
          );
        } else {
          mediaItem = MediaItem(
            id: id,
            title: data.title ?? '',
            artist: data.owner?.name,
            duration: Duration(seconds: data.duration ?? 0),
            artUri: getUri(data.pic),
          );
        }
      case EpisodeItem():
        mediaItem = MediaItem(
          id: id,
          title: data.showTitle ?? data.longTitle ?? data.title ?? '',
          artist: artist,
          duration: data.from == 'pugv'
              ? Duration(seconds: data.duration ?? 0)
              : Duration(milliseconds: data.duration ?? 0),
          artUri: getUri(data.cover),
        );
      case RoomInfoH5Data():
        mediaItem = MediaItem(
          id: id,
          title: data.roomInfo?.title ?? '',
          artist: data.anchorInfo?.baseInfo?.uname,
          artUri: getUri(data.roomInfo?.cover),
          isLive: true,
        );
      case Part():
        mediaItem = MediaItem(
          id: id,
          title: data.part ?? '',
          artist: artist,
          duration: Duration(seconds: data.duration ?? 0),
          artUri: getUri(cover),
        );
      case DetailItem(:final arc):
        mediaItem = MediaItem(
          id: id,
          title: arc.title,
          artist: data.owner.name,
          duration: Duration(seconds: arc.duration.toInt()),
          artUri: getUri(arc.cover),
        );
      case BiliDownloadEntryInfo():
        final coverFile = File(
          path.join(data.entryDirPath, PathUtils.coverName),
        );
        final uri = coverFile.existsSync()
            ? coverFile.absolute.uri
            : getUri(data.cover);
        mediaItem = MediaItem(
          id: id,
          title: data.showTitle,
          artist: data.ownerName,
          duration: Duration(milliseconds: data.totalTimeMilli),
          artUri: uri,
        );
      default:
        return;
    }
    _item.add(mediaItem);
    setMediaItem(mediaItem);
  }

  void onVideoDetailDispose(String herotag) {
    if (!enableBackgroundPlay) return;

    if (_item.isNotEmpty) {
      _item.removeWhere((item) => item.id.endsWith(herotag));
    }
    if (_listening) return;
    if (_item.isNotEmpty) {
      setMediaItem(_item.last);
      playbackState.add(
        playbackState.value.copyWith(processingState: .ready, playing: false),
      );
    }
  }

  void clearIfNeeded() {
    if (!enableBackgroundPlay) return;
    if (_item.isEmpty) clear();
  }

  void clear() {
    if (_listening) return;
    if (!enableBackgroundPlay) return;
    mediaItem.add(null);
    _item.clear();
    _lastPos = null;
    _lastConfig = null;
    /**
     * if (playbackState.processingState == AudioProcessingState.idle &&
            previousState?.processingState != AudioProcessingState.idle) {
          await AudioService._stop();
        }
     */
    if (playbackState.value.processingState == .idle) {
      playbackState.add(PlaybackState(processingState: .completed));
    }
    playbackState.add(PlaybackState(processingState: .idle));
  }
}
