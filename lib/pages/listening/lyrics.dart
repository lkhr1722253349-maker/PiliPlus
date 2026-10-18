import 'dart:convert';

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/music.dart';
import 'package:PiliPlus/http/user.dart';
import 'package:PiliPlus/models_new/video/video_tag/data.dart';
import 'package:PiliPlus/pages/listening/models.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:html/parser.dart' show parseFragment;

String? songTagName(List<VideoTagItem> tags, String title) {
  final music = tags.where((e) => e.tagType == 'bgm').toList();
  if (music.length == 1) {
    final name = music.single.tagName?.replaceFirst(RegExp(r'^发现'), '').trim();
    if (name?.isNotEmpty == true) return name;
  }
  const generic = {
    '音乐',
    '歌曲',
    '音乐分享',
    '日语',
    '日语歌曲',
    '翻唱',
    '原创',
    '原创音乐',
    'MV',
    'BGM',
    '纯音乐',
    '动漫',
    '动漫音乐',
    '高音质',
    '无损',
    '歌词',
    '治愈',
    '听歌',
    '音乐推荐',
    'ACG音乐',
    '中文',
    '英文歌曲',
    '日语现场',
  };
  final names = tags
      .map((e) => e.tagName?.trim() ?? '')
      .where((e) => e.length > 1 && !generic.contains(e) && title.contains(e))
      .toSet()
      .toList();
  // Prefer an explicitly quoted song title; ordinary category tags are ambiguous.
  final quoted = names
      .where(
        (e) =>
            title.contains('《$e》') ||
            title.contains('「$e」') ||
            title.contains('“$e”'),
      )
      .toList();
  return quoted.length == 1 ? quoted.single : null;
}

class ListeningMetadata {
  Future<String?> name(SongSource source) async {
    final result = await UserHttp.videoTags(bvid: source.bvid, cid: source.cid);
    if (result case Success(:final response)) {
      final tags = response ?? <VideoTagItem>[];
      final music = tags.where((e) => e.tagType == 'bgm').toList();
      if (music.length == 1 && music.single.musicId != null) {
        try {
          final detail = await MusicHttp.bgmDetail(music.single.musicId!);
          if (detail case Success(:final response)) {
            if (response.musicTitle?.trim().isNotEmpty == true)
              return response.musicTitle!.trim();
          }
        } catch (_) {
          /* Fall back to the song tag. */
        }
      }
      return songTagName(tags, source.title);
    }
    throw StateError('暂时无法读取歌曲标签');
  }
}

class LyricLine {
  final Duration start;
  final Duration? end;
  final String text;
  final String translation;
  const LyricLine(this.start, this.text, [this.end, this.translation = '']);
}

List<LyricLine> bilingualLines(
  List<LyricLine> original,
  List<LyricLine> translated,
) => original.map((line) {
  LyricLine? match;
  var distance = 751;
  for (final candidate in translated) {
    final delta = (candidate.start - line.start).inMilliseconds.abs();
    if (delta < distance &&
        candidate.text != line.text &&
        RegExp(r'[\u3400-\u9fff]').hasMatch(candidate.text)) {
      match = candidate;
      distance = delta;
    }
  }
  return LyricLine(
    line.start,
    line.text,
    line.end,
    line.translation.isNotEmpty ? line.translation : match?.text ?? '',
  );
}).toList();

List<LyricLine> subtitleLines(List body) =>
    body
        .whereType<Map>()
        .where(
          (e) => e['from'] is num && e['to'] is num && e['content'] is String,
        )
        .map(
          (e) => LyricLine(
            Duration(milliseconds: ((e['from'] as num) * 1000).round()),
            e['content'] as String,
            Duration(milliseconds: ((e['to'] as num) * 1000).round()),
          ),
        )
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));

List<LyricLine> lrcLines(String text) {
  final lines = <LyricLine>[];
  final pattern = RegExp(r'\[(\d+):(\d{2})(?:[.:](\d{1,3}))?\]');
  for (final line in text.split('\n')) {
    final matches = pattern.allMatches(line).toList();
    if (matches.isEmpty) continue;
    final content = line.substring(matches.last.end).trim();
    if (content.isEmpty) continue;
    for (final match in matches) {
      final fraction = (match[3] ?? '').padRight(3, '0');
      lines.add(
        LyricLine(
          Duration(
            minutes: int.parse(match[1]!),
            seconds: int.parse(match[2]!),
            milliseconds: int.parse(fraction),
          ),
          content,
        ),
      );
    }
  }
  return lines..sort((a, b) => a.start.compareTo(b.start));
}

