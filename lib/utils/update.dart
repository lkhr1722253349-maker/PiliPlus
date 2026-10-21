import 'dart:io' show File, Platform;

import 'package:PiliPlus/build_config.dart';
import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_bspatch/flutter_bspatch.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

abstract final class Update {
  /// Whether a GitHub release is newer than this build.
  ///
  /// A release is newer when its tag names a different version, or when it was
  /// published after this build. `published_at` is used because `created_at`
  /// is the tag's commit time: publishing a tag that points at an older commit
  /// (or at another branch) would otherwise look "older" than the installed
  /// build and the update would never be offered.
  static bool isNewer({
    required String tagName,
    required String? publishedAt,
    required String? createdAt,
    required String installedVersion,
    required int installedBuildTime,
  }) {
    String numeric(String value) =>
        value.split('-').first.split('+').first.trim().replaceFirst(
          RegExp(r'^[vV]'),
          '',
        );
    final tag = numeric(tagName);
    final installed = numeric(installedVersion);
    if (tag.isNotEmpty && installed.isNotEmpty && tag != installed) return true;
    final stamp = publishedAt ?? createdAt;
    if (stamp == null) return false;
    final latest = DateTime.tryParse(stamp)?.millisecondsSinceEpoch;
    if (latest == null) return false;
    return installedBuildTime < latest ~/ 1000;
  }

