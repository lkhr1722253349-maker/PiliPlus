import 'dart:async';

import 'package:PiliPlus/pages/listening/controller.dart';
import 'package:PiliPlus/pages/listening/lyrics.dart';
import 'package:PiliPlus/pages/listening/models.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class ListeningLyricsView extends StatefulWidget {
  final ListeningSong song;
  final ListeningController controller;
  final ListeningLyrics? service;
  const ListeningLyricsView({
    super.key,
    required this.song,
    required this.controller,
    this.service,
  });
  @override
  State<ListeningLyricsView> createState() => _ListeningLyricsViewState();
}

class _ListeningLyricsViewState extends State<ListeningLyricsView> {
  late final service = widget.service ?? ListeningLyrics();
  final scroll = ScrollController();
  final tracks = <LyricTrack>[];
  LyricTrack? selected;
  late final TextEditingController query = TextEditingController(
    text: widget.song.name,
  );
  late final Worker positionWorker;
  bool busy = true, translating = false;
  String? message;
  String language = 'ja';
  Duration offset = Duration.zero;
  int active = -1;
  int generation = 0;
  bool get isCurrent => identical(widget.controller.current.value, widget.song);

  @override
  void initState() {
    super.initState();
    offset = Duration(
      milliseconds: GStorage.localCache.get(
        'listeningLyricsOffset:${widget.song.source.key}',
        defaultValue: 0,
      ),
    );
    for (final track in [
      service.saved(widget.song),
      service.saved(widget.song, translation: true),
    ]) {
      if (track != null) tracks.add(track);
    }
    _choosePreferred();
    positionWorker = ever(widget.controller.position, (_) => _follow());
    unawaited(_load());
  }