int lyricIndex(List<LyricLine> lines, Duration position, Duration offset) {
  final time = position - offset;
  for (var i = lines.length - 1; i >= 0; i--) {
    if (lines[i].start <= time)
      return lines[i].end != null && time >= lines[i].end! ? -1 : i;
  }
  return -1;
}

class LyricCandidate {
  final String title, artist, plain, lrc;
  final String provider;
  final String translatedLrc;
  final int duration;
  LyricCandidate(Map json)
    : title = json['trackName'] ?? '',
      artist = json['artistName'] ?? '',
      plain = json['plainLyrics'] ?? '',
      lrc = json['syncedLyrics'] ?? '',
      provider = json['provider'] ?? 'LRCLIB',
      translatedLrc = json['translatedLyrics'] ?? '',
      duration = (json['duration'] as num?)?.round() ?? 0;
}

class LyricsSearch {
  final Dio _music;
  LyricsSearch({Dio? music})
    : _music =
          music ??
          Dio(
            BaseOptions(
              baseUrl: 'https://music.163.com',
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 10),
              headers: {
                'Referer': 'https://music.163.com/',
                'User-Agent': 'Mozilla/5.0',
              },
            ),
          );
  // A separate client keeps Bilibili cookies and account interceptors off LRCLIB.
  final Dio _client = Dio(
    BaseOptions(
      baseUrl: 'https://lrclib.net',
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 15),
      headers: {
        'User-Agent': 'PiliPlus-custom/1.0 (https://github.com/lkhr1722253349-maker/PiliPlus)',
      },
    ),
  );
  Future<List<LyricCandidate>> search(String name) async {
    try {
      final response = await _music.get(
        '/api/search/get',
        queryParameters: {'s': name, 'type': 1, 'limit': 10},
      );
      final data = response.data is String
          ? jsonDecode(response.data)
          : response.data;
      final songs = (data['result']?['songs'] as List? ?? []).whereType<Map>();
      final found = await Future.wait(
        songs.map((song) async {
          try {
            final response = await _music.get(
              '/api/song/lyric',
              queryParameters: {'id': song['id'], 'lv': -1, 'tv': -1},
            );
            final lyrics = response.data is String
                ? jsonDecode(response.data)
                : response.data;
            final text = lyrics['lrc']?['lyric'] as String? ?? '';
            if (lrcLines(text).isEmpty) return null;
            return LyricCandidate({
              'trackName': song['name'],
              'artistName': (song['artists'] as List? ?? [])
                  .whereType<Map>()
                  .map((e) => e['name'])
                  .join(' / '),
              'duration': ((song['duration'] as num? ?? 0) / 1000).round(),
              'syncedLyrics': text,
              'translatedLyrics': lyrics['tlyric']?['lyric'] ?? '',
              'provider': '网易云音乐',
            });
          } catch (_) {
            return null;
          }
        }),
      );
      final available = found.whereType<LyricCandidate>().toList();
      if (available.isNotEmpty) return available;
    } catch (_) {
      /* Try the independent lyrics database below. */
    }
    final result = await _client.get(
      '/api/search',
      queryParameters: {'q': name},
    );
    return (result.data as List)
        .whereType<Map>()
        .map(LyricCandidate.new)
        .where((e) => e.lrc.isNotEmpty || e.plain.isNotEmpty)
        .take(30)
        .toList();
  }

  void close() {
    _music.close(force: true);
    _client.close(force: true);
  }
}

/// A title alone cannot distinguish unrelated songs with the same name.
/// Sparse or language-incompatible results remain available for manual selection.
bool plausibleSongLyrics(
  ListeningSong song,
  List<LyricLine> lines,
  String plain, {
  Duration duration = Duration.zero,
  int candidateDuration = 0,
}) {
  final text = lines.isNotEmpty ? lines.map((e) => e.text).join('\n') : plain;
  final content = text.split('\n').where((e) => e.trim().isNotEmpty).toList();
  if (content.length < 6 || text.replaceAll(RegExp(r'\s'), '').length < 80)
    return false;
  final title = '${song.name} ${song.source.title}';
  for (final script in [r'[\u3040-\u30ff]', r'[\uac00-\ud7af]']) {
    if (RegExp(script).hasMatch(title) && !RegExp(script).hasMatch(text))
      return false;
  }
  if (lines.isNotEmpty && lines.last.start.inSeconds < 30) return false;
  final seconds = duration.inSeconds;
  if (seconds > 0) {
    if (candidateDuration > 0 &&
        (candidateDuration - seconds).abs() > (seconds * .03).clamp(5, 12))
      return false;
    if (lines.isNotEmpty &&
        (lines.last.start.inSeconds < seconds * .45 ||
            lines.last.start.inSeconds > seconds + 15))
      return false;
  }
  return true;
}

