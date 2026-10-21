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
import 'package:PiliPlus/pages/listening/song_name.dart';
import 'package:PiliPlus/pages/listening/lyrics.dart';
import 'package:PiliPlus/pages/listening/audio_proxy.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/services/shutdown_timer_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:audio_service/audio_service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';

enum ListeningMode { list, shuffle, single }

class ListeningController extends GetxController {
  static const storageKey = 'listeningPlaylistsV1';
  static const _networkChannel = MethodChannel(
    'com.example.piliplus/listening_network',
  );
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
  final activeLyrics = Rxn<LyricTrack>();
  final lyricsOffset = Duration.zero.obs;
  final lyricsLoading = false.obs;
  final isMobileNetwork = false.obs;
  final mobileBytes = 0.obs;
  int _receivedMobileBytes = 0;
  int _trafficSession = 0;
  int _lyricsRequest = 0;
  String? _lyricsIdentity;
  String? _lyricsDurationRetry;
  /// Creates the lyric/translation service. Tests replace it with a stub.
  ListeningLyrics Function() newLyrics = ListeningLyrics.new;
  void applyLyricsSettings(LyricTrack track, Duration offset) {
    _lyricsRequest++;
    lyricsLoading.value = false;
    activeLyrics.value = track;
    lyricsOffset.value = offset;
  }

  ListeningAudioProxy? _audioProxy;
  Timer? _trafficTimer;
  StreamSubscription<List<ConnectivityResult>>? _networkSubscription;
  Future<void> _watchNetwork() async {
    if (_networkSubscription != null) return;
    var networkUpdate = 0;
    Future<void> update(List<ConnectivityResult> networks) async {
      final updateId = ++networkUpdate;
      final mobileOnly =
          networks.contains(ConnectivityResult.mobile) &&
          !networks.contains(ConnectivityResult.wifi) &&
          !networks.contains(ConnectivityResult.ethernet);
      var meteredWifi = false;
      if (Platform.isAndroid && networks.contains(ConnectivityResult.wifi)) {
        try {
          meteredWifi =
              await _networkChannel.invokeMethod<bool>('isMeteredWifi') ??
              false;
        } on PlatformException catch (_) {
          meteredWifi = false;
        }
      }
      if (updateId == networkUpdate) {
        isMobileNetwork.value = mobileOnly || meteredWifi;
      }
    }

    try {
      update(await Connectivity().checkConnectivity());
      _networkSubscription = Connectivity().onConnectivityChanged.listen(
        update,
      );
    } catch (_) {
      isMobileNetwork.value = false;
    }
  }

  /// Loads everything that belongs to the newly played song instead of the
  /// audio stream: three lines of lyrics, the offset, the Chinese name and
  /// (for a raw video title) the recognised song name. Every step catches its
  /// own failure, so playback never waits on or is broken by metadata.
  Future<void> prepareSongMetadata(ListeningSong song) async {
    try {
      await loadCurrentLyrics();
    } catch (_) {
      /* The compact view keeps whatever lyrics are already loaded. */
    }
    if (!identical(current.value, song)) return;
    try {
      await translateCurrentSongName();
    } catch (_) {
      /* Retried by the next refresh; failures are never cached. */
    }
    if (!identical(current.value, song)) return;
    if (song.nameEdited || song.namedSource != null) return;
    // A name that is still the raw video title is replaced by the consensus
    // of other videos of the same song, with a marker that keeps the search
    // from running on every play.
    try {
      final renamed = (await _recognizeOnce(song)).$2;
      if (renamed) unawaited(translateSongNames());
    } catch (_) {
      /* Retried on the next refresh; recognition is best effort. */
    }
  }

  Future<void> loadCurrentLyrics() async {
    final song = current.value;
    final request = ++_lyricsRequest;
    if (song == null) {
      _lyricsIdentity = null;
      activeLyrics.value = null;
      lyricsLoading.value = false;
      return;
    }
    final identity = '${song.source.key}:${song.name}';
    // Switching songs must not show the previous song's lines, but reloading
    // the same song keeps the current lines visible while refreshing.
    if (_lyricsIdentity != identity) {
      _lyricsIdentity = identity;
      activeLyrics.value = null;
    }
    lyricsOffset.value = Duration(
      milliseconds: GStorage.localCache.get(
        'listeningLyricsOffset:${song.source.key}',
        defaultValue: 0,
      ),
    );
    final service = newLyrics();
    final name = song.name;
    try {
      final cached = service.saved(song);
      final translation = service.saved(song, translation: true);
      final initial = cached?.priority == 0 ? cached : translation ?? cached;
      if (initial != null && activeLyrics.value == null)
        activeLyrics.value = initial;
      lyricsLoading.value = true;
      final snapshot = ListeningSong(
        id: song.id,
        name: name,
        original: song.original,
        source: song.source,
      );
      final track = await service.preferred(
        snapshot,
        currentDuration: () => duration.value,
      );
      if (request == _lyricsRequest &&
          identical(current.value, song) &&
          song.name == name)
        activeLyrics.value = track ?? initial;
    } catch (_) {
      /* Keep the cached lyrics when a service is unavailable. */
    } finally {
      service.close();
      if (request == _lyricsRequest) {
        lyricsLoading.value = false;
        // The first search often runs before the player reports a duration,
        // which is required to reject same-name covers. Retry once afterwards.
        if (duration.value > Duration.zero) _lyricsDurationRetry = identity;
      }
    }
  }

