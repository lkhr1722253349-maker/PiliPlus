import 'dart:convert';

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/video.dart';
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
  const LyricLine(this.start, this.text, [this.end]);
}

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
  final int duration;
  LyricCandidate(Map json)
    : title = json['trackName'] ?? '',
      artist = json['artistName'] ?? '',
      plain = json['plainLyrics'] ?? '',
      lrc = json['syncedLyrics'] ?? '',
      duration = (json['duration'] as num?)?.round() ?? 0;
}

class LyricsSearch {
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

  void close() => _client.close(force: true);
}

class LyricTrack {
  final String label, language, source;
  final List<LyricLine> lines;
  final String plain;
  final int priority;
  final LyricTrack? original;
  const LyricTrack({
    required this.label,
    required this.source,
    required this.lines,
    this.language = '',
    this.plain = '',
    this.priority = 2,
    this.original,
  });
  Map<String, dynamic> toJson() => {
    'label': label,
    'language': language,
    'source': source,
    'plain': plain,
    'priority': priority,
    'original': original?.toJson(),
    'lines': lines
        .map(
          (e) => {
            'start': e.start.inMilliseconds,
            'end': e.end?.inMilliseconds,
            'text': e.text,
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
    original: json['original'] is Map
        ? LyricTrack.fromJson(json['original'])
        : null,
    lines: (json['lines'] as List)
        .map(
          (e) => LyricLine(
            Duration(milliseconds: e['start']),
            e['text'],
            e['end'] == null ? null : Duration(milliseconds: e['end']),
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

  Future<LyricTrack?> preferred(ListeningSong song) async {
    final original = saved(song);
    if (original?.priority == 0) return original;
    try {
      final matches = (await search.search(song.name))
          .where(
            (e) =>
                e.title.trim().toLowerCase() == song.name.trim().toLowerCase(),
          )
          .toList();
      if (matches.length == 1) {
        final candidate = matches.single;
        final track = LyricTrack(
          label: '歌曲歌词 · ${candidate.artist}',
          source: 'LRCLIB · ${candidate.title}',
          lines: lrcLines(candidate.lrc),
          plain: candidate.plain,
          priority: 0,
        );
        await save(song, track);
        return track;
      }
    } catch (_) {
      /* Saved translations and subtitles remain available offline. */
    }
    final translation = saved(song, translation: true);
    if (translation != null) return translation;
    if (original != null) return original;
    final available = await subtitles(song);
    if (available.isEmpty) return null;
    await save(song, available.first);
    return available.first;
  }

  LyricTrack? saved(ListeningSong song, {bool translation = false}) {
    final json = GStorage.localCache.get(
      'listeningLyrics:${translation ? 'translation:' : ''}${sourceKey(song)}',
    );
    return json is Map ? LyricTrack.fromJson(json) : null;
  }

  Future<void> save(
    ListeningSong song,
    LyricTrack track,
  ) => GStorage.localCache.put(
    'listeningLyrics:${track.priority == 1 ? 'translation:' : ''}${sourceKey(song)}',
    track.toJson(),
  );
  Future<List<LyricTrack>> subtitles(ListeningSong song) async {
    final result = await VideoHttp.playInfo(
      bvid: song.source.bvid,
      cid: song.source.cid,
    );
    if (result case Success(:final response)) {
      final tracks = <LyricTrack>[];
      // Prefer existing Chinese subtitles. Limit downloads, not available choices.
      for (final subtitle in (response.subtitle?.subtitles ?? []).take(4)) {
        final url = subtitle.subtitleUrl;
        if (url == null || url.isEmpty) continue;
        try {
          final response = await Request().get(
            url.startsWith('//') ? 'https:$url' : url,
          );
          final body = response.data['body'];
          if (body is List)
            tracks.add(
              LyricTrack(
                label: '视频字幕 · ${subtitle.lanDoc ?? subtitle.lan}',
                source: url,
                language: subtitle.lan,
                lines: subtitleLines(body),
              ),
            );
        } catch (_) {
          /* One unavailable language does not discard the others. */
        }
      }
      return tracks.where((e) => e.lines.isNotEmpty).toList();
    }
    return [];
  }

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
