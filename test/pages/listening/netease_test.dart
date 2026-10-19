import 'package:PiliPlus/models/search/result.dart';
import 'package:PiliPlus/pages/listening/netease.dart';
import 'package:flutter_test/flutter_test.dart';

SearchVideoItemModel _candidate({
  required String title,
  required String duration,
  required int play,
  String bvid = 'BV1xx411c7mD',
}) {
  return SearchVideoItemModel.fromJson({
    'id': 1,
    'aid': 1,
    'bvid': bvid,
    'title': title,
    'description': '',
    'pic': '',
    'pubdate': 0,
    'senddate': 0,
    'duration': duration,
    'mid': 1,
    'author': 'UP',
    'upic': '',
    'play': play,
    'danmaku': 0,
    'favorite': 0,
    'review': 0,
    'like': 0,
    'type': 'video',
  });
}

void main() {
  const song = NeteaseSong(
    id: 3312263543,
    name: '恐龙的时代还是结束了（Intro）',
    artists: 'WaytheDinoScream',
    album: '校园里有长颈龙的日子',
    durationMs: 101647,
  );

  test('parses web, mobile, hash-route and numeric NetEase links', () {
    for (final input in [
      'https://music.163.com/song?id=3312263543',
      'https://music.163.com/#/song?id=3312263543',
      'https://y.music.163.com/m/song?id=3312263543&userid=1',
      '分享歌曲 https://music.163.com/#/song?id=3312263543。',
      '3312263543',
    ]) {
      final link = parseNeteaseLink(input);
      expect(link?.id, 3312263543, reason: input);
      expect(link?.playlist, isFalse, reason: input);
    }
    for (final input in [
      'https://music.163.com/playlist?id=2718757645',
      'https://music.163.com/#/playlist?id=2718757645',
      'https://y.music.163.com/m/playlist?id=2718757645',
    ]) {
      final link = parseNeteaseLink(input);
      expect(link?.id, 2718757645, reason: input);
      expect(link?.playlist, isTrue, reason: input);
    }
  });

  test('rejects unrelated domains and invalid ids', () {
    for (final input in [
      'https://example.com/song?id=1',
      'https://notmusic.163.com/song?id=1',
      '0',
      '-1',
      'no link',
    ]) {
      expect(parseNeteaseLink(input), isNull, reason: input);
    }
  });

  test('extracts short links for redirect resolution', () {
    final uri = firstLinkUri('分享 https://163cn.tv/biXS6ucM。');
    expect(uri?.host, '163cn.tv');
    expect(isNeteaseShortHost(uri!.host), isTrue);
    expect(
      firstLinkUri('https://music.163.com/song?id=1')?.host,
      'music.163.com',
    );
  });

  test('normalizes bracketed suffixes for matching', () {
    expect(normalizeNeteaseText('恐龙的时代还是结束了（Intro）'), '恐龙的时代还是结束了');
    expect(normalizeNeteaseText('【4K】Song (Live)'), 'song');
    expect(normalizeNeteaseText(''), '');
  });

  test('prefers duration-matched, high-play candidates', () {
    final exact = _candidate(
      title: '恐龙的时代还是结束了（Intro）',
      duration: '01:41',
      play: 100000,
      bvid: 'BV1aa411c7mD',
    );
    final popular = _candidate(
      title: '恐龙的时代还是结束了（Intro） 4K',
      duration: '01:42',
      play: 5000000,
      bvid: 'BV1bb411c7mD',
    );
    final tooLong = _candidate(
      title: '恐龙的时代还是结束了（Intro） 合集',
      duration: '05:00',
      play: 99000000,
      bvid: 'BV1cc411c7mD',
    );
    final unrelated = _candidate(
      title: '完全不同的歌',
      duration: '01:41',
      play: 90000000,
      bvid: 'BV1dd411c7mD',
    );
    final best = bestNeteaseCandidate(song, [
      exact,
      popular,
      tooLong,
      unrelated,
    ]);
    expect(best?.bvid, 'BV1bb411c7mD');
  });

  test('uses the requested 百万豪装录音 preference as a tie-breaker', () {
    final plain = _candidate(
      title: '恐龙的时代还是结束了（Intro）',
      duration: '01:41',
      play: 1000000,
      bvid: 'BV1aa411c7mD',
    );
    final preferred = _candidate(
      title: '恐龙的时代还是结束了（Intro） 百万豪装录音',
      duration: '01:41',
      play: 1000000,
      bvid: 'BV1bb411c7mD',
    );
    final best = bestNeteaseCandidate(song, [plain, preferred]);
    expect(best?.bvid, 'BV1bb411c7mD');
  });

  test('returns null when no candidate matches the title', () {
    final best = bestNeteaseCandidate(song, [
      _candidate(title: '完全不同的歌', duration: '01:41', play: 1000000),
    ]);
    expect(best, isNull);
  });
}