  /// Re-runs the automatic lyric match once the real audio duration is known.
  void _retryLyricsForDuration(Duration value) {
    if (value <= Duration.zero) return;
    final song = current.value;
    if (song == null || lyricsLoading.value) return;
    final identity = '${song.source.key}:${song.name}';
    if (_lyricsIdentity != identity || _lyricsDurationRetry == identity) return;
    _lyricsDurationRetry = identity;
    if (activeLyrics.value?.priority == 0) return;
    unawaited(loadCurrentLyrics());
  }

  bool _translatingNames = false;
  bool _translationPending = false;
  Future<void> translateSongNames({ListeningLyrics? service}) async {
    if (_translatingNames) {
      _translationPending = true;
      return;
    }
    _translatingNames = true;
    final lyrics = service ?? newLyrics();
    var quota = false;
    try {
      for (final list in playlists.toList()) {
        for (final song in list.songs.toList()) {
          if (quota) break;
          final name = song.name;
          if (song.translatedNameSource == name) continue;
          final context = '${song.source.title} ${song.original.title}';
          if (ListeningLyrics.nameLanguage(name, context: context) == null)
            continue;
          try {
            final translated = await lyrics.translateName(
              name,
              context: context,
            );
            if (song.name != name || !list.songs.contains(song)) continue;
            song.translatedNameSource = name;
            song.chineseName = translated;
            await save();
          } on LyricsTranslationException catch (error) {
            // Only an exhausted quota stops the queue; a single unavailable
            // name must not block every remaining song.
            if (error.quota) quota = true;
            continue;
          } catch (_) {
            continue;
          }
        }
      }
    } finally {
      lyrics.close();
      _translatingNames = false;
      if (_translationPending) {
        _translationPending = false;
        unawaited(translateSongNames());
      }
    }
  }

  /// Translates just the song that is playing, so its notification title and
  /// the three-line lyrics header pick up the Chinese name without waiting for
  /// a full playlist scan.
  Future<void> translateCurrentSongName({ListeningLyrics? service}) async {
    final song = current.value;
    if (song == null) return;
    final name = song.name;
    if (song.translatedNameSource == name) return;
    final context = '${song.source.title} ${song.original.title}';
    if (ListeningLyrics.nameLanguage(name, context: context) == null) return;
    final lyrics = service ?? newLyrics();
    try {
      final translated = await lyrics.translateName(name, context: context);
      if (song.name != name) return;
      song.translatedNameSource = name;
      song.chineseName = translated;
      await save();
    } catch (_) {
      /* Retried on the next refresh; failures are never cached. */
    } finally {
      lyrics.close();
    }
  }

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
  bool _naming = false;
  bool _namingPending = false;
  Future<void> refreshSongNames() async {
    if (_naming) {
      _namingPending = true;
      return;
    }
    _naming = true;
    try {
      for (final list in playlists.toList()) {
        for (final song in list.songs.toList()) {
          if (song.nameEdited ||
              song.namedSource == song.source.key ||
              song.source.cid == 0)
            continue;
          final source = song.source;
          try {
            final name = await ListeningMetadata().name(source);
            if (song.nameEdited ||
                song.source.key != source.key ||
                !list.songs.contains(song))
              continue;
            if (name != null) song.name = name;
            // Remember that the tag was read: a missing BGM tag must not
            // trigger a metadata request on every refresh, and a song without
            // a tag keeps its title for the search based recognition pass.
            song.namedSource = source.key;
            await save();
          } catch (_) {
            /* Retry metadata later; playback remains available. */
          }
        }
      }
    } finally {
      _naming = false;
      if (_namingPending) {
        _namingPending = false;
        unawaited(refreshSongNames());
      } else {
        unawaited(recognizeSongNames());
        unawaited(translateSongNames());
      }
    }
  }

  bool _recognizing = false;
  bool _recognizePending = false;
  /// Applies a name inferred from the titles of the same song's other videos.
  /// Recognition only ever replaces the local display name: the original
  /// bvid/cid/page/title are kept, and manual names are never overwritten.
  Future<bool> recognizeSongName(ListeningSong song) async {
    final sourceKey = song.source.key;
    if (song.nameEdited || song.source.cid == 0) return false;
    try {
      final items = await search(song.name, 1);
      final unique = <String, String>{};
      for (final item in items) {
        final bvid = item.bvid;
        if (bvid != null && bvid.isNotEmpty) unique[bvid] = item.title;
      }
      final consensus = inferSongName(unique.values);
      if (consensus == null) return false;
      return applySearchSongName(song, sourceKey, consensus);
    } catch (_) {
      return false;
    }
  }

