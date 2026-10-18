import 'package:PiliPlus/pages/listening/controller.dart';
import 'package:PiliPlus/pages/listening/models.dart';
import 'package:flutter_test/flutter_test.dart';

class RetryController extends ListeningController {
  final calls = <String>[];
  @override
  Future<void> save() async {}
  @override
  Future<void> openSong(
    ListeningPlaylist list,
    ListeningSong song,
    int request,
  ) async {
    calls.add(song.id);
    if (song.id == 'old' || calls.length < 3 && song.id == 'retry') {
      throw StateError('temporary stream failure');
    }
  }
}

ListeningSong song(String id) => ListeningSong(
  id: id,
  name: id,
  original: const SongSource(
    bvid: 'BV1',
    aid: 1,
    cid: 1,
    page: 1,
    title: 'song',
  ),
);

void main() {
  test('refreshes stream twice before asking to change source', () async {
    final controller = RetryController();
    final item = song('retry');
    final list = ListeningPlaylist(id: 'list', name: 'list', songs: [item]);
    var failures = 0;
    controller.onUnavailable = (_) => failures++;
    await controller.play(list, item);
    expect(controller.calls, ['retry', 'retry', 'retry']);
    expect(item.error, isNull);
    expect(failures, 0);
    expect(controller.loading.value, isFalse);
  });

  test('changing song cancels pending retry of old song', () async {
    final controller = RetryController();
    final old = song('old');
    final next = song('next');
    final list = ListeningPlaylist(
      id: 'list',
      name: 'list',
      songs: [old, next],
    );
    final pending = controller.play(list, old);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await controller.play(list, next);
    await pending;
    expect(controller.calls, ['old', 'next']);
    expect(controller.current.value, same(next));
    expect(controller.loading.value, isFalse);
  });
}