LyricCandidate? selectSongLyrics(
  ListeningSong song,
  List<LyricCandidate> candidates, {
  Duration duration = Duration.zero,
  String? query,
}) {
  final unique = <String, LyricCandidate>{};
  final name = (query ?? song.name).trim().toLowerCase();
  for (final candidate in candidates) {
    final lines = lrcLines(candidate.lrc);
    if (candidate.title.trim().toLowerCase() != name ||
        !plausibleSongLyrics(
          song,
          lines,
          candidate.plain,
          duration: duration,
          candidateDuration: candidate.duration,
        ))
      continue;
    final identity = jsonEncode([
      candidate.title.trim().toLowerCase(),
      candidate.artist.trim().toLowerCase(),
      candidate.duration,
      lines.map((e) => [e.start.inMilliseconds, e.text]).toList(),
      if (lines.isEmpty) candidate.plain.trim(),
    ]);
    final previous = unique[identity];
    if (previous == null ||
        (previous.translatedLrc.isEmpty &&
            candidate.translatedLrc.isNotEmpty)) {
      unique[identity] = candidate;
    }
  }
  if (unique.length == 1) return unique.values.single;
  // Video titles often identify the performer even when no artist tag exists.
  final videoTitle = '${song.source.title} ${song.original.title}'
      .toLowerCase();
  final artists = unique.values
      .where(
        (e) =>
            e.artist.trim().length >= 2 &&
            videoTitle.contains(e.artist.trim().toLowerCase()),
      )
      .toList();
  return artists.length == 1 ? artists.single : null;
}

class LyricTrack {
  List<LyricLine> get displayLines =>
      original == null ? lines : bilingualLines(original!.lines, lines);
  final String label, language, source;
  final List<LyricLine> lines;
  final String plain;
  final int priority;
  final LyricTrack? original;
  final bool confirmed;
  final int matchVersion;
  const LyricTrack({
    required this.label,
    required this.source,
    required this.lines,
    this.language = '',
    this.plain = '',
    this.priority = 2,
    this.original,
    this.confirmed = false,
    this.matchVersion = 0,
  });
  Map<String, dynamic> toJson() => {
    'label': label,
    'language': language,
    'source': source,
    'plain': plain,
    'priority': priority,
    'original': original?.toJson(),
    'confirmed': confirmed,
    'matchVersion': matchVersion,
    'lines': lines
        .map(
          (e) => {
            'start': e.start.inMilliseconds,
            'end': e.end?.inMilliseconds,
            'text': e.text,
            'translation': e.translation,
          },
        )
        .toList(),
  };
  factory LyricTrack.fromJson(Map json) => LyricTrack(
    label: json['label'],
    language: json['language'] ?? '',
    source: json['source'],
    plain: json['plain'] ?? '',
    priority: json['priority'] ?? 2,
    confirmed: json['confirmed'] ?? false,
    matchVersion: json['matchVersion'] ?? 0,
    original: json['original'] is Map
        ? LyricTrack.fromJson(json['original'])
        : null,
    lines: (json['lines'] as List)
        .map(
          (e) => LyricLine(
            Duration(milliseconds: e['start']),
            e['text'],
            e['end'] == null ? null : Duration(milliseconds: e['end']),
            e['translation'] ?? '',
          ),
        )
        .toList(),
  );
}

