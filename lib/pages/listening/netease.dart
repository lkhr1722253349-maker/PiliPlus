import 'dart:convert';
import 'dart:math';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/models/search/result.dart';
import 'package:dio/dio.dart';

/// A reference to a NetEase Cloud Music song or playlist.
class NeteaseLink {
  const NeteaseLink(this.id, {this.playlist = false});

  final int id;
  final bool playlist;
}

class NeteaseSong {
  const NeteaseSong({
    required this.id,
    required this.name,
    required this.artists,
    required this.album,
    required this.durationMs,
    this.cover = '',
  });

  final int id;
  final String name;
  final String artists;
  final String album;
  final int durationMs;
  final String cover;

  String get displayName => artists.isEmpty ? name : '$name - $artists';
}

class NeteaseCollection {
  const NeteaseCollection({
    required this.title,
    required this.songs,
  });

  final String title;
  final List<NeteaseSong> songs;
}

/// Parses a NetEase song/playlist link or a bare numeric song id.
///
/// Accepts the common web, mobile and hash-route forms:
/// `music.163.com/song?id=1`, `music.163.com/#/playlist?id=2`,
/// `y.music.163.com/m/song?id=1` and a bare `1`.
NeteaseLink? parseNeteaseLink(String input) {
  final raw = input.trim();
  if (RegExp(r'^\d+$').hasMatch(raw)) {
    final id = int.tryParse(raw);
    return id != null && id > 0 ? NeteaseLink(id) : null;
  }
  final match = RegExp(
    r'https?://[^\s<>"，。]+',
    caseSensitive: false,
  ).firstMatch(raw);
  if (match == null) return null;
  final uri = Uri.tryParse(match.group(0)!);
  if (uri == null || !isNeteaseHost(uri.host)) return null;

  var effective = uri;
  // `https://music.163.com/#/song?id=1` keeps the route in the fragment.
  if (uri.fragment.contains('?')) {
    final fragment = uri.fragment.replaceFirst(RegExp(r'^/+'), '');
    effective = Uri.tryParse('https://music.163.com/$fragment') ?? uri;
  }
  final path = effective.path.toLowerCase();
  final playlist =
      path.contains('playlist') || uri.path.toLowerCase().contains('playlist');
  final idText =
      effective.queryParameters['id'] ??
      effective.queryParameters['playlistId'] ??
      effective.queryParameters['songId'];
  final id = int.tryParse(idText ?? '');
  return id != null && id > 0 ? NeteaseLink(id, playlist: playlist) : null;
}

bool isNeteaseHost(String host) {
  final value = host.toLowerCase();
  return value == 'music.163.com' || value.endsWith('.music.163.com');
}

bool isNeteaseShortHost(String host) {
  final value = host.toLowerCase();
  return value == '163cn.tv' || value.endsWith('.163cn.tv');
}

Uri? firstLinkUri(String input) {
  final match = RegExp(
    r'https?://[^\s<>"，。]+',
    caseSensitive: false,
  ).firstMatch(input);
  return match == null ? null : Uri.tryParse(match.group(0)!);
}

/// Normalizes a title for loose matching across Bilibili upload styles.
String normalizeNeteaseText(String value) {
  var text = value.toLowerCase();
  // Drop bracketed suffixes such as (Live), 【MV】, [4K].
  text = text.replaceAll(RegExp(r'[\(（\[【][^\)）\]】]*[\)）\]】]'), '');
  text = text.replaceAll(RegExp(r'[^a-z0-9\u3040-\u30ff\u4e00-\u9fff]'), '');
  return text;
}

/// Picks the best Bilibili search result for a NetEase song.
///
/// Candidates must be close in duration, then a title/artist match is
/// required. Among matches, closer duration wins, then play count, then the
/// requested "百万豪装录音" style title preference.
SearchVideoItemModel? bestNeteaseCandidate(
  NeteaseSong song,
  List<SearchVideoItemModel> candidates,
) {
  final target = song.durationMs / 1000;
  if (target <= 0) return null;
  final songName = normalizeNeteaseText(song.name);
  final artist = normalizeNeteaseText(song.artists);
  final tolerance = max(12.0, target * 0.05);

  final within = candidates.where((item) {
    final bvid = item.bvid;
    if (bvid == null || bvid.isEmpty || item.duration <= 0) return false;
    return (item.duration - target).abs() <= tolerance;
  }).toList();
  if (within.isEmpty) return null;

  bool matches(SearchVideoItemModel item) {
    final title = normalizeNeteaseText(item.title);
    if (title.isEmpty) return false;
    if (songName.isNotEmpty && title.contains(songName)) return true;
    return artist.isNotEmpty && title.contains(artist);
  }

  var pool = within.where(matches).toList();
  if (pool.isEmpty) return null;

  int bucket(SearchVideoItemModel item) {
    final diff = (item.duration - target).abs();
    if (diff <= 3) return 0;
    if (diff <= 8) return 1;
    if (diff <= 15) return 2;
    return 3;
  }

  bool preferredTitle(SearchVideoItemModel item) =>
      item.title.contains('百万豪装录音');

  pool.sort((a, b) {
    final byBucket = bucket(a).compareTo(bucket(b));
    if (byBucket != 0) return byBucket;
    final byPlay = (b.stat.view ?? 0).compareTo(a.stat.view ?? 0);
    if (byPlay != 0) return byPlay;
    return preferredTitle(b) == preferredTitle(a)
        ? 0
        : preferredTitle(b)
        ? 1
        : -1;
  });
  return pool.first;
}

