import 'dart:async';

import 'package:PiliPlus/http/fav.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/user.dart';
import 'package:PiliPlus/models/search/result.dart';
import 'package:PiliPlus/models_new/video/video_detail/data.dart';
import 'package:PiliPlus/models_new/video/video_detail/page.dart';
import 'package:PiliPlus/pages/listening/controller.dart';
import 'package:PiliPlus/pages/listening/favorite_link.dart';
import 'package:PiliPlus/pages/listening/models.dart';
import 'package:PiliPlus/pages/listening/song_name.dart';
import 'package:PiliPlus/pages/listening/lyrics_view.dart';
import 'package:PiliPlus/pages/listening/compact_lyrics.dart';
import 'package:PiliPlus/pages/listening/audio_proxy.dart';
import 'package:PiliPlus/services/shutdown_timer_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/url_utils.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class ListeningPage extends StatefulWidget {
  const ListeningPage({super.key, this.embedded = false});
  final bool embedded;
  @override
  State<ListeningPage> createState() => _ListeningPageState();
}

class _ListeningPageState extends State<ListeningPage> {
  late final ListeningController controller =
      Get.isRegistered<ListeningController>()
      ? Get.find<ListeningController>()
      : Get.put(ListeningController(), permanent: true);
  bool _busy = false;
  bool _cancelImport = false;
  String _progress = '';
  bool _listExpanded = true;
  final _playlistMenu = MenuController();
  final _songsScroll = ScrollController();
  late final Worker _focusWorker;

  @override
  void initState() {
    super.initState();
    controller.onUnavailable = _onUnavailable;
    _focusWorker = ever(controller.focusRequest, (_) => _focusPlayingSong());
    controller.focusCurrentSong();
    unawaited(controller.refreshSongNames());
  }

  void _focusPlayingSong() {
    if (mounted && !_listExpanded) setState(() => _listExpanded = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final song = controller.current.value;
      if (!mounted || song == null || !_songsScroll.hasClients) return;
      final index = controller.selected.songs.indexOf(song);
      if (index < 0) return;
      final position = _songsScroll.position;
      final offset = (index * 80.0 - (position.viewportDimension - 80) / 2)
          .clamp(0.0, position.maxScrollExtent);
      _songsScroll.animateTo(
        offset,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  void _onUnavailable(ListeningSong song) {
    if (mounted && !_busy && ModalRoute.of(context)?.isCurrent == true) {
      unawaited(
        _run(() async {
          final action = await showDialog<String>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('暂时无法播放'),
              content: const Text('暂时无法取得可播放音源。可以再试一次，或搜索其他音源。'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('稍后'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, 'replace'),
                  child: const Text('搜索换源'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, 'retry'),
                  child: const Text('重试播放'),
                ),
              ],
            ),
          );
          if (!mounted || !identical(song, controller.current.value)) return;
          if (action == 'retry') await controller.resume();
          if (action == 'replace') await _replace(song);
        }),
      );
    }
  }

