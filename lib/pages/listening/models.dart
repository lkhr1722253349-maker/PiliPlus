class SongSource {
  final String bvid;
  final int aid;
  final int cid;
  final int page;
  final String title;
  final String cover;

  const SongSource({
    required this.bvid,
    required this.aid,
    required this.cid,
    required this.page,
    required this.title,
    this.cover = '',
  });

  factory SongSource.fromJson(Map json) => SongSource(
    bvid: json['bvid'],
    aid: json['aid'],
    cid: json['cid'],
    page: json['page'],
    title: json['title'],
    cover: json['cover'] ?? '',
  );
  Map<String, dynamic> toJson() => {
    'bvid': bvid,
    'aid': aid,
    'cid': cid,
    'page': page,
    'title': title,
    'cover': cover,
  };
  String get key => '$bvid:$cid';
}

class ListeningSong {
  final String id;
  String name;
  bool nameEdited;
  String? namedSource;
  final SongSource original;
  SongSource source;
  final List<SongSource> previousSources;
  final Set<int> folderIds;
  final int? ownerMid;
  String? error;
  bool pendingFavoriteSync;

  ListeningSong({
    required this.id,
    required this.name,
    this.nameEdited = false,
    this.namedSource,
    required this.original,
    SongSource? source,
    List<SongSource>? previousSources,
    Set<int>? folderIds,
    this.ownerMid,
    this.error,
    this.pendingFavoriteSync = false,
  }) : source = source ?? original,
       previousSources = previousSources ?? [],
       folderIds = folderIds ?? {};

  void replace(SongSource replacement) {
    if (source.key != replacement.key) previousSources.add(source);
    source = replacement;
    error = null;
  }

  factory ListeningSong.fromJson(Map json) => ListeningSong(
    id: json['id'],
    name: json['name'],
    nameEdited:
        json['nameEdited'] ?? (json['name'] != json['original']['title']),
    namedSource: json['namedSource'],
    original: SongSource.fromJson(json['original']),
    source: SongSource.fromJson(json['source']),
    previousSources: (json['previousSources'] as List? ?? [])
        .map((e) => SongSource.fromJson(e))
        .toList(),
    folderIds: Set<int>.from(json['folderIds'] ?? []),
    ownerMid: json['ownerMid'],
    error: json['error'],
    pendingFavoriteSync: json['pendingFavoriteSync'] ?? false,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'nameEdited': nameEdited,
    'namedSource': namedSource,
    'original': original.toJson(),
    'source': source.toJson(),
    'previousSources': previousSources.map((e) => e.toJson()).toList(),
    'folderIds': folderIds.toList(),
    'ownerMid': ownerMid,
    'error': error,
    'pendingFavoriteSync': pendingFavoriteSync,
  };
}

class ListeningPlaylist {
  final String id;
  String name;
  final List<ListeningSong> songs;
  ListeningPlaylist({
    required this.id,
    required this.name,
    List<ListeningSong>? songs,
  }) : songs = songs ?? [];
  factory ListeningPlaylist.fromJson(Map json) => ListeningPlaylist(
    id: json['id'],
    name: json['name'],
    songs: (json['songs'] as List)
        .map((e) => ListeningSong.fromJson(e))
        .toList(),
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'songs': songs.map((e) => e.toJson()).toList(),
  };

  bool add(ListeningSong song) {
    final existing = songs.where(
      (e) => e.source.key == song.source.key && e.ownerMid == song.ownerMid,
    );
    if (existing.isNotEmpty) {
      existing.first.folderIds.addAll(song.folderIds);
      return false;
    }
    songs.add(song);
    return true;
  }
}
