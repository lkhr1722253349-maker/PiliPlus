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
  Future<List<String>> lyricSearchTags(SongSource source) async {
    final result = await UserHttp.videoTags(bvid: source.bvid, cid: source.cid);
    if (result case Success(:final response)) {
      final tags = response ?? <VideoTagItem>[];
      final values = <String>{};
      for (final tag in tags) {
        final name = tag.tagName?.replaceFirst(RegExp(r'^发现'), '').trim();
        if (name == null || name.length < 2) continue;
        if (tag.tagType == 'bgm') values.add(name);
        if (tag.musicId != null) {
          try {
            final detail = await MusicHttp.bgmDetail(tag.musicId!);
            if (detail case Success(:final response)) {
              if (response.musicTitle?.trim().isNotEmpty == true) {
                values.add(response.musicTitle!.trim());
              }
            }
          } catch (_) {}
        }
      }
      return values.take(3).toList();
    }
    return [];
  }

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
  Future<List<LyricCandidate>> search(
    String name, {
    Iterable<String> hints = const [],
  }) async {
    final candidates = <LyricCandidate>[];
    final seen = <String>{};
    for (final term in [
      name,
      ...hints,
    ].where((e) => e.trim().isNotEmpty).take(4)) {
      candidates.addAll(
        await _searchMusic(term).then(
          (items) => items
              .where(
                (e) => seen.add(
                  '${e.title.toLowerCase()}|${e.artist.toLowerCase()}|${e.duration}|${e.lrc.hashCode}',
                ),
              )
              .toList(),
        ),
      );
    }
    if (candidates.isNotEmpty) return candidates;
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

  Future<List<LyricCandidate>> _searchMusic(String name) async {
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
      /* Search the next query hint. */
    }
    return [];
  }

  void close() {
    _music.close(force: true);
    _client.close(force: true);
  }
}