  @override
  void dispose() {
    if (controller.onUnavailable == _onUnavailable) {
      controller.onUnavailable = null;
    }
    _cancelImport = true;
    _focusWorker.dispose();
    _songsScroll.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      SmartDialog.showToast(e.toString());
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = '';
        });
      }
    }
  }

  Future<String?> _text(
    String title, {
    String initial = '',
    String? hint,
  }) async {
    final input = TextEditingController(text: initial);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: input,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) Navigator.pop(context, value.trim());
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              if (input.text.trim().isNotEmpty) {
                Navigator.pop(context, input.text.trim());
              }
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
    // The dialog route can still be animating after its future completes.
    Future<void>.delayed(const Duration(seconds: 1), input.dispose);
    return value;
  }

  Future<List<Part>?> _parts(
    VideoDetailData data, {
    bool single = false,
  }) async {
    final parts = (data.pages ?? []).where((p) => p.cid != null).toList();
    if (parts.isEmpty) throw StateError('没有可用的分 P');
    if (parts.length == 1) return parts;
    if (!mounted) return null;
    final selected = <int>{};
    return showDialog<List<Part>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(single ? '选择替换音源的分 P' : '选择要导入的分 P'),
          content: SizedBox(
            width: 500,
            height: 380,
            child: Column(
              children: [
                Text(
                  data.title ?? '',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (!single)
                  TextButton(
                    onPressed: () => setState(() {
                      if (selected.length == parts.length) {
                        selected.clear();
                      } else {
                        selected.addAll(parts.map((e) => e.cid!));
                      }
                    }),
                    child: const Text('全选 / 清空'),
                  ),
                Expanded(
                  child: ListView.builder(
                    itemCount: parts.length,
                    itemBuilder: (context, i) {
                      final part = parts[i];
                      return CheckboxListTile(
                        value: selected.contains(part.cid),
                        title: Text(
                          'P${part.page} · ${part.part ?? data.title}',
                        ),
                        onChanged: (value) => setState(() {
                          if (single) selected.clear();
                          if (value == true) {
                            selected.add(part.cid!);
                          } else {
                            selected.remove(part.cid);
                          }
                        }),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('跳过'),
            ),
            FilledButton(
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.pop(
                      context,
                      parts.where((p) => selected.contains(p.cid)).toList(),
                    ),
              child: Text(single ? '选择此音源' : '导入 ${selected.length} 首'),
            ),
          ],
        ),
      ),
    );
  }

  SongSource _source(VideoDetailData video, Part part) => SongSource(
    bvid: video.bvid!,
    aid: video.aid!,
    cid: part.cid!,
    page: part.page ?? 1,
    title: video.title ?? '',
    cover: video.pic ?? '',
  );

  Future<void> _addVideo(
    ListeningPlaylist list,
    String bvid, {
    int? folderId,
    int? folderOwnerMid,
  }) async {
    final detail = await controller.detail(bvid);
    final parts = await _parts(detail);
    if (parts == null || !mounted) return;
    for (final part in parts) {
      final name = parts.length > 1 || (detail.pages?.length ?? 0) > 1
          ? part.part ?? detail.title ?? bvid
          : detail.title ?? bvid;
      final source = _source(detail, part);
      list.add(
        ListeningSong(
          id: controller.newId(),
          name: name,
          original: source,
          folderIds: {?folderId},
          ownerMid: folderId == null ? null : folderOwnerMid,
        ),
      );
    }
    await controller.save();
    unawaited(controller.refreshSongNames());
  }

  Future<void> _addVideoLink() async {
    final list = controller.selected;
    var input = await _text('从 BV 号 / 链接导入', hint: 'BV / av 号、视频链接或公开收藏夹链接');
    if (input == null) return;
    final uri = favoriteLinkUri(input);
    if (uri?.host == 'b23.tv') {
      input = await UrlUtils.parseRedirectUrl(uri.toString());
      if (input == null) throw StateError('无法解析短链接，请复制完整链接');
    }
    final folder = favoriteFolderId(input);
    if (folder != null) {
      await _importFolder(folder);
      return;
    }
    final bv = RegExp(r'BV[0-9A-Za-z]{10}').firstMatch(input)?.group(0);
    final av = RegExp(
      r'(?:av)(\d+)',
      caseSensitive: false,
    ).firstMatch(input)?.group(1);
    if (bv == null && av == null) throw StateError('请输入完整 BV 号、av 号或包含它们的视频链接');
    await _addVideo(list, bv ?? IdUtils.av2bv(int.parse(av!)));
  }

  Future<void> _importFavorites() async {
    final folders = await controller.folders();
    if (!mounted) return;
    final folder = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('导入我的收藏夹'),
        children: [
          if (folders.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('没有可导入的收藏夹'),
            ),
          for (final folder in folders)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, folder.id),
              child: Text('${folder.title} · ${folder.mediaCount} 个视频'),
            ),
        ],
      ),
    );
    if (folder == null) return;
    await _importFolder(folder);
  }

  Future<void> _importFolder(int folder) async {
    final list = controller.selected;
    int? syncFolder;
    int? ownerMid;
    _cancelImport = false;
    var count = 0;
    for (var page = 1; mounted && !_cancelImport; page++) {
      final result = await FavHttp.userFavFolderDetail(
        mediaId: folder,
        pn: page,
        ps: 20,
      );
      if (result case Success(:final response)) {
        if (page == 1) {
          final info = response.info;
          final mid = info?.upper?.mid ?? info?.mid;
          final owned = Accounts.main.isLogin && mid == Accounts.main.mid;
          if (owned) {
            syncFolder = folder;
            ownerMid = mid;
          }
          if (!mounted) return;
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text('导入 ${info?.title ?? "收藏夹"}'),
              content: Text(
                '${info?.mediaCount ?? response.medias?.length ?? 0} 个视频，多 P 视频可逐项选择。\n\n'
                '${owned ? "这是你的收藏夹，换源时会同步更新收藏。" : "导入本地歌单，换源仅更新歌单，不修改他人的收藏夹。"}',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('开始导入'),
                ),
              ],
            ),
          );
          if (confirmed != true || !mounted) return;
        }
        final videos = response.medias ?? [];
        if (videos.isEmpty) break;
        for (final video in videos) {
          if (!mounted || _cancelImport) break;
          if (video.type != 2 || video.id == null) continue;
          setState(() => _progress = '导入第 ${++count} 个视频：${video.title ?? ""}');
          final bvid = video.bvid?.isNotEmpty == true
              ? video.bvid!
              : IdUtils.av2bv(video.id!);
          try {
            await _addVideo(
              list,
              bvid,
              folderId: syncFolder,
              folderOwnerMid: ownerMid,
            );
          } catch (e) {
            // Keep even already-invalid favorite entries so their name can be
            // corrected and used for source search later.
            final source = SongSource(
              bvid: bvid,
              aid: video.id!,
              cid: 0,
              page: 1,
              title: video.title ?? bvid,
              cover: video.cover ?? '',
            );
            list.add(
              ListeningSong(
                id: controller.newId(),
                name: video.title ?? bvid,
                original: source,
                folderIds: {?syncFolder},
                ownerMid: ownerMid,
                error: '无法获取原视频，保留条目以便换源：$e',
              ),
            );
            await controller.save();
          }
        }
        if (response.hasMore != true) break;
      } else {
        throw StateError('收藏导入中断，已导入的歌曲已保存：$result');
      }
    }
    SmartDialog.showToast('导入结束，已保存歌单；重复分 P 已合并');
  }

  Future<void> _replace(ListeningSong song) async {
    final candidate = await showDialog<SearchVideoItemModel>(
      context: context,
      builder: (_) => _SourceSearch(controller: controller, song: song),
    );
    if (candidate?.bvid == null || !mounted) return;
    final detail = await controller.detail(candidate!.bvid!);
    final parts = await _parts(detail, single: true);
    if (parts == null || parts.isEmpty || !mounted) return;
    final replacement = _source(detail, parts.first);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('替换音源'),
        content: Text(
          '歌曲：${song.name}\n新音源：${replacement.title} · P${replacement.page}\n\n'
          '${song.folderIds.isEmpty ? "此条目没有关联收藏夹，仅更新本地歌单。" : "同时将新视频加入关联收藏夹，成功后移除旧视频收藏。其他歌曲仍使用旧视频时会保留旧收藏。"}'
          '\n原视频信息和歌曲名称会保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('替换并同步收藏'),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.replaceSource(song, replacement);
  }

  Future<void> _play(ListeningPlaylist list, ListeningSong song) async {
    await controller.play(list, song);
  }

  Future<void> _chooseSongTag(ListeningSong song) async {
    final result = await UserHttp.videoTags(
      bvid: song.source.bvid,
      cid: song.source.cid,
    );
    if (!mounted) return;
    if (result case Success(:final response)) {
      final names = (response ?? [])
          .map((e) => e.tagName?.replaceFirst(RegExp(r'^发现'), '').trim() ?? '')
          .where((e) => e.isNotEmpty)
          .toSet()
          .toList();
      if (names.isEmpty) {
        SmartDialog.showToast('这个视频没有可用标签，可手动修改歌名');
        return;
      }
      final name = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('从视频标签选择歌名'),
          children: names
              .map(
                (e) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, e),
                  child: Text(e),
                ),
              )
              .toList(),
        ),
      );
      if (name != null) {
        song.name = name;
        song.nameEdited = true;
        song.namedSource = song.source.key;
        await controller.save();
        unawaited(controller.translateSongNames());
      }
    } else {
      throw StateError('读取视频标签失败，请稍后重试');
    }
  }

  String _time(Duration duration) =>
      '${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';

  Widget _playbackBar() => Obx(() {
    final song = controller.current.value;
    final total = controller.duration.value.inSeconds;
    final position = controller.position.value.inSeconds.clamp(0, total);
    final modeLabel = switch (controller.mode.value) {
      ListeningMode.list => '列表循环',
      ListeningMode.shuffle => '随机播放',
      ListeningMode.single => '单曲循环',
    };
    final transport = <Widget>[
      IconButton(
        tooltip: '定时关闭',
        icon: const Icon(Icons.bedtime_outlined, size: 28),
        onPressed: () => shutdownTimerService.showScheduleExitDialog(
          context,
          isFullScreen: false,
        ),
      ),
      IconButton(
        tooltip: '上一首',
        icon: const Icon(Icons.skip_previous, size: 30),
        onPressed: song == null ? null : () => controller.next(previous: true),
      ),
      IconButton.filled(
        tooltip: controller.playing.value ? '暂停' : '播放',
        iconSize: 36,
        padding: const EdgeInsets.all(12),
        icon: Icon(controller.playing.value ? Icons.pause : Icons.play_arrow),
        onPressed: song == null || controller.loading.value
            ? null
            : () => controller.playing.value
                  ? controller.pause()
                  : controller.resume(),
      ),
      IconButton(
        tooltip: '下一首',
        icon: const Icon(Icons.skip_next, size: 30),
        onPressed: song == null ? null : () => controller.next(),
      ),
      IconButton(
        tooltip: modeLabel,
        icon: Icon(switch (controller.mode.value) {
          ListeningMode.list => Icons.repeat,
          ListeningMode.shuffle => Icons.shuffle,
          ListeningMode.single => Icons.repeat_one,
        }),
        onPressed: controller.cycleMode,
      ),
    ];
    final listToggle = SizedBox(
      width: 64,
      child: TextButton(
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _listExpanded ? Icons.keyboard_arrow_down : Icons.queue_music,
              size: 28,
            ),
            Text(
              _listExpanded ? '收起列表' : '展开列表',
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
        onPressed: () => setState(() => _listExpanded = !_listExpanded),
      ),
    );
    final traffic = song != null && controller.isMobileNetwork.value
        ? Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              '耗费流量：${formatAudioBytes(controller.mobileBytes.value)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          )
        : const SizedBox.shrink();
    final controls = LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 600 &&
            song != null &&
            controller.isMobileNetwork.value) {
          return Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: transport,
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [traffic, listToggle],
              ),
            ],
          );
        }
        return Row(
          children: [...transport, const Spacer(), traffic, listToggle],
        );
      },
    );
    return Material(
      elevation: 3,
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: null,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              song?.displayName ?? '尚未选择歌曲',
                              style: Theme.of(context).textTheme.titleMedium,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (song != null)
                            IconButton(
                              tooltip: '歌词设置',
                              onPressed: () async {
                                await Get.to(
                                  () => ListeningLyricsView(
                                    song: song,
                                    controller: controller,
                                  ),
                                );
                              },
                              icon: const Icon(Icons.tune, size: 22),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (song?.error != null)
                  IconButton(
                    tooltip: '重试播放',
                    onPressed: () => controller.resume(),
                    icon: const Icon(Icons.refresh),
                  ),
                const SizedBox(width: 12),
                Text(
                  '${_time(controller.position.value)} / ${_time(controller.duration.value)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            if (controller.loading.value) const LinearProgressIndicator(),
            SizedBox(
              height: 40,
              child: Slider(
                value: position.toDouble(),
                max: total > 0 ? total.toDouble() : 1,
                onChanged: song == null || total == 0
                    ? null
                    : (value) =>
                          controller.seek(Duration(seconds: value.round())),
              ),
            ),
            controls,
          ],
        ),
      ),
    );
  });

  Widget _songList() => Obx(() {
    final list = controller.selected;
    if (list.songs.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '歌单还是空的\n添加视频或导入收藏，多 P 视频可以逐项选择。',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _songsScroll,
      itemExtent: 80,
      itemCount: list.songs.length,
      itemBuilder: (context, i) {
        final song = list.songs[i];
        return ListTile(
          selected: identical(song, controller.current.value),
          leading: Icon(
            song.error == null
                ? Icons.music_note_outlined
                : Icons.error_outline,
          ),
          title: Text(
            song.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            song.error == null
                ? 'P${song.source.page} · ${song.source.bvid}'
                : '播放不可用 · 原信息已保留，可搜索换源',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => _play(list, song),
          trailing: PopupMenuButton<String>(
            tooltip: '歌曲操作',
            onSelected: (action) => _run(() async {
              switch (action) {
                case 'replace':
                  await _replace(song);
                case 'tags':
                  await _chooseSongTag(song);
                case 'lyrics':
                  await Get.to(
                    () =>
                        ListeningLyricsView(song: song, controller: controller),
                  );
                case 'rename':
                  final name = await _text(
                    '修改歌曲名称（用于换源搜索）',
                    initial: song.name,
                  );
                  if (name != null) {
                    song.name = name;
                    song.nameEdited = true;
                    await controller.save();
                    unawaited(controller.translateSongNames());
                  }
                case 'delete':
                  await controller.removeSong(list, song);
                case 'unfavorite':
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('删除并取消收藏'),
                      content: Text(
                        '将“${song.name}”从歌单删除，并从关联的 ${song.folderIds.length} 个个人收藏夹移除当前视频。\n\n收藏按整个视频取消，同一视频的其他分 P 也会失去该收藏关联，但保留在歌单中。',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('取消'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('删除并取消收藏'),
                        ),
                      ],
                    ),
                  );
                  if (confirmed == true)
                    await controller.removeSongAndUnfavorite(list, song);
                case 'sync':
                  await controller.retryFavoriteSync(song);
                case 'original':
                  if (!mounted) return;
                  var source = song.original;
                  if (source.cid == 0) {
                    final video = await controller.detail(source.bvid);
                    final parts = video.pages ?? [];
                    final part = parts
                        .where((e) => e.page == source.page)
                        .firstOrNull;
                    if (part?.cid == null) throw StateError('原视频已失效或原分 P 不可用');
                    source = _source(video, part!);
                  }
                  await PageUtils.toVideoPage(
                    aid: source.aid,
                    bvid: source.bvid,
                    cid: source.cid,
                    title: source.title,
                    cover: source.cover,
                  );
              }
            }),
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'lyrics', child: Text('歌词设置')),
              const PopupMenuItem(value: 'tags', child: Text('使用歌曲标签命名')),
              const PopupMenuItem(value: 'replace', child: Text('搜索换源并同步收藏')),
              const PopupMenuItem(value: 'rename', child: Text('修改歌曲名称')),
              const PopupMenuItem(value: 'original', child: Text('查看原视频')),
              if (song.pendingFavoriteSync)
                const PopupMenuItem(value: 'sync', child: Text('重试同步收藏')),
              const PopupMenuItem(value: 'delete', child: Text('从歌单删除（保留收藏）')),
              PopupMenuItem(
                value: 'unfavorite',
                enabled: song.folderIds.isNotEmpty,
                child: const Text('从歌单删除并取消收藏'),
              ),
            ],
          ),
        );
      },
    );
  });

  Future<void> _playlistAction(String action, ListeningPlaylist list) async {
    _playlistMenu.close();
    await _run(() async {
      if (action == 'rename') {
        final name = await _text('重命名歌单', initial: list.name);
        if (name != null) await controller.renamePlaylist(list, name);
      } else {
        await controller.deletePlaylist(list);
      }
    });
  }

  Widget _playlistSelector() => Obx(
    () => MenuAnchor(
      controller: _playlistMenu,
      consumeOutsideTap: true,
      menuChildren: [
        for (final list in controller.playlists)
          SizedBox(
            width: 280,
            child: Row(
              children: [
                Expanded(
                  child: MenuItemButton(
                    onPressed: () {
                      controller.selectedId.value = list.id;
                      _playlistMenu.close();
                    },
                    child: Text(list.name, overflow: TextOverflow.ellipsis),
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: '歌单操作：${list.name}',
                  icon: const Icon(Icons.more_vert),
                  onSelected: (action) => _playlistAction(action, list),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'rename', child: Text('重命名')),
                    PopupMenuItem(value: 'delete', child: Text('删除')),
                  ],
                ),
              ],
            ),
          ),
        const Divider(height: 1),
        MenuItemButton(
          leadingIcon: const Icon(Icons.add),
          onPressed: () {
            _playlistMenu.close();
            _run(() async {
              final name = await _text('新建歌单');
              if (name != null) await controller.createPlaylist(name);
            });
          },
          child: const Text('新建歌单'),
        ),
      ],
      builder: (context, menu, child) => TextButton(
        onPressed: _busy
            ? null
            : () => menu.isOpen ? menu.close() : menu.open(),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                controller.selected.name,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    primary: !widget.embedded,
    appBar: AppBar(
      primary: !widget.embedded,
      automaticallyImplyLeading: false,
      titleSpacing: 4,
      title: _playlistSelector(),
      actions: [
        MenuAnchor(
          consumeOutsideTap: true,
          menuChildren: [
            MenuItemButton(
              onPressed: () => _run(_addVideoLink),
              child: const Text('从 BV 号 / 链接导入'),
            ),
            MenuItemButton(
              onPressed: () => _run(_importFavorites),
              child: const Text('从我的收藏夹导入'),
            ),
          ],
          builder: (context, menu, child) => IconButton(
            tooltip: '添加视频',
            onPressed: _busy
                ? null
                : () => menu.isOpen ? menu.close() : menu.open(),
            icon: const Icon(Icons.add),
          ),
        ),
      ],
    ),
    body: SafeArea(
      top: false,
      bottom: !widget.embedded,
      child: Column(
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (_progress.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _progress,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _cancelImport = true),
                    child: const Text('停止导入'),
                  ),
                ],
              ),
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => AnimatedCrossFade(
                duration: const Duration(milliseconds: 280),
                firstCurve: Curves.easeInOut,
                secondCurve: Curves.easeInOut,
                crossFadeState: _listExpanded
                    ? CrossFadeState.showFirst
                    : CrossFadeState.showSecond,
                firstChild: SizedBox(
                  width: constraints.maxWidth,
                  height: constraints.maxHeight,
                  child: _songList(),
                ),
                secondChild: SizedBox(
                  width: constraints.maxWidth,
                  height: constraints.maxHeight,
                  child: CompactListeningLyrics(controller: controller),
                ),
              ),
            ),
          ),
          _playbackBar(),
        ],
      ),
    ),
  );
}

