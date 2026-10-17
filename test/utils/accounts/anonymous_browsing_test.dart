import 'dart:io';

import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

void main() {
  late Directory directory;
  late LoginAccount loggedIn;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('piliplus-anonymous-');
    Hive.init(directory.path);
    GStorage.setting = await Hive.openBox('setting');
    GStorage.localCache = await Hive.openBox('localCache');
    loggedIn = LoginAccount(
      BiliCookieJar.fromJson({
        'DedeUserID': '123',
        'bili_jct': 'csrf',
        'SESSDATA': 'session',
      }),
      'access-key',
      'refresh',
    );
  });
  setUp(() async {
    await GStorage.setting.clear();
    for (final type in AccountType.values) {
      Accounts.accountMode[type.index] = loggedIn;
    }
  });
  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('anonymous browsing covers playback, recommendations and history, preserves main login', () async {
    await Accounts.setAnonymousBrowsing(true);
    expect(Accounts.main, same(loggedIn));
    expect(Accounts.get(AccountType.main).isLogin, isTrue);
    for (final type in [
      AccountType.video,
      AccountType.recommend,
      AccountType.heartbeat,
    ]) {
      final account = Accounts.get(type);
      expect(account, isA<AnonymousAccount>());
      expect(account.accessKey, isNull);
      expect(account.mid, 0);
      final cookies = await account.cookieJar.loadForRequest(
        Uri.parse('https://www.bilibili.com'),
      );
      expect(
        cookies.any((e) => e.name == 'SESSDATA' || e.name == 'DedeUserID'),
        isFalse,
      );
    }
    expect(Accounts.video.isLogin, isFalse);
    expect(Accounts.heartbeat.isLogin, isFalse);
    expect(Accounts.history.isLogin, isFalse);
  });

  test('disabling anonymity restores each configured account', () async {
    await Accounts.setAnonymousBrowsing(true);
    await Accounts.setAnonymousBrowsing(false);
    for (final type in AccountType.values) {
      expect(Accounts.get(type), same(loggedIn));
    }
  });
}