  void _choosePreferred() {
    tracks.sort((a, b) => a.priority.compareTo(b.priority));
    selected = tracks.firstOrNull;
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        service.subtitles(widget.song).catchError((_) => <LyricTrack>[]),
        _search(automatic: true),
      ]);
      if (!mounted) return;
      tracks.addAll(results.first);
      setState(() {
        _choosePreferred();
        busy = false;
      });
      _follow();
    } catch (e) {
      if (mounted)
        setState(() {
          busy = false;
          message = '读取失败，可重试：$e';
        });
    }
  }

  Future<List<LyricTrack>> _search({bool automatic = false}) async {
    try {
      final candidates = await service.search.search(query.text.trim());
      if (!mounted) return [];
      LyricCandidate? chosen;
      if (automatic) {
        final exact = candidates
            .where(
              (e) =>
                  e.title.toLowerCase().trim() ==
                  query.text.toLowerCase().trim(),
            )
            .toList();
        if (exact.length == 1) chosen = exact.single;
      } else {
        chosen = await showDialog<LyricCandidate>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('选择歌词版本'),
            content: SizedBox(
              width: 500,
              height: 360,
              child: candidates.isEmpty
                  ? const Center(child: Text('未找到歌词，请修改歌曲名重试'))
                  : ListView(
                      children: candidates
                          .map(
                            (e) => ListTile(
                              title: Text(e.title),
                              subtitle: Text(
                                '${e.artist} · ${e.duration} 秒 · ${e.lrc.isEmpty ? '无时间轴' : '同步歌词'}',
                              ),
                              onTap: () => Navigator.pop(context, e),
                            ),
                          )
                          .toList(),
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
            ],
          ),
        );
      }
      if (chosen != null && mounted) {
        final track = LyricTrack(
          label: '歌曲歌词 · ${chosen.artist}',
          source: 'LRCLIB · ${chosen.title}',
          lines: lrcLines(chosen.lrc),
          plain: chosen.plain,
          priority: 0,
        );
        await service.save(widget.song, track);
        if (!mounted) return [];
        setState(() {
          tracks.removeWhere((e) => e.priority == 0);
          tracks.add(track);
          selected = track;
          active = -1;
        });
        _follow();
      }
    } catch (e) {
      if (mounted) setState(() => message = '歌词搜索暂不可用，可使用已保存歌词或视频字幕');
    }
    return [];
  }

  void _follow() {
    final track = selected;
    if (!mounted || track == null || !isCurrent) return;
    final index = lyricIndex(
      track.lines,
      widget.controller.position.value,
      offset,
    );
    if (index == active) return;
    setState(() => active = index);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !scroll.hasClients || index < 0) return;
      scroll.animateTo(
        (index * 80.0 - scroll.position.viewportDimension / 2 + 40).clamp(
          0,
          scroll.position.maxScrollExtent,
        ),
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _translate() async {
    final base = selected?.original ?? selected;
    if (base == null) return;
    final request = ++generation;
    final sourceLines = base.lines.isEmpty
        ? base.plain
              .split('\n')
              .where((e) => e.trim().isNotEmpty)
              .map((e) => LyricLine(Duration.zero, e))
              .toList()
        : base.lines;
    if (sourceLines.isEmpty) return;
    setState(() {
      translating = true;
      message = '使用 MyMemory 免费翻译，译文逐行保存；额度耗尽可稍后继续';
    });
    final result = <LyricLine>[];
    try {
      for (var i = 0; i < sourceLines.length; i++) {
        if (!mounted || request != generation) return;
        final line = sourceLines[i];
        final text = await service.translateLine(line.text, language);
        if (!mounted || request != generation) return;
        result.add(LyricLine(line.start, text, line.end));
        final translated = LyricTrack(
          label: '自动翻译 ${i + 1}/${sourceLines.length} · MyMemory',
          source: base.source,
          language: 'zh-CN',
          lines: base.lines.isEmpty
              ? []
              : [...result, ...sourceLines.skip(i + 1)],
          plain: base.lines.isEmpty
              ? [
                  ...result,
                  ...sourceLines.skip(i + 1),
                ].map((e) => e.text).join('\n')
              : '',
          priority: 1,
          original: base,
        );
        await service.save(widget.song, translated);
        if (!mounted) return;
        setState(() {
          tracks.removeWhere((e) => e.priority == 1);
          tracks.add(translated);
          selected = translated;
        });
      }
      if (mounted) setState(() => message = '译文已自动保存在本机');
    } catch (e) {
      if (mounted) setState(() => message = '$e');
    } finally {
      if (mounted && request == generation) setState(() => translating = false);
    }
  }

  @override
  void dispose() {
    generation++;
    positionWorker.dispose();
    scroll.dispose();
    query.dispose();
    service.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.song.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ),
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: query,
                    decoration: const InputDecoration(
                      labelText: '歌曲名称',
                      isDense: true,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '搜索歌词',
                  onPressed: busy || translating
                      ? null
                      : () async {
                          setState(() => busy = true);
                          await _search();
                          if (mounted) setState(() => busy = false);
                        },
                  icon: const Icon(Icons.search),
                ),
              ],
            ),
          ),
          if (busy || translating) const LinearProgressIndicator(),
          if (tracks.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: DropdownButton<LyricTrack>(
                isExpanded: true,
                value: selected,
                items: tracks
                    .map(
                      (e) => DropdownMenuItem(
                        value: e,
                        child: Text(e.label, overflow: TextOverflow.ellipsis),
                      ),
                    )
                    .toList(),
                onChanged: translating
                    ? null
                    : (value) {
                        setState(() {
                          selected = value;
                          active = -1;
                        });
                        _follow();
                      },
              ),
            ),
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DropdownButton<String>(
                value: language,
                items: const [
                  DropdownMenuItem(value: 'ja', child: Text('日语 → 中文')),
                  DropdownMenuItem(value: 'en', child: Text('英语 → 中文')),
                  DropdownMenuItem(value: 'ko', child: Text('韩语 → 中文')),
                ],
                onChanged: translating
                    ? null
                    : (value) => setState(() => language = value!),
              ),
              TextButton.icon(
                onPressed: selected == null || busy || translating
                    ? null
                    : _translate,
                icon: const Icon(Icons.translate),
                label: const Text('自动翻译并保存'),
              ),
            ],
          ),
          if (message != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                message!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (!isCurrent) const Text('这首歌未在播放，时间轴暂停跟随'),
          Expanded(
            child: selected == null
                ? Center(
                    child: Text(busy ? '正在查找歌词和字幕…' : '暂无匹配歌词或可用字幕，可修改歌名搜索'),
                  )
                : selected!.lines.isEmpty
                ? SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: SelectableText(selected!.plain),
                  )
                : ListView.builder(
                    controller: scroll,
                    itemExtent: 80,
                    itemCount: selected!.lines.length,
                    itemBuilder: (context, index) {
                      final line = selected!.lines[index];
                      return ListTile(
                        selected: index == active,
                        title: Text(
                          line.text,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                        ),
                        onTap: !isCurrent
                            ? null
                            : () => widget.controller.seek(
                                line.start + offset < Duration.zero
                                    ? Duration.zero
                                    : line.start + offset,
                              ),
                      );
                    },
                  ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                tooltip: '歌词提前 0.5 秒',
                onPressed: () => _adjust(-500),
                icon: const Icon(Icons.remove),
              ),
              Text(
                '歌词偏移 ${(offset.inMilliseconds / 1000).toStringAsFixed(1)} 秒',
              ),
              IconButton(
                tooltip: '歌词延后 0.5 秒',
                onPressed: () => _adjust(500),
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        ],
      ),
    ),
  );
  void _adjust(int milliseconds) {
    setState(() {
      offset += Duration(milliseconds: milliseconds);
      active = -1;
    });
    unawaited(
      GStorage.localCache.put(
        'listeningLyricsOffset:${widget.song.source.key}',
        offset.inMilliseconds,
      ),
    );
    _follow();
  }
}
