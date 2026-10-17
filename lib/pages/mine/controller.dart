import 'package:PiliPlus/common/widgets/custom_icon.dart';
import 'package:PiliPlus/http/fav.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/user.dart';
import 'package:PiliPlus/models/common/later_view_type.dart';
import 'package:PiliPlus/models/common/mine_tab_type.dart';
import 'package:PiliPlus/models/common/theme/theme_type.dart';
import 'package:PiliPlus/models/user/info.dart';
import 'package:PiliPlus/models/user/stat.dart';
import 'package:PiliPlus/models_new/fav/fav_folder/data.dart';
import 'package:PiliPlus/models_new/fav/fav_folder/list.dart';
import 'package:PiliPlus/models_new/history/data.dart';
import 'package:PiliPlus/models_new/history/list.dart';
import 'package:PiliPlus/models_new/later/data.dart';
import 'package:PiliPlus/models_new/later/list.dart';
import 'package:PiliPlus/models_new/sub/sub/data.dart';
import 'package:PiliPlus/models_new/sub/sub/list.dart';
import 'package:PiliPlus/pages/common/common_list_controller.dart';
import 'package:PiliPlus/services/account_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/extension/scroll_controller_ext.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/theme_utils.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class MineController extends GetxController with AccountMixin {
  @override
  AccountService accountService = Get.find<AccountService>();

  // 用户信息 头像、昵称、lv
  final Rx<UserInfoData> userInfo = UserInfoData().obs;
  // 用户状态 动态、关注、粉丝
  final Rx<UserStat> userStat = const UserStat().obs;

  final Rx<ThemeType> themeType = Pref.themeType.obs;

  ThemeType get nextThemeType =>
      ThemeType.values[(themeType.value.index + 1) % ThemeType.values.length];

  static RxBool anonymity = Accounts.anonymousBrowsing.obs;

  late final list = <({IconData icon, String title, VoidCallback onTap})>[
    (
      icon: Icons.library_music_outlined,
      title: '听视频歌单',
      onTap: () => Get.toNamed('/listening'),
    ),
    (
      icon: CustomIcons.folderDownloadOutline,
      title: '离线缓存',
      onTap: () => Get.toNamed('/download'),
    ),
    (
      icon: CustomIcons.history,
      title: '观看记录',
      onTap: () {
        if (isLogin) {
          Get.toNamed('/history');
        }
      },
    ),
    (
      icon: CustomIcons.subscriptions_outlined,
      title: '我的订阅',
      onTap: () {
        if (isLogin) {
          Get.toNamed('/subscription');
        }
      },
    ),
    (
      icon: CustomIcons.watch_later_outlined,
      title: '稍后再看',
      onTap: () {
        if (isLogin) {
          Get.toNamed('/later');
        }
      },
    ),
  ];

  late final Set<MineTabType> mineTabs;
  FavCtr? favCtr;
  HistoryCtr? historyCtr;
  LaterCtr? laterCtr;
  SubCtr? subCtr;

  Iterable<MineRefreshMixin> tabCtr() sync* {
    if (favCtr != null) yield favCtr!;
    if (historyCtr != null) yield historyCtr!;
    if (laterCtr != null) yield laterCtr!;
    if (subCtr != null) yield subCtr!;
  }

  void _initTabs() {
    mineTabs = Pref.mineTabs;
    for (final tab in mineTabs) {
      switch (tab) {
        case .favorite:
          favCtr = FavCtr();
        case .history:
          historyCtr = HistoryCtr();
        case .later:
          laterCtr = LaterCtr();
        case .sub:
          subCtr = SubCtr();
      }
    }
  }

  @override
  void onInit() {
    super.onInit();
    _initTabs();
    final userInfoCache = Pref.userInfoCache;
    if (userInfoCache != null) {
      userInfo.value = userInfoCache;
      queryUserInfo();
      tabCtr().forEach((ctr) => ctr.queryData());
    }
  }

  bool get isLogin => accountService.isLogin.value;

  Future<void> queryUserInfo() async {
    final res = await UserHttp.userInfo();
    if (res case Success(:final response)) {
      if (response.isLogin == true) {
        userInfo.value = response;
        if (response != Pref.userInfoCache) {
          GStorage.userInfo.put('userInfoCache', response);
        }
        accountService
          ..face.value = response.face!
          ..isLogin.value = true;
      } else {
        _onLogoutMain();
        return;
      }
    } else {
      final errMsg = res.toString();
      SmartDialog.showToast(errMsg);
      if (errMsg == '账号未登录') {
        _onLogoutMain();
        return;
      }
    }
    queryUserStatOwner();
  }

  void _onLogoutMain() => Accounts.deleteAll({Accounts.main});

  Future<void> queryUserStatOwner() async {
    final res = await UserHttp.userStatOwner();
    if (res case Success(:final response)) {
      userStat.value = response;
    }
  }

  static Future<void> onChangeAnonymity() async {
    final value = !anonymity.value;
    await Accounts.setAnonymousBrowsing(value);
    anonymity.value = value;
    SmartDialog.showToast(
      value ? '已开启匿名浏览：推荐、搜索和播放不携带登录身份，不上传观看记录；收藏仍使用主账号' : '已关闭匿名浏览，恢复各功能的账号设置',
    );
  }

  void onChangeTheme() {
    final newVal = nextThemeType;
    themeType.value = newVal;
    GStorage.setting.put(SettingBoxKey.themeMode, newVal.index);
    Get.changeThemeMode(ThemeUtils.themeMode = newVal.toThemeMode);
  }

  void push(String name) {
    late final mid = userInfo.value.mid;
    if (isLogin && mid != null) {
      Get.toNamed('/$name?mid=$mid');
    }
  }

  void onLogin([bool longPress = false]) {
    if (!accountService.isLogin.value || longPress) {
      Get.toNamed('/loginPage');
    } else {
      Get.toNamed('/member?mid=${userInfo.value.mid}');
    }
  }

  Future<void> onRefresh({bool isManual = true}) {
    if (!accountService.isLogin.value) {
      return Future.syncValue(null);
    }
    if (isManual) {
      queryUserInfo();
    }
    return Future.wait(
      tabCtr().map((ctr) => ctr.onRefresh(isManual: isManual)),
    );
  }

  @override
  void onChangeAccount(bool isLogin) {
    if (isLogin) {
      onRefresh();
    } else {
      userInfo.value = UserInfoData();
      userStat.value = const UserStat();
      tabCtr().forEach(
        (ctr) => ctr.loadingState.value = LoadingState.loading(),
      );
    }
  }
}

