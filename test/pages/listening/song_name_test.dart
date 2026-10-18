import 'package:PiliPlus/pages/listening/song_name.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('recognizes the repeated song across HTML and title decorations', () {
    final result = inferSongName([
      '甲《春日影》翻唱',
      '乙「春日影」现场',
      '丙 - <em>春日影</em> - 完整版',
      '丁【春日影】高清',
      '其他歌曲',
    ]);
    expect(result?.name, '春日影');
    expect(result?.matches, 4);
    expect(result?.total, 5);
  });
  test('keeps English word boundaries and original case', () {
    expect(
      inferSongName([
        'A - Test Song - Cover',
        'B《Test Song》Official',
        'C「Test Song」Live',
        'D【Test Song】Lyrics',
      ])?.name,
      'Test Song',
    );
    expect(
      inferSongName([
        'A - Love',
        'B - Lovely',
        'C - Lovely',
        'D - Lovely',
      ]),
      isNull,
    );
  });
  test('rejects generic words and ambiguous artist versus song', () {
    expect(inferSongName(List.filled(5, '高清完整版翻唱')), isNull);
    expect(
      inferSongName([
        '歌手甲 - 春日影',
        '歌手甲《春日影》',
        '歌手甲「春日影」',
        '歌手甲【春日影】',
      ]),
      isNull,
    );
    expect(inferSongName(['《春日影》', '《春日影》', '《春日影》']), isNull);
  });
}