class ListeningLyrics {
  final LyricsSearch search = LyricsSearch();
  final Dio _translation;
  ListeningLyrics({Dio? translation})
    : _translation =
          translation ??
          Dio(
            BaseOptions(
              baseUrl: 'https://api.mymemory.translated.net',
              connectTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 20),
            ),
          );
  static String key(String text) =>
      sha256.convert(utf8.encode(text)).toString();
  static String sourceKey(ListeningSong song) =>
      key('${song.source.key}:${song.name}');
  static String? nameLanguage(String name) {
    if (RegExp(r'[\u3040-\u30ff]').hasMatch(name)) return 'ja';
    if (RegExp(r'[\uac00-\ud7af]').hasMatch(name)) return 'ko';
    if (!RegExp(r'[\u3400-\u9fff]').hasMatch(name) &&
        RegExp('[a-zA-Z]').hasMatch(name))
      return 'en';
    return null;
  }

  Future<LyricTrack?> preferred(
    ListeningSong song, {
    Duration duration = Duration.zero,
    Duration Function()? currentDuration,
  }) async {
    final original = saved(song);
    if (original?.priority == 0 && original!.confirmed) return original;
    try {
      final candidates = await search.search(song.name);
      final candidate = selectSongLyrics(
        song,
        candidates,
        duration: currentDuration?.call() ?? duration,
      );
      if (candidate != null) {
        final track = LyricTrack(
          label: '歌曲歌词 · ${candidate.artist}',
          source: '${candidate.provider} · ${candidate.title}',
          lines: bilingualLines(
            lrcLines(candidate.lrc),
            lrcLines(candidate.translatedLrc),
          ),
          plain: candidate.plain,
          priority: 0,
          matchVersion: 1,
        );
        await save(song, track);
        return saved(song) ?? track;
      }
    } catch (_) {
      /* Saved song lyrics and translations remain available offline. */
    }
    final translation = saved(song, translation: true);
    if (translation != null) return translation;
    if (original != null) return original;
    return null;
  }

  LyricTrack? saved(ListeningSong song, {bool translation = false}) {
    final json = GStorage.localCache.get(
      'listeningLyrics:${translation ? 'translation:' : ''}${sourceKey(song)}',
    );
    if (json is! Map) return null;
    final track = LyricTrack.fromJson(json);
    if (track.priority == 2 || track.original?.priority == 2) return null;
    if (track.priority == 0 && !track.confirmed && track.matchVersion < 1)
      return null;
    if (track.priority == 0 &&
        !track.confirmed &&
        !plausibleSongLyrics(song, track.lines, track.plain))
      return null;
    // A translation of a rejected match must not bring the wrong song back.
    final base = track.original;
    if (base?.priority == 0 && !base!.confirmed && base.matchVersion < 1)
      return null;
    if (base?.priority == 0 &&
        !base!.confirmed &&
        !plausibleSongLyrics(song, base.lines, base.plain))
      return null;
    if (track.priority == 0 &&
        track.lines.every((e) => e.translation.isEmpty)) {
      final translated = saved(song, translation: true);
      if (translated?.original?.source == track.source) {
        return LyricTrack(
          label: track.label,
          source: track.source,
          lines: bilingualLines(track.lines, translated!.lines),
          language: track.language,
          plain: track.plain,
          priority: track.priority,
          confirmed: track.confirmed,
          matchVersion: track.matchVersion,
        );
      }
    }
    return track;
  }

  Future<void> save(
    ListeningSong song,
    LyricTrack track,
  ) => GStorage.localCache.put(
    'listeningLyrics:${track.priority == 1 ? 'translation:' : ''}${sourceKey(song)}',
    track.toJson(),
  );
  static List<String> chunks(String text) {
    final parts = <String>[];
    var current = StringBuffer();
    var bytes = 0;
    for (final rune in text.runes) {
      final char = String.fromCharCode(rune);
      final size = utf8.encode(char).length;
      if (bytes + size > 450) {
        parts.add(current.toString());
        current = StringBuffer();
        bytes = 0;
      }
      current.write(char);
      bytes += size;
    }
    if (current.isNotEmpty) parts.add(current.toString());
    return parts;
  }

  Future<String> translateLine(String text, String language) async {
    final cacheKey =
        'listeningTranslation:${key('mymemory:$language:zh-CN:$text')}';
    final cached = GStorage.localCache.get(cacheKey);
    if (cached is String && cached.isNotEmpty) return cached;
    final segments = chunks(text);
    if (segments.length > 1) {
      final values = <String>[];
      for (final segment in segments) {
        values.add(await translateLine(segment, language));
      }
      final joined = values.join();
      await GStorage.localCache.put(cacheKey, joined);
      return joined;
    }
    final translated = <String>[];
    for (final part in chunks(text)) {
      final res = await _translation.get(
        '/get',
        queryParameters: {'q': part, 'langpair': '$language|zh-CN', 'mt': 1},
      );
      final data = res.data;
      if ('${data['responseStatus']}' != '200' || data['quotaFinished'] == true)
        throw StateError('免费翻译额度不足或服务暂不可用，已完成的译文已保存');
      final value = data['responseData']?['translatedText'];
      if (value is! String || value.trim().isEmpty)
        throw StateError('翻译服务未返回译文');
      translated.add(parseFragment(value).text ?? value);
    }
    final result = translated.join();
    await GStorage.localCache.put(cacheKey, result);
    return result;
  }

  void close() {
    search.close();
    _translation.close(force: true);
  }
}