/// Fetches NetEase metadata without requiring a login.
abstract final class NeteaseClient {
  static final Dio _dio = Dio(
    BaseOptions(
      baseUrl: 'https://music.163.com',
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
      headers: const {
        'user-agent': BrowserUa.pc,
        'referer': 'https://music.163.com/',
        'accept': 'application/json, text/plain, */*',
      },
    ),
  );

  /// Resolves a short link such as `https://163cn.tv/xxxx` and parses it.
  static Future<NeteaseLink> resolve(String input) async {
    final uri = firstLinkUri(input);
    if (uri != null && isNeteaseShortHost(uri.host)) {
      final target = await _resolveShort(uri);
      final parsed = parseNeteaseLink(target.toString());
      if (parsed != null) return parsed;
    }
    final parsed = parseNeteaseLink(input);
    if (parsed == null) {
      throw const FormatException('请输入网易云歌曲或歌单链接，支持 163cn.tv 短链');
    }
    return parsed;
  }

  /// Loads one song, or a playlist and all of its tracks.
  static Future<NeteaseCollection> load(String input) async {
    final link = await resolve(input);
    if (link.playlist) return _loadPlaylist(link.id);
    try {
      final track = await song(link.id);
      return NeteaseCollection(title: track.name, songs: [track]);
    } on Object {
      // A bare numeric id may also be a playlist id.
      return _loadPlaylist(link.id);
    }
  }

  static Future<NeteaseSong> song(int id) async {
    final result = await songs([id]);
    if (result.isEmpty) throw StateError('网易云没有返回这首歌，可能已下架');
    return result.first;
  }

  static Future<List<NeteaseSong>> songs(List<int> ids) async {
    final unique = <int>[];
    final seen = <int>{};
    for (final id in ids) {
      if (id > 0 && seen.add(id)) unique.add(id);
    }
    final byId = <int, NeteaseSong>{};
    for (var start = 0; start < unique.length; start += 100) {
      final batch = unique.sublist(start, min(start + 100, unique.length));
      final response = await _dio.get<dynamic>(
        '/api/song/detail/',
        queryParameters: {
          'id': batch.first,
          'ids': jsonEncode(batch),
        },
      );
      final data = response.data;
      final list = data is Map ? data['songs'] : null;
      if (list is! List) continue;
      for (final item in list) {
        if (item is! Map) continue;
        final song = _parseSong(item);
        if (song != null) byId[song.id] = song;
      }
    }
    return [
      for (final id in unique)
        if (byId[id] != null) byId[id]!,
    ];
  }

  static Future<NeteaseCollection> _loadPlaylist(int id) async {
    final response = await _dio.get<dynamic>(
      '/api/v6/playlist/detail',
      queryParameters: {'id': id, 'n': 1000},
    );
    final data = response.data;
    final playlist = data is Map ? data['playlist'] : null;
    if (playlist is! Map) throw StateError('网易云没有返回这个歌单');
    final title = playlist['name'] as String? ?? '网易云歌单';
    final ids = <int>[];
    for (final item in playlist['trackIds'] as List? ?? const []) {
      final value = item is Map ? item['id'] : item;
      if (value is num && value > 0) ids.add(value.toInt());
    }
    if (ids.isEmpty) {
      for (final item in playlist['tracks'] as List? ?? const []) {
        final value = item is Map ? item['id'] : null;
        if (value is num && value > 0) ids.add(value.toInt());
      }
    }
    final songs = await NeteaseClient.songs(ids);
    if (songs.isEmpty) throw StateError('歌单没有可读取的歌曲');
    return NeteaseCollection(title: title, songs: songs);
  }

  static Future<Uri> _resolveShort(Uri uri) async {
    var current = uri;
    for (var i = 0; i < 3; i++) {
      final response = await _dio.getUri<dynamic>(
        current,
        options: Options(
          followRedirects: false,
          validateStatus: (status) => status != null && status < 400,
        ),
      );
      final location = response.headers.value('location');
      if (location == null || location.isEmpty) {
        throw StateError('短链接没有跳转到网易云页面，请复制完整链接');
      }
      current = current.resolve(location);
      if (isNeteaseHost(current.host)) return current;
    }
    throw StateError('短链接跳转次数过多，请复制完整链接');
  }

  static NeteaseSong? _parseSong(Map json) {
    final id = json['id'];
    final name = json['name'];
    if (id is! num || name is! String || name.isEmpty) return null;
    final rawArtists = json['artists'] ?? json['ar'];
    final artists = <String>[];
    if (rawArtists is List) {
      for (final artist in rawArtists) {
        final value = artist is Map ? artist['name'] : null;
        if (value is String && value.isNotEmpty) artists.add(value);
      }
    }
    final rawAlbum = json['album'] ?? json['al'];
    final album = rawAlbum is Map ? rawAlbum['name'] as String? ?? '' : '';
    final cover = rawAlbum is Map ? (rawAlbum['picUrl'] as String? ?? '') : '';
    final duration = json['duration'] ?? json['dt'];
    return NeteaseSong(
      id: id.toInt(),
      name: name,
      artists: artists.join(' / '),
      album: album,
      durationMs: duration is num ? duration.toInt() : 0,
      cover: cover,
    );
  }
}
