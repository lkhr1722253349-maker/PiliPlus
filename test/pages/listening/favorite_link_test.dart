import 'package:PiliPlus/pages/listening/favorite_link.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses shared space favorite links and numeric folder IDs', () {
    expect(
      favoriteFolderId(
        '收藏夹 https://space.bilibili.com/123/favlist?fid=456&ftype=create',
      ),
      456,
    );
    expect(
      favoriteFolderId('https://www.bilibili.com/medialist/detail/ml789'),
      789,
    );
    expect(favoriteFolderId('https://www.bilibili.com/list/ml789'), 789);
    expect(
      favoriteFolderId(
        'https://www.bilibili.com/medialist/play/123?business=space&business_id=456',
      ),
      456,
    );
    expect(
      favoriteFolderId('https://www.bilibili.com/medialist/play/ml789'),
      789,
    );
    expect(
      favoriteFolderId('https://www.bilibili.com/favlist?media_id=456'),
      456,
    );
    expect(favoriteFolderId(' 456 '), 456);
  });

  test('rejects video IDs, unrelated domains and invalid folder IDs', () {
    for (final input in [
      'https://evilbilibili.com/favlist?fid=456',
      'https://example.com/?fid=456',
      'https://www.bilibili.com/video/BV1234567890',
      'https://www.bilibili.com/list/123?business=season&business_id=456',
      'https://space.bilibili.com/123/favlist?fid=-1',
      '0',
      'no link',
    ]) {
      expect(favoriteFolderId(input), isNull, reason: input);
    }
  });

  test('extracts b23 links from share text for redirect resolution', () {
    expect(favoriteLinkUri('分享收藏夹 https://b23.tv/abc123。')?.host, 'b23.tv');
    expect(favoriteFolderId('https://b23.tv/abc123'), isNull);
  });
}