  // 检查更新
  static Future<void> checkUpdate([bool isAuto = true]) async {
    if (kDebugMode) return;
    SmartDialog.dismiss();
    try {
      final res = await Request().get(
        Api.latestApp,
        options: Options(
          headers: {'user-agent': BrowserUa.mob},
          extra: {'account': const NoAccount()},
        ),
      );
      if (res.data is Map || res.data.isEmpty) {
        if (!isAuto) {
          SmartDialog.showToast('检查更新失败，GitHub接口未返回数据，请检查网络');
        }
        return;
      }
      final data = res.data[0];
      final newer = isNewer(
        tagName: '${data['tag_name'] ?? ''}',
        publishedAt: data['published_at'] as String?,
        createdAt: data['created_at'] as String?,
        installedVersion: BuildConfig.versionName,
        installedBuildTime: BuildConfig.buildTime,
      );
      if (!newer) {
        if (!isAuto) {
          SmartDialog.showToast('已是最新版本');
        }
      } else {
        SmartDialog.show(
          animationType: SmartAnimationType.centerFade_otherSlide,
          builder: (context) {
            final colorScheme = ColorScheme.of(context);
            Widget downloadBtn(String text, {String? ext}) => TextButton(
              onPressed: () => onDownload(data, ext: ext),
              child: Text(text),
            );
            return AlertDialog(
              title: const Text('🎉 发现新版本 '),
              content: SizedBox(
                height: 280,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${data['tag_name']}',
                        style: const TextStyle(fontSize: 20),
                      ),
                      const SizedBox(height: 8),
                      Text('${data['body']}'),
                      TextButton(
                        onPressed: () => PageUtils.launchURL(
                          '${Constants.sourceCodeUrl}/compare/${BuildConfig.commitHash}...${data['tag_name']}',
                        ),
                        child: Text(
                          '查看两个版本之间的提交',
                          style: TextStyle(color: colorScheme.primary),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                if (isAuto)
                  TextButton(
                    onPressed: () {
                      SmartDialog.dismiss();
                      GStorage.setting.put(SettingBoxKey.autoUpdate, false);
                    },
                    child: Text(
                      '不再提醒',
                      style: TextStyle(color: colorScheme.outline),
                    ),
                  ),
                TextButton(
                  onPressed: SmartDialog.dismiss,
                  child: Text(
                    '取消',
                    style: TextStyle(color: colorScheme.outline),
                  ),
                ),
                if (Platform.isWindows) ...[
                  downloadBtn('zip', ext: 'zip'),
                  downloadBtn('exe', ext: 'exe'),
                ] else if (Platform.isLinux) ...[
                  downloadBtn('rpm', ext: 'rpm'),
                  downloadBtn('deb', ext: 'deb'),
                  downloadBtn('targz', ext: 'tar.gz'),
                ] else if (Platform.isAndroid)
                  downloadBtn('下载并安装（优先差分）')
                else
                  downloadBtn('Github'),
              ],
            );
          },
        );
      }
    } catch (e) {
      if (kDebugMode) debugPrint('failed to check update: $e');
    }
  }

  // 下载适用于当前系统的安装包
  static Future<void> onDownload(Map data, {String? ext}) async {
    SmartDialog.dismiss();
    try {
      void download(String plat) {
        if (data['assets'].isNotEmpty) {
          for (Map<String, dynamic> i in data['assets']) {
            final String name = i['name'];
            if (name.contains(plat) &&
                (ext == null || ext.isEmpty ? true : name.endsWith(ext))) {
              PageUtils.launchURL(i['browser_download_url']);
              return;
            }
          }
          throw UnsupportedError('platform not found: $plat');
        }
      }

      if (Platform.isAndroid) {
        // 获取设备信息
        AndroidDeviceInfo androidInfo = await DeviceInfoPlugin().androidInfo;
        final abi = androidInfo.supportedAbis.first;
        final assets = (data['assets'] as List).cast<Map<String, dynamic>>();
        final apk = assets
            .where((asset) => (asset['name'] as String).endsWith('_$abi.apk'))
            .firstOrNull;
        if (apk == null) throw UnsupportedError('APK not found: $abi');
        await _installAndroidUpdate(assets, apk, abi);
      } else {
        download(Platform.operatingSystem);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('download error: $e');
      PageUtils.launchURL('${Constants.sourceCodeUrl}/releases/latest');
    }
  }

  static Future<void> _installAndroidUpdate(
    List<Map<String, dynamic>> assets,
    Map<String, dynamic> apk,
    String abi,
  ) async {
    const channel = MethodChannel('com.example.piliplus/update');
    final directory = await getTemporaryDirectory();
    final output = File('${directory.path}/piliplus-update.apk');
    final patchFile = File('${directory.path}/piliplus-update.patch');
    final patchName =
        'PiliPlus_android_from_${BuildConfig.versionCode}_$abi.patch';
    final patches = assets.where((asset) => asset['name'] == patchName);
    final patch = patches.isEmpty ? null : patches.first;
    SmartDialog.showLoading(msg: '正在下载更新');
    try {
      if (output.existsSync()) output.deleteSync();
      if (patch != null &&
          (patch['size'] as num) < (apk['size'] as num) * 0.8) {
        try {
          final oldPath = await channel.invokeMethod<String>(
            'installedApkPath',
          );
          if (oldPath == null) throw StateError('Installed APK unavailable');
          await Dio().download(patch['browser_download_url'], patchFile.path);
          SmartDialog.showLoading(msg: '正在校验并合成安装包');
          await BsPatch.patch(
            oldFile: oldPath,
            patchFile: patchFile.path,
            newFile: output.path,
          );
          await _verifyApk(output, apk);
        } catch (e) {
          if (kDebugMode) debugPrint('Delta update fallback: $e');
          if (output.existsSync()) output.deleteSync();
        }
      }
      if (!output.existsSync()) {
        SmartDialog.showLoading(msg: '正在下载完整安装包');
        await Dio().download(apk['browser_download_url'], output.path);
        await _verifyApk(output, apk);
      }
      await channel.invokeMethod<void>('installApk', {'path': output.path});
    } finally {
      SmartDialog.dismiss();
      if (patchFile.existsSync()) patchFile.deleteSync();
    }
  }

  static Future<void> _verifyApk(File file, Map<String, dynamic> asset) async {
    final digest = asset['digest'];
    if (digest is! String || !digest.startsWith('sha256:')) {
      throw const FormatException('GitHub release asset has no SHA-256 digest');
    }
    final actual = await sha256.bind(file.openRead()).first;
    if (actual.toString() != digest.substring(7)) {
      throw const FormatException('APK SHA-256 mismatch');
    }
  }
}