  /// Lets the page show what automatic recognition changed. It stays a
  /// callback so the controller never touches UI state on its own.
  void Function(String message)? onNotice;
  void _notice(String message) {
    try {
      onNotice?.call(message);
    } catch (_) {
      /* A missing UI must not break the metadata pipeline. */
    }
  }

  /// Recognises names for songs that still use a raw video title, e.g. after
  /// an import. Runs in the background so the page stays responsive.
  Future<void> recognizeSongNames({int limit = 3}) async {
    if (_recognizing) {
      _recognizePending = true;
      return;
    }
    _recognizing = true;
    var searched = 0;
    var renamed = 0;
    try {
      for (final list in playlists.toList()) {
        for (final song in list.songs.toList()) {
          if (searched >= limit) break;
          final result = await _recognizeOnce(song);
          if (!result.$1) continue;
          searched++;
          if (result.$2) renamed++;
        }
      }
    } finally {
      _recognizing = false;
      if (renamed > 0) {
        _notice('已按同名视频自动识别 $renamed 首歌名');
        unawaited(translateSongNames());
      }
      if (_recognizePending) {
        _recognizePending = false;
        unawaited(recognizeSongNames(limit: limit));
      }
    }
  }

  /// One guarded recognition attempt; the marker keeps a song from being
  /// re-searched on every play or refresh.
  /// Returns `(attempted, renamed)`.
  Future<(bool, bool)> _recognizeOnce(ListeningSong song) async {
    final source = song.source;
    if (song.nameEdited || source.cid == 0) return (false, false);
    // Only songs whose name is still the untouched video title need it.
    if (song.namedSource != null &&
        song.name != source.title &&
        song.name != song.original.title)
      return (false, false);
    final marker = 'listeningNameSearch:${source.key}';
    if (GStorage.localCache.get(marker) == song.name) return (false, false);
    final before = song.name;
    try {
      await recognizeSongName(song);
    } finally {
      await GStorage.localCache.put(marker, song.name);
    }
    return (true, song.name != before);
  }

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
    final song = current.value;
    final item = videoPlayerServiceHandler?.mediaItem.value;
    // A renamed or re-recognised song must re-run the lyric search even when
    // the media session belongs to another page.
    if (song != null && _lyricsIdentity != '${song.source.key}:${song.name}') {
      unawaited(loadCurrentLyrics());
    }
    if (_ownsMediaSession &&
        song != null &&
        item?.id == 'listening:${song.id}' &&
        item!.title != song.displayName) {
      videoPlayerServiceHandler?.setListeningMediaItem(
        item.copyWith(title: song.displayName),
      );
    }
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

  Future<bool> applySearchSongName(
    ListeningSong song,
    String sourceKey,
    SongNameConsensus consensus,
  ) async {
    if (song.nameEdited ||
        song.source.key != sourceKey ||
        !playlists.any((list) => list.songs.contains(song)))
      return false;
    if (song.name == consensus.name) return true;
    song.name = consensus.name;
    song.namedSource = sourceKey;
    await save();
    unawaited(translateSongNames());
    return true;
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
        _retryLyricsForDuration(value);
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
    videoPlayerServiceHandler?.bindListeningSession(
      play: resume,
      pause: pause,
      seek: seek,
      mode: cycleMode,
      next: () => next(),
      previous: () => next(previous: true),
    );
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
    videoPlayerServiceHandler?.clearListeningMediaItem();
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
      listening: true,
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
    if (attempt == 0) {
      // Lyrics and the Chinese name belong to the song, not to the audio
      // stream: load them right away so a slow or failing stream never leaves
      // the three-line lyrics and the notification title stale.
      unawaited(prepareSongMetadata(song));
      _trafficSession++;
      _receivedMobileBytes = 0;
      mobileBytes.value = 0;
    }
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
          title: song.displayName,
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
      await _watchNetwork();
      if (request != _request) return;
      _trafficTimer ??= Timer.periodic(
        const Duration(seconds: 1),
        (_) => mobileBytes.value = _receivedMobileBytes,
      );
      final trafficSession = _trafficSession;
      final previousProxy = _audioProxy;
      _audioProxy = null;
      await previousProxy?.close();
      if (request != _request) return;
      final proxy = await ListeningAudioProxy.create(
        Uri.parse(url),
        (bytes) {
          if (trafficSession == _trafficSession && isMobileNetwork.value) {
            _receivedMobileBytes += bytes;
          }
        },
        userAgent: BrowserUa.pc,
        cacheKey: song.source.key,
      );
      if (request != _request) {
        await proxy.close();
        return;
      }
      _audioProxy = proxy;
      _openError = null;
      await player.open(Media(proxy.url));
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
    ++_lyricsRequest;
    _trafficTimer?.cancel();
    _networkSubscription?.cancel();
    _audioProxy?.close();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _player?.dispose();
    super.onClose();
  }
}