const _ps = 20;

mixin MineRefreshMixin<R, T> on CommonListController<R, T> {
  int? count;

  @override
  void checkIsEnd(int length) {
    if (count != null && length >= count!) {
      isEnd = true;
    }
  }

  @override
  Future<void> onRefresh({bool isManual = true}) {
    count = null;
    if (isManual) {
      return super.onRefresh().whenComplete(scrollController.jumpToTop);
    }
    return super.onRefresh();
  }
}

class FavCtr extends CommonListController<FavFolderData, FavFolderInfo>
    with MineRefreshMixin {
  @override
  List<FavFolderInfo>? getDataList(FavFolderData response) {
    count = response.count;
    if (response.hasMore == false) isEnd = true;
    return response.list;
  }

  @override
  Future<LoadingState<FavFolderData>> customGetData() =>
      FavHttp.userfavFolder(pn: page, ps: _ps, mid: Accounts.main.mid);
}

class HistoryCtr extends CommonListController<HistoryData, HistoryItemModel>
    with MineRefreshMixin {
  int? viewAt;
  int? max;

  @override
  List<HistoryItemModel>? getDataList(HistoryData response) {
    final last = response.list?.lastOrNull;
    if (last == null) {
      isEnd = true;
      max = viewAt = null;
    } else {
      isEnd = false;
      max = last.history.oid;
      viewAt = last.viewAt;
    }
    return response.list;
  }

  @override
  Future<LoadingState<HistoryData>> customGetData() => UserHttp.historyList(
    type: 'all',
    viewAt: viewAt,
    max: max,
    ps: _ps,
    account: Accounts.history,
  );

  @override
  Future<void> onRefresh({bool isManual = true}) {
    viewAt = null;
    max = null;
    return super.onRefresh(isManual: isManual);
  }
}

class LaterCtr extends CommonListController<LaterData, LaterItemModel>
    with MineRefreshMixin {
  @override
  List<LaterItemModel>? getDataList(LaterData response) {
    count = response.count;
    return response.list;
  }

  @override
  Future<LoadingState<LaterData>> customGetData() =>
      UserHttp.seeYouLater(page: page, ps: _ps, viewed: LaterViewType.all.type);
}

class SubCtr extends CommonListController<SubData, SubItemModel>
    with MineRefreshMixin {
  @override
  List<SubItemModel>? getDataList(SubData response) {
    count = response.count;
    if (response.hasMore == false) isEnd = true;
    return response.list;
  }

  @override
  Future<LoadingState<SubData>> customGetData() =>
      UserHttp.userSubFolder(pn: page, ps: _ps, mid: Accounts.main.mid);
}
