import 'dart:io';

import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

void main() {
  late Directory directory;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('piliplus-speeds-');
    Hive.init(directory.path);
    GStorage.video = await Hive.openBox('video');
  });
  setUp(() => GStorage.video.clear());
  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('existing custom speeds gain 4 to 10 without losing custom values or duplicates', () async {
    await GStorage.video.put(VideoBoxKey.speedsList, [1.0, 2.5, 4.0]);
    final speeds = Pref.speedList;
    expect(speeds, [1.0, 2.5, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0]);
    expect(Pref.speedList, speeds);
    await GStorage.video.put(VideoBoxKey.speedsList, [1.0, 2.5]);
    expect(Pref.speedList, [1.0, 2.5]); // Deleting a preset remains supported.
  });
}
