import 'package:html/parser.dart' show parseFragment;

class SongNameConsensus {
  final String name;
  final int matches;
  final int total;
  const SongNameConsensus(this.name, this.matches, this.total);
}

/// Words that appear in video titles around the song name but are never the
/// song itself. They are removed before a title is split into candidates.
final _noise = RegExp(
  r'翻唱|原唱|高清|完整版|无损|高音质|歌词|现场|纯享|官方|音乐|歌曲|伴奏|中字|中日|双语|字幕|重制|推荐|合集|精选|循环|小时|版本|cover|official|lyrics|music video|live|\b[248]k\b|\bmv\b|\bhi.?res\b',
  caseSensitive: false,
);

/// Brackets and separators that mark a title field boundary.
final _delimiters = RegExp(r'[《》「」『』“”"【】\[\]（）()丨|/:：·—–~～]|\s-\s');

/// Punctuation that ends a clause inside an undelimited title.
final _clause = RegExp(r'[\s,，、。;；!！?？+&＆*#@\t]+');

/// Joins the artist and the song in titles such as "歌手-歌名" without spaces.
final _hyphen = RegExp(r'[-－—_]+');

/// A candidate must contain at least one letter or CJK/kana/hangul character.
final _wordChar = RegExp(r'[A-Za-z\u3400-\u9fff\u3040-\u30ff\uac00-\ud7af]');

/// Strips HTML highlighting and surrounding whitespace from a video title.
String cleanTitle(String title) => (parseFragment(title).text ?? '').trim();

bool _usable(String value) {
  final text = value.trim();
  if (text.length < 2 || text.length > 60) return false;
  if (_noise.hasMatch(text)) return false;
  return _wordChar.hasMatch(text);
}

/// Splits a title into candidate song names.
///
/// Chinese and Japanese titles usually carry no spaces, so besides brackets and
/// separators this also walks the text and keeps every clause-bounded run, then
/// every hyphen-bounded run inside it. That turns
/// "【初音】千本桜-初音ミク" into "初音", "千本桜", "初音ミク" and
/// "千本桜 初音ミク" into "千本桜", "初音ミク".
Iterable<String> titleCandidates(String title) {
  final clean = cleanTitle(title);
  if (clean.isEmpty) return const [];
  final out = <String>[];
  final seen = <String>{};
  void emit(String value) {
    final text = value.trim();
    if (!_usable(text)) return;
    if (seen.add(text.toLowerCase())) out.add(text);
  }

  for (final match in RegExp(r'[《「『“"]([^》」』”"]{2,60})[》」』”"]')
      .allMatches(clean)) {
    emit(match[1]!);
  }
  for (final field in clean.split(_delimiters)) {
    for (final clause in field.split(_clause)) {
      // A clause such as "歌手-歌名" still hides the name behind a hyphen.
      for (final part in clause.split(_hyphen)) {
        emit(part);
      }
      // Keep the whole clause too: it may be the complete song name.
      emit(clause);
    }
    emit(field);
  }
  return out;
}

/// Count videos, rather than word occurrences, so repeated keywords cannot vote
/// more than once. Callers supply one title per unique video.
SongNameConsensus? inferSongName(Iterable<String> titles) {
  final clean = titles.take(60).map(cleanTitle).where((e) => e.isNotEmpty).toList();
  if (clean.length < 4) return null;
  final candidates = <String, String>{};
  for (final title in clean) {
    for (final candidate in titleCandidates(title)) {
      candidates.putIfAbsent(candidate.toLowerCase(), () => candidate);
    }
  }
  final normalized = clean.map((e) => e.toLowerCase()).toList();
  final votes = <String, int>{};
  for (final key in candidates.keys) {
    // Latin names must match complete words ("Love" must not match "Lovely").
    final pattern = RegExp(
      '${RegExp(r"^[a-z0-9]").hasMatch(key) ? r"(?<![a-z0-9])" : ""}${RegExp.escape(key)}${RegExp(r"[a-z0-9]$").hasMatch(key) ? r"(?![a-z0-9])" : ""}',
    );
    final count = normalized.where(pattern.hasMatch).length;
    if (count >= 4 && count / clean.length >= .7) votes[key] = count;
  }
  if (votes.isEmpty) return null;
  final ranked = votes.keys.toList()
    ..sort((a, b) {
      final count = votes[b]!.compareTo(votes[a]!);
      return count != 0 ? count : b.length.compareTo(a.length);
    });
  final best = ranked.first;
  // Competing artist/series/song names with similar support are ambiguous.
  if (ranked
      .skip(1)
      .any(
        (e) =>
            !best.contains(e) &&
            !e.contains(best) &&
            votes[e]! >= votes[best]! - 1,
      ))
    return null;
  return SongNameConsensus(candidates[best]!, votes[best]!, clean.length);
}