class EncyclopediaLyricsSearch {
  final Dio client;
  EncyclopediaLyricsSearch({Dio? client})
    : client =
          client ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 6),
              receiveTimeout: const Duration(seconds: 8),
              headers: {
                'User-Agent': 'PiliPlus-custom/1.0 (https://github.com/lkhr1722253349-maker/PiliPlus)',
              },
            ),
          );

  Future<List<String>> hints(String song, Iterable<String> tags) async {
    final tagList = tags.take(2).toList();
    final query = tagList.isEmpty ? song : '$song ${tagList.join(' ')}';
    final output = <String>{};
    await Future.wait<void>(
      [
        ...['ja', 'zh', 'en'].map((language) async {
          try {
            final result = await client.get(
              'https://$language.wikipedia.org/w/api.php',
              queryParameters: {
                'action': 'query',
                'list': 'search',
                'srsearch': query,
                'srlimit': 3,
                'format': 'json',
              },
            );
            final pages = result.data['query']?['search'] as List? ?? [];
            for (final page in pages.whereType<Map>()) {
              final title = (page['title'] as String? ?? '').trim();
              if (title.isNotEmpty && title.toLowerCase() != song.toLowerCase())
                output.add(title);
            }
          } catch (_) {}
        }),
        (() async {
          try {
            final result = await client.get(
              'https://www.wikidata.org/w/api.php',
              queryParameters: {
                'action': 'wbsearchentities',
                'search': query,
                'language': 'ja',
                'uselang': 'ja',
                'format': 'json',
                'limit': 4,
              },
            );
            for (final entity
                in (result.data['search'] as List? ?? []).whereType<Map>()) {
              final label = (entity['label'] as String? ?? '').trim();
              final description = (entity['description'] as String? ?? '')
                  .trim();
              if (label.isNotEmpty && label.toLowerCase() != song.toLowerCase())
                output.add(label);
              if (description.length > 3 && description.length < 80)
                output.add(description);
            }
          } catch (_) {}
        })(),
      ],
    );
    return output.take(3).toList();
  }

  void close() => client.close(force: true);
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
  if (duration.inSeconds > 0) {
    final matchingDuration = unique.values
        .where(
          (candidate) =>
              candidate.duration > 0 &&
              (candidate.duration - duration.inSeconds).abs() <= 2,
        )
        .toList();
    if (matchingDuration.isNotEmpty) {
      unique
        ..clear()
        ..addEntries(
          matchingDuration.map(
            (candidate) => MapEntry(
              jsonEncode([
                candidate.title.trim().toLowerCase(),
                candidate.artist.trim().toLowerCase(),
                candidate.duration,
                lrcLines(candidate.lrc)
                    .map((e) => [e.start.inMilliseconds, e.text])
                    .toList(),
                if (lrcLines(candidate.lrc).isEmpty) candidate.plain.trim(),
              ]),
              candidate,
            ),
          ),
        );
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

/// Translation failures keep the completed work and are split into a
/// per-request failure and a service-wide quota failure, so one bad request
/// cannot stop the whole queue.
class LyricsTranslationException extends StateError {
  final bool quota;
  LyricsTranslationException(super.message, {this.quota = false});
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
  /// Traditional-only characters that have no simplified form in common use.
  /// A name written with these is Chinese, not Japanese kanji, so it must not
  /// be sent for translation: the target language is already Chinese.
  static const _traditionalOnly =
      '們個來時說會為對這過還開關點電發現實學體國東車長門間問無與萬樣種'
      '麼兒將應該當經給還邊變讓認識語讀寫聽講話誰歡樂聲愛氣義處務員'
      '標準備結束繼續練習習慣感覺憶願擁抱護選擇單雙號碼稱讚賞顏'
      '麗雲飛風飄點燈熱鬧靜歲豐農曆藝術戲劇團隊營營養師';

  /// Simplified-only characters: their presence means the text is already in
  /// the target script, so no translation is needed either.
  static const _simplifiedOnly =
      '们个来时说会为对这过还开关点电发现实学体国东车长门间问无与万样种'
      '么儿将应该当经给边变让认识语读写听讲话谁欢乐声爱气义处务员'
      '标准备结束继续练习习惯感觉忆愿拥抱护选择单双号码称赞赏颜'
      '丽云飞风飘点灯热闹静岁丰农历艺术戏剧团队营营养师';

  /// True when the text is Chinese (simplified or traditional) and therefore
  /// needs no Chinese translation.
  static bool isChinese(String text) {
    if (!RegExp(r'[\u3400-\u9fff]').hasMatch(text)) return false;
    if (RegExp(r'[\u3040-\u30ff\uac00-\ud7af]').hasMatch(text)) return false;
    if (_traditionalOnly.split('').any(text.contains)) return true;
    if (_simplifiedOnly.split('').any(text.contains)) return true;
    // Han-only text without kana/hangul is treated as Chinese unless the
    // caller supplies Japanese context (see [nameLanguage]).
    return true;
  }

  static String? nameLanguage(String name, {String context = ''}) {
    if (RegExp(r'[\u3040-\u30ff]').hasMatch(name)) return 'ja';
    if (RegExp(r'[\uac00-\ud7af]').hasMatch(name)) return 'ko';
    // Kanji-only Japanese titles need language context from the source video,
    // but a name that is clearly Chinese (traditional or simplified) must not
    // be translated just because the video has Japanese tags.
    if (RegExp(r'[\u3400-\u9fff]').hasMatch(name)) {
      if (_traditionalOnly.split('').any(name.contains)) return null;
      if (_simplifiedOnly.split('').any(name.contains)) return null;
      if (RegExp(r'[\u3040-\u30ff]').hasMatch(context)) return 'ja';
      return null;
    }
    if (RegExp('[a-zA-Z]').hasMatch(name)) return 'en';
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
      var candidates = await search.search(song.name);
      var candidate = selectSongLyrics(
        song,
        candidates,
        duration: currentDuration?.call() ?? duration,
      );
      if (candidate == null) {
        final tags = await ListeningMetadata().lyricSearchTags(song.original);
        final encyclopedia = EncyclopediaLyricsSearch();
        try {
          final articleHints = await encyclopedia.hints(song.name, tags);
          candidates = await search.search(
            song.name,
            hints: [...tags, ...articleHints],
          );
          candidate = selectSongLyrics(
            song,
            candidates,
            duration: currentDuration?.call() ?? duration,
          );
        } finally {
          encyclopedia.close();
        }
      }
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
    final source = language.trim();
    // MyMemory requires two distinct, concrete languages; it rejects
    // "autodetect" with HTTP 403, which must never be reported as quota.
    if (!RegExp(r'^[a-z]{2,3}(?:-[A-Za-z]{2,4})?$').hasMatch(source) ||
        source == 'autodetect')
      throw LyricsTranslationException('无法判断原文语言，已跳过翻译');
    final cacheKey =
        'listeningTranslation:${key('mymemory:$source:zh-CN:$text')}';
    final cached = GStorage.localCache.get(cacheKey);
    if (cached is String && cached.isNotEmpty) return cached;
    final segments = chunks(text);
    if (segments.length > 1) {
      final values = <String>[];
      for (final segment in segments) {
        values.add(await translateLine(segment, source));
      }
      final joined = values.join();
      await GStorage.localCache.put(cacheKey, joined);
      return joined;
    }
    final translated = <String>[];
    for (final part in chunks(text)) {
      final res = await _translation.get(
        '/get',
        queryParameters: {'q': part, 'langpair': '$source|zh-CN', 'mt': 1},
      );
      final data = res.data;
      // Only a real quota/rate-limit answer stops the whole queue; any other
      // bad answer stays a per-name failure.
      if (data['quotaFinished'] == true ||
          '${data['responseStatus']}' == '429')
        throw LyricsTranslationException(
          '免费翻译额度不足或服务暂不可用，已完成的译文已保存',
          quota: true,
        );
      if ('${data['responseStatus']}' != '200')
        throw LyricsTranslationException('翻译服务暂不可用，已完成的译文已保存');
      final value = data['responseData']?['translatedText'];
      if (value is! String || value.trim().isEmpty)
        throw LyricsTranslationException('翻译服务未返回译文');
      translated.add(parseFragment(value).text ?? value);
    }
    final result = translated.join();
    await GStorage.localCache.put(cacheKey, result);
    return result;
  }

  /// Translates a song name once, only when the source language is known.
  /// Returns `null` when the name needs no (or cannot get a) Chinese name.
  Future<String?> translateName(String name, {String context = ''}) async {
    final language = nameLanguage(name, context: context);
    if (language == null) return null;
    final translated = (await translateLine(name, language)).trim();
    if (translated.isEmpty || translated == name.trim()) return null;
    if (!RegExp(r'[\u3400-\u9fff]').hasMatch(translated)) return null;
    return translated;
  }

  void close() {
    search.close();
    _translation.close(force: true);
  }
}
