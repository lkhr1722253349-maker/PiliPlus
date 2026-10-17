Uri? favoriteLinkUri(String input) {
  final link = RegExp(
    r'https?://[^\s<>"，。]+',
    caseSensitive: false,
  ).firstMatch(input)?.group(0);
  return link == null ? null : Uri.tryParse(link);
}

int? favoriteFolderId(String input) {
  final raw = input.trim();
  if (RegExp(r'^\d+$').hasMatch(raw)) {
    final id = int.tryParse(raw);
    return id != null && id > 0 ? id : null;
  }
  final uri = favoriteLinkUri(raw);
  if (uri == null ||
      !(uri.host == 'bilibili.com' || uri.host.endsWith('.bilibili.com'))) {
    return null;
  }
  String? id = uri.queryParameters['fid'] ?? uri.queryParameters['media_id'];
  if (id == null && uri.queryParameters['business'] == 'space') {
    id = uri.queryParameters['business_id'];
  }
  id ??= RegExp(r'/(?:medialist/(?:detail|play)|list)/ml(\d+)(?:/|$)')
      .firstMatch(uri.path)
      ?.group(1);
  final parsed = int.tryParse(id ?? '');
  return parsed != null && parsed > 0 ? parsed : null;
}
