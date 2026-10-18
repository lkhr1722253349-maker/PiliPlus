import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/fav.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/search.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/search/search_type.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models/search/result.dart';
import 'package:PiliPlus/models_new/fav/fav_folder/list.dart';
import 'package:PiliPlus/models_new/video/video_detail/data.dart';
import 'package:PiliPlus/pages/listening/models.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/services/shutdown_timer_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';

enum ListeningMode { list, shuffle, single }

class ListeningController extends GetxController {
  static const storageKey = 'listeningPlaylistsV1';
  final playlists = <ListeningPlaylist>[].obs;
  final selectedId = ''.obs;
  final focusRequest = 0.obs;
  final current = Rxn<ListeningSong>();
  final position = Duration.zero.obs;
  final duration = Duration.zero.obs;
  final playing = false.obs;
  final loading = false.obs;
  final mode = ListeningMode.list.obs;
  final speed = 1.0.obs;
  Player? _player;
  Future<Player>? _creatingPlayer;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  int _request = 0;
  String? _playingPlaylistId;
  final _random = Random();
  bool _ownsMediaSession = false;
  void Function(ListeningSong song)? onUnavailable;
  String? _notifiedFailure;
  int _streamRetries = 0;
  String? _openError;

  ListeningPlaylist get selected =>
      playlists.firstWhere((e) => e.id == selectedId.value);
  String newId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(1 << 32)}';

  @override
  void onInit() {
    super.onInit();
    final saved = GStorage.localCache.get(storageKey) as List?;
    if (saved != null) {
      playlists.addAll(saved.map((e) => ListeningPlaylist.fromJson(e)));
    }
    if (playlists.isEmpty) {
      playlists.add(ListeningPlaylist(id: newId(), name: '我的歌单'));
    }
    selectedId.value = playlists.first.id;
  }

  Future<void> save() async {
    await GStorage.localCache.put(
      storageKey,
      playlists.map((e) => e.toJson()).toList(),
    );
    playlists.refresh();
    current.refresh();
  }

  Future<void> createPlaylist(String name) async {
    if (name.trim().isEmpty) return;
    final list = ListeningPlaylist(id: newId(), name: name.trim());
    playlists.add(list);
    selectedId.value = list.id;
    await save();
  }

  Future<void> renamePlaylist(ListeningPlaylist list, String name) async {
    if (name.trim().isEmpty) return;
    list.name = name.trim();
    await save();
  }

  Future<void> deletePlaylist(ListeningPlaylist list) async {
    if (_playingPlaylistId == list.id || list.songs.contains(current.value)) {
      ++_request;
      await _yieldPlayback();
      await _player?.stop();
      current.value = null;
      loading.value = false;
      _playingPlaylistId = null;
    }
    playlists.remove(list);
    if (playlists.isEmpty) {
      playlists.add(ListeningPlaylist(id: newId(), name: '我的歌单'));
    }
    if (selectedId.value == list.id) selectedId.value = playlists.first.id;
    await save();
  }

  void cycleMode() {
    mode.value = ListeningMode
        .values[(mode.value.index + 1) % ListeningMode.values.length];
    videoPlayerServiceHandler?.updateListeningMode(mode.value.name);
    _publish();
  }

  Future<void> removeSong(ListeningPlaylist list, ListeningSong song) async {
    if (identical(current.value, song)) {
      ++_request;
      await _yieldPlayback();
      await _player?.stop();
      current.value = null;
      loading.value = false;
    }
    list.songs.remove(song);
    await save();
  }

  void focusCurrentSong() {
    final song = current.value;
    if (song == null) return;
    final list =
        playlists
            .where(
              (list) =>
                  list.id == _playingPlaylistId && list.songs.contains(song),
            )
            .firstOrNull ??
        playlists.where((list) => list.songs.contains(song)).firstOrNull;
    if (list == null) return;
    selectedId.value = list.id;
    focusRequest.value++;
  }

  Future<void> removeSongAndUnfavorite(
    ListeningPlaylist list,
    ListeningSong song,
  ) async {
    if (song.folderIds.isEmpty) throw StateError('此歌曲没有关联的个人收藏夹');
    if (!Accounts.main.isLogin || song.ownerMid != Accounts.main.mid) {
      throw StateError('请切换到导入收藏时使用的主账号');
    }
    await retryFavoriteSync(song);
    if (song.pendingFavoriteSync) throw StateError('请先完成上次换源的收藏同步');
    final folders = Set<int>.of(song.folderIds);
    final result = await updateFavorite(
      resources: '${song.source.aid}:2',
      delIds: folders.join(','),
    );
    if (!result.isSuccess) throw StateError('取消收藏失败，已保留歌单歌曲：$result');
    for (final playlist in playlists) {
      for (final other in playlist.songs) {
        if (other.ownerMid == song.ownerMid &&
            other.source.aid == song.source.aid) {
          other.folderIds.removeAll(folders);
        }
      }
    }
    await removeSong(list, song);
  }

  Future<VideoDetailData> detail(String bvid) async {
    final result = await VideoHttp.videoIntro(bvid: bvid);
    if (result case Success(:final response)) return response;
    throw StateError(result.toString());
  }

  Future<List<FavFolderInfo>> folders() async {
    if (!Accounts.main.isLogin) throw StateError('导入收藏需要登录主账号，匿名浏览可以保持开启');
    final result = await FavHttp.allFavFolders(Accounts.main.mid);
    if (result case Success(:final response)) {
      return (response.list ?? [])
          .where((e) => e.mid == Accounts.main.mid)
          .toList();
    }
    throw StateError(result.toString());
  }

  Future<List<SearchVideoItemModel>> search(String keyword, int page) async {
    final result = await SearchHttp.searchByType<SearchVideoData>(
      searchType: SearchType.video,
      keyword: keyword,
      page: page,
      onSuccess: (_) {},
    );
    if (result case Success(:final response)) return response.list ?? [];
    throw StateError(result.toString());
  }

  Future<Player> _ensurePlayer() async {
    try {
      return await (_creatingPlayer ??= _createPlayer());
    } catch (_) {
      _creatingPlayer = null;
      rethrow;
    }
  }

  void _notifyUnavailable(ListeningSong song) {
    if (_notifiedFailure == song.id) return;
    _notifiedFailure = song.id;
    scheduleMicrotask(() {
      if (identical(current.value, song) && song.error != null) {
        onUnavailable?.call(song);
      }
    });
  }

  Future<Player> _createPlayer() async {
    final player = await Player.create(
      configuration: PlayerConfiguration(
        options: {
          'video': 'no',
          if (Platform.isAndroid) 'ao': Pref.audioOutput,
          'volume':
              (Platform.isAndroid
                      ? Pref.playerVolume
                      : Pref.desktopVolume * 100)
                  .toString(),
          ...Pref.initBuffer(),
        },
      ),
    );
    _player = player;
    _subscriptions.addAll([
      player.stream.position.listen((value) {
        position.value = value;
        _publish();
      }),
      player.stream.duration.listen((value) {
        duration.value = value;
      }),
      player.stream.playing.listen((value) {
        playing.value = value;
        _publish();
      }),
      player.stream.error.listen((error) {
        final song = current.value;
        if (song != null) {
          if (loading.value) {
            _openError = error;
          } else if (_ownsMediaSession && _streamRetries < 2) {
            final list = playlists
                .where((list) => list.id == _playingPlaylistId)
                .firstOrNull;
            if (list != null)
              unawaited(
                play(
                  list,
                  song,
                  attempt: _streamRetries + 1,
                  resumeAt: position.value,
                ),
              );
          } else if (_ownsMediaSession) {
            song.error = '重试后仍无法播放，可再试一次或换源：$error';
            unawaited(save());
            _notifyUnavailable(song);
          }
        }
      }),
      player.stream.completed.listen((value) {
        if (!value || loading.value || current.value?.error != null) return;
        if (shutdownTimerService.isWaiting) {
          shutdownTimerService.handleWaiting();
        } else {
          unawaited(next(completed: true));
        }
      }),
    ]);
    return player;
  }

  void _bindSession() {
    _ownsMediaSession = true;
    pauseListening = _yieldPlayback;
    videoPlayerServiceHandler
      ?..onPlay = resume
      ..onPause = pause
      ..onSeek = seek
      ..onListeningMode = cycleMode
      ..onSkipToNext = () {
        unawaited(next());
      }
      ..onSkipToPrevious = () {
        unawaited(next(previous: true));
      };
    videoPlayerServiceHandler?.updateListeningMode(mode.value.name);
    shutdownTimerService
      ..onPause = () {
        unawaited(pause());
      }
      ..isPlaying = _isPlaying;
  }

  bool _isPlaying() => playing.value;

  Future<void> _yieldPlayback() async {
    await pause();
    _ownsMediaSession = false;
    pauseListening = null;
    if (videoPlayerServiceHandler?.onPlay == resume) {
      videoPlayerServiceHandler
        ?..onPlay = null
        ..onPause = null
        ..onSeek = null
        ..onSkipToNext = null
        ..onSkipToPrevious = null
        ..clearListeningMediaItem();
    }
    if (shutdownTimerService.isPlaying == _isPlaying) {
      shutdownTimerService
        ..onPause = null
        ..isPlaying = null;
    }
  }

  void _publish() {
    if (!_ownsMediaSession) return;
    videoPlayerServiceHandler?.onUpdateState(
      playing.value ? PlayerStatus.playing : PlayerStatus.paused,
      false,
      false,
      position: position.value,
      speed: speed.value,
    );
  }

  Future<void> play(
    ListeningPlaylist list,
    ListeningSong song, {
    int attempt = 0,
    Duration? resumeAt,
  }) async {
    final request = ++_request;
    _streamRetries = attempt;
    _notifiedFailure = null;
    loading.value = true;
    await _player?.pause();
    if (request != _request) return;
    current.value = song;
    _playingPlaylistId = list.id;
    position.value = duration.value = Duration.zero;
    try {
      await openSong(list, song, request);
      if (request != _request) return;
      if (resumeAt != null && resumeAt > Duration.zero)
        await _player?.seek(resumeAt);
      song.error = null;
    } catch (e) {
      if (request != _request) return;
      if (attempt < 2 && song.source.cid != 0) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (request != _request) return;
        await play(list, song, attempt: attempt + 1, resumeAt: resumeAt);
        return;
      }
      song.error = '重试后仍无法播放，可再试一次或搜索换源：$e';
      SmartDialog.showToast(song.error!);
      _notifyUnavailable(song);
    } finally {
      if (request == _request) {
        loading.value = false;
        await save();
      }
    }
  }

  Future<void> openSong(
    ListeningPlaylist list,
    ListeningSong song,
    int request,
  ) async {
    if (song.source.cid == 0) throw StateError('原视频信息不可用，请换源');
    final result = await VideoHttp.videoUrl(
      bvid: song.source.bvid,
      cid: song.source.cid,
      qn: 64,
      tryLook: true,
      videoType: VideoType.ugc,
    );
    if (request != _request) return;
    if (result case Success(:final response)) {
      final audios = response.dash?.audio;
      final urls = audios != null && audios.isNotEmpty
          ? audios.first.playUrls
          : response.durl?.firstOrNull?.playUrls;
      if (urls == null || urls.isEmpty) throw StateError('没有可播放的音源，请换源');
      final url = VideoUtils.getCdnUrl(urls, isAudio: true);
      final player = await _ensurePlayer();
      if (request != _request) return;
      await videoPlayerServiceHandler?.pause();
      await PlPlayerController.pauseIfExists();
      if (request != _request) return;
      _bindSession();
      await audioSessionHandler?.setActive(true);
      if (request != _request) return;
      videoPlayerServiceHandler?.setListeningMediaItem(
        MediaItem(
          id: 'listening:${song.id}',
          title: song.name,
          album: list.name,
          artUri: song.source.cover.isEmpty
              ? null
              : Uri.tryParse(song.source.cover),
        ),
      );
      player.setMediaHeader(
        userAgent: BrowserUa.pc,
        headers: {'Referer': 'https://www.bilibili.com/'},
      );
      _openError = null;
      await player.open(Media(url));
      if (_openError != null) throw StateError(_openError!);
      await player.setRate(speed.value);
      song.error = null;
    } else {
      throw StateError(result.toString());
    }
  }

  Future<void> resume() async {
    final song = current.value;
    if (song == null) return;
    if (song.error != null || _player == null) {
      final list = playlists
          .where((list) => list.songs.contains(song))
          .firstOrNull;
      if (list != null) await play(list, song);
      return;
    }
    if (!_ownsMediaSession) {
      await videoPlayerServiceHandler?.pause();
      await PlPlayerController.pauseIfExists();
    }
    _bindSession();
    await audioSessionHandler?.setActive(true);
    await _player?.play();
  }

  Future<void> pause() async {
    await _player?.pause();
  }

  Future<void> seek(Duration value) async {
    await _player?.seek(value);
  }

  Future<void> setSpeed(double value) async {
    speed.value = value;
    await _player?.setRate(value);
    _publish();
  }

  Future<void> next({bool previous = false, bool completed = false}) async {
    if (current.value == null) return;
    final list = playlists.where((e) => e.id == _playingPlaylistId).firstOrNull;
    if (list == null || list.songs.isEmpty) return;
    final index = list.songs.indexOf(current.value!);
    int target = index + (previous ? -1 : 1);
    if (completed && mode.value == ListeningMode.single) {
      target = index;
    } else if (mode.value == ListeningMode.shuffle && list.songs.length > 1) {
      target =
          (index + 1 + _random.nextInt(list.songs.length - 1)) %
          list.songs.length;
    } else if (target < 0 || target >= list.songs.length) {
      target = (target + list.songs.length) % list.songs.length;
    }
    await play(list, list.songs[target]);
  }

  // Add the new favorite before removing the old one. Keep a durable retry marker
  // if the second request fails; neither the original metadata nor song name changes.
  Future<LoadingState<void>> updateFavorite({
    required String resources,
    String? addIds,
    String? delIds,
  }) => FavHttp.favVideo(resources: resources, addIds: addIds, delIds: delIds);

  Future<void> replaceSource(ListeningSong song, SongSource replacement) async {
    await retryFavoriteSync(song);
    if (song.pendingFavoriteSync) throw StateError('请先完成上一轮收藏同步再换源');
    final old = song.source;
    if (old.key == replacement.key) return;
    if (song.folderIds.isNotEmpty) {
      if (!Accounts.main.isLogin || song.ownerMid != Accounts.main.mid) {
        throw StateError('请切换到导入收藏时使用的主账号后再同步换源');
      }
      final add = await updateFavorite(
        resources: '${replacement.aid}:2',
        addIds: song.folderIds.join(','),
      );
      if (!add.isSuccess) throw StateError('新视频收藏失败，已保留原音源：$add');
    }
    song.replace(replacement);
    song.pendingFavoriteSync =
        song.folderIds.isNotEmpty && old.aid != replacement.aid;
    await save();
    await retryFavoriteSync(song);
    if (identical(current.value, song)) {
      final list = playlists.firstWhere((e) => e.songs.contains(song));
      await play(list, song);
    }
  }

  Future<void> retryFavoriteSync(ListeningSong song) async {
    if (!song.pendingFavoriteSync) return;
    if (!Accounts.main.isLogin || song.ownerMid != Accounts.main.mid) {
      throw StateError('请登录导入收藏时的账号后重试同步');
    }
    final old = song.previousSources.last;
    // Other selected parts may still need the old video in the favorite folder.
    final removable = song.folderIds
        .where(
          (folder) => !playlists.any(
            (list) => list.songs.any(
              (other) =>
                  !identical(other, song) &&
                  other.ownerMid == song.ownerMid &&
                  other.folderIds.contains(folder) &&
                  other.source.aid == old.aid,
            ),
          ),
        )
        .toList();
    if (removable.isNotEmpty) {
      final remove = await updateFavorite(
        resources: '${old.aid}:2',
        delIds: removable.join(','),
      );
      if (!remove.isSuccess) {
        SmartDialog.showToast('新视频已收藏；旧收藏未移除，可点击重试同步');
        return;
      }
    }
    song.pendingFavoriteSync = false;
    await save();
  }

  @override
  void onClose() {
    ++_request;
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _player?.dispose();
    super.onClose();
  }
}