class _SourceSearch extends StatefulWidget {
  final ListeningController controller;
  final ListeningSong song;
  const _SourceSearch({required this.controller, required this.song});
  @override
  State<_SourceSearch> createState() => _SourceSearchState();
}

class _SourceSearchState extends State<_SourceSearch> {
  late final input = TextEditingController(text: widget.song.name);
  late final sourceKey = widget.song.source.key;
  SongNameConsensus? consensus;
  bool nameApplied = false;
  final List<SearchVideoItemModel> results = [];
  bool busy = false;
  String? error;
  int page = 0;
  String keyword = '';
  @override
  void initState() {
    super.initState();
    unawaited(_search());
  }

  Future<void> _search({bool more = false}) async {
    if (busy || input.text.trim().isEmpty) return;
    setState(() {
      busy = true;
      error = null;
      if (!more) {
        consensus = null;
        nameApplied = false;
      }
    });
    try {
      final query = more ? keyword : input.text.trim();
      final target = more ? page + 1 : 1;
      final items = await widget.controller.search(query, target);
      if (!mounted) return;
      setState(() {
        if (!more) results.clear();
        results.addAll(items);
        page = target;
        keyword = query;
        if (items.isEmpty) error = '没有更多结果，可修改歌曲名称重新搜索';
      });
      final unique = <String, String>{};
      for (final item in results) {
        if (item.bvid?.isNotEmpty == true) unique[item.bvid!] = item.title;
      }
      final inferred = inferSongName(unique.values);
      final applied =
          inferred != null &&
          await widget.controller.applySearchSongName(
            widget.song,
            sourceKey,
            inferred,
          );
      if (!mounted) return;
      setState(() {
        consensus = inferred;
        nameApplied = applied;
      });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('搜索同歌曲视频'),
    content: SizedBox(
      width: 600,
      height: 480,
      child: Column(
        children: [
          TextField(
            controller: input,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              labelText: '歌曲名称',
              suffixIcon: IconButton(
                tooltip: '搜索',
                onPressed: busy ? null : _search,
                icon: const Icon(Icons.search),
              ),
            ),
          ),
          if (busy) const LinearProgressIndicator(),
          if (consensus case final detected?)
            Text(
              '${nameApplied ? "已识别歌名" : "候选歌名（保留手动名称）"}：${detected.name} · ${detected.matches}/${detected.total} 个视频',
            ),
          if (error != null) Text(error!),
          Expanded(
            child: ListView.builder(
              itemCount: results.length,
              itemBuilder: (context, index) {
                final video = results[index];
                return ListTile(
                  title: Text(video.title),
                  subtitle: Text(
                    '${video.owner.name ?? ""} · ${video.bvid ?? ""}',
                  ),
                  onTap: busy ? null : () => Navigator.pop(context, video),
                );
              },
            ),
          ),
          TextButton(
            onPressed: busy || results.isEmpty
                ? null
                : () => _search(more: true),
            child: const Text('加载更多'),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
    ],
  );
}
