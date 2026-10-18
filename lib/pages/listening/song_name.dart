import 'package:html/parser.dart' show parseFragment;

class SongNameConsensus {
  final String name;
  final int matches;
  final int total;
  const SongNameConsensus(this.name, this.matches, this.total);
}

/// Count videos, rather than word occurrences, so repeated keywords cannot vote
/// more than once. Callers supply one title per unique video.
SongNameConsensus? inferSongName(Iterable<String> titles) {
  final clean = titles
      .take(60)
      .map((e) => (parseFragment(e).text ?? '').trim())
      .where((e) => e.isNotEmpty)
      .toList();
  if (clean.length < 4) return null;
  final candidates = <String, String>{};
  final quotes = RegExp(r'[《「『“"]([^》」』”"]{2,60})[》」』”"]');
  final noise = RegExp(
    r'翻唱|原唱|高清|完整版|无损|高音质|歌词|现场|纯享|官方|音乐|歌曲|伴奏|中字|中日|双语|字幕|重制|推荐|合集|精选|循环|小时|版本|cover|official|lyrics|music video|live|\b[248]k\b|\bmv\b|\bhi.?res\b',
    caseSensitive: false,
  );
  void add(String value) {
    value = value.trim();
    if (value.length < 2 || value.length > 60 || noise.hasMatch(value)) return;
    if (!RegExp(r'[A-Za-z\u3400-\u9fff\u3040-\u30ff\uac00-\ud7af]')
        .hasMatch(value))
      return;
    candidates.putIfAbsent(value.toLowerCase(), () => value);
  }

  for (final title in clean) {
    for (final match in quotes.allMatches(title)) {
      add(match[1]!);
    }
    // Delimited title fields provide candidates even when the song is unquoted.
    for (final part in title.split(
      RegExp(r'[《》「」『』“”"【】\[\]（）()丨|/:：·—–]|\s-\s'),
    )) {
      add(part);
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
