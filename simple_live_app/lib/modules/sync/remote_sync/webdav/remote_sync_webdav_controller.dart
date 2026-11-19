import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/app/utils/archive.dart';
import 'package:simple_live_app/app/utils/document.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/modules/sync/remote_sync/webdav/webdav_client.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_app/services/douyu_account_service.dart';
import 'package:simple_live_app/services/huya_account_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

class RemoteSyncWebDAVController extends BaseController {
  // ui
  var passwordVisible = true.obs;
  // ui-用户选择是否同步
  var isSyncFollows = true.obs;
  var isSyncHistories = true.obs;
  var isSyncBlockWord = true.obs;
  var isSyncBilibiliAccount = true.obs;
  var isSyncDouyuAccount = true.obs;
  var isSyncHuyaAccount = true.obs;
  var isSyncDouyinAccount = true.obs;

  late DAVClient davClient;
  var user = "--".obs;
  var lastRecoverTime = "--".obs;
  var lastUploadTime = "--".obs;

  final _userFollowJsonName = 'SimpleLive_follows.json';
  final _userHistoriesJsonName = 'SimpleLive_histories.json';
  final _userBlockedWordJsonName = 'SimpleLive_blocked_word.json';
  final _userBilibiliAccountJsonName = 'SimpleLive_bilibili_account.json';
  final _userDouyuAccountJsonName = 'SimpleLive_douyu_account.json';
  final _userHuyaAccountJsonName = 'SimpleLive_huya_account.json';
  final _userDouyinAccountJsonName = 'SimpleLive_douyin_account.json';
  final _userSettingsJsonName = 'SimpleLive_Settings.json';
  final _userTagsJsonName = 'SimpleLive_Tags.json';

  /// 账号 Cookie、WebDAV 凭据与本地缓存不写进「设置」文件：
  /// 账号有独立的备份文件与开关，凭据和缓存不该上传到云端。
  static const List<String> _excludedSettingKeys = [
    LocalStorageService.kBilibiliCookie,
    LocalStorageService.kDouyuCookie,
    LocalStorageService.kHuyaCookie,
    LocalStorageService.kHuyaNickname,
    LocalStorageService.kDouyinCookie,
    LocalStorageService.kDouyinLoginCookie,
    LocalStorageService.kWebDAVUri,
    LocalStorageService.kWebDAVUser,
    LocalStorageService.kWebDAVPassword,
    LocalStorageService.kWebDAVLastUploadTime,
    LocalStorageService.kWebDAVLastRecoverTime,
    LocalStorageService.kBiliFollowingCache,
  ];

  @override
  void onInit() {
    doWebDAVInit();
    super.onInit();
  }

  // webDAV 逻辑
  // 初始化webDAV
  void doWebDAVInit() {
    var uri = LocalStorageService.instance
        .getValue(LocalStorageService.kWebDAVUri, "");
    if (uri.isEmpty) {
      notLogin.value = true;
    } else {
      user.value = LocalStorageService.instance
          .getValue(LocalStorageService.kWebDAVUser, "");
      var password = LocalStorageService.instance
          .getValue(LocalStorageService.kWebDAVPassword, "");
      davClient = DAVClient(uri, user.value, password);
      // 从未同步过默认为最新数据
      lastRecoverTime.value = Utils.parseTime(
        DateTime.fromMillisecondsSinceEpoch(
          LocalStorageService.instance.getValue(
            LocalStorageService.kWebDAVLastRecoverTime,
            DateTime.now().millisecondsSinceEpoch,
          ),
        ),
      );
      lastUploadTime.value = Utils.parseTime(
        DateTime.fromMillisecondsSinceEpoch(
          LocalStorageService.instance.getValue(
            LocalStorageService.kWebDAVLastUploadTime,
            DateTime.now().millisecondsSinceEpoch,
          ),
        ),
      );
      checkIsLogin();
    }
  }

  // 检查webDAV登录状态
  Future<void> checkIsLogin() async {
    try {
      // 返回登录结果
      bool value = await davClient.pingCompleter.future;
      notLogin.value = !value;
    } catch (e) {
      Log.e("$e", StackTrace.current);
      notLogin.value = true;
    }
  }

  // WebDAV登录
  void doWebDAVLogin(
      String webDAVUri, String webDAVUser, String webDAVPassword) async {
    // 确认登录
    davClient = DAVClient(webDAVUri, webDAVUser, webDAVPassword);
    await checkIsLogin();
    if (!notLogin.value) {
      // 保存到本地
      LocalStorageService.instance
          .setValue(LocalStorageService.kWebDAVUri, webDAVUri);
      LocalStorageService.instance
          .setValue(LocalStorageService.kWebDAVUser, webDAVUser);
      user.value = webDAVUser;
      LocalStorageService.instance
          .setValue(LocalStorageService.kWebDAVPassword, webDAVPassword);
      Get.back();
      SmartDialog.showToast("登录成功！");
    } else {
      SmartDialog.showToast("WebDAV账号密码验证失败，请重新输入！");
    }
  }

  // WebDAV登出
  @override
  Future<void> onLogout() async {
    var result = await Utils.showAlertDialog("确定要登出WebDAV账号？", title: "退出登录");
    if (result) {
      // 清除本地账号数据
      LocalStorageService.instance.setValue(LocalStorageService.kWebDAVUri, "");
      LocalStorageService.instance
          .setValue(LocalStorageService.kWebDAVUser, "");
      LocalStorageService.instance
          .setValue(LocalStorageService.kWebDAVPassword, "");
      notLogin.value = true;
    }
  }

  // webDAV上传到云端
  Future<void> doWebDAVUpload() async {
    SmartDialog.showLoading(msg: "正在上传到云端");
    _backupData().then((value) async {
      SmartDialog.dismiss();
      if (value.isNotEmpty) {
        var result = await davClient.backup(Uint8List.fromList(value));
        if (result) {
          SmartDialog.showToast("上传成功");
          DateTime uploadTime = DateTime.now();
          lastUploadTime.value = Utils.parseTime(uploadTime);
          LocalStorageService.instance.setValue(
              LocalStorageService.kWebDAVLastUploadTime,
              uploadTime.millisecondsSinceEpoch);
        } else {
          Log.e("备份失败", StackTrace.current);
          SmartDialog.showToast("上传失败");
        }
      } else {
        SmartDialog.showToast("上传失败");
      }
    });
  }

  // 备份所有数据
  Future<List<int>> _backupData() async {
    final archive = Archive();
    List<int> zipBytes = [];
    // 获取本地备份路径
    var dir = (await getApplicationSupportDirectory()).path;
    var profile = Directory(join(dir, 'backup'));
    if (!profile.existsSync()) {
      profile.createSync();
    }
    try {
      // archive.add(filepath, data_map) 会导致文件损坏
      // follows
      var userFollowList = DBService.instance.getFollowList();
      var dataFollowsMap = {
        'data': userFollowList.map((e) => e.toJson()).toList()
      };
      final userFollowJsonFile = File(join(profile.path, _userFollowJsonName));
      await userFollowJsonFile.writeAsString(jsonEncode(dataFollowsMap));
      // 用户自定义标签
      var userTagsList = DBService.instance.getFollowTagList();
      var dataTagsMap = {'data': userTagsList.map((e) => e.toJson()).toList()};
      var userTagsJsonFile = File(join(profile.path, _userTagsJsonName));
      await userTagsJsonFile.writeAsString(jsonEncode(dataTagsMap));
      // histories
      var userHistoriesList = DBService.instance.getHistores();
      var dataHistoriesMap = {
        'data': userHistoriesList.map((e) => e.toJson()).toList()
      };
      final userHistoriesJsonFile =
          File(join(profile.path, _userHistoriesJsonName));
      await userHistoriesJsonFile.writeAsString(jsonEncode(dataHistoriesMap));

      // blocked_word
      var userShieldList = AppSettingsController.instance.shieldList;
      var dataShieldListMap = {'data': userShieldList.toList()};
      final userBlockedWordJsonFile =
          File(join(profile.path, _userBlockedWordJsonName));
      await userBlockedWordJsonFile
          .writeAsString(jsonEncode(dataShieldListMap));

      // bilibili_account
      var userBiliAccountCookieMap = {
        'data': {'cookie': BiliBiliAccountService.instance.cookie}
      };
      final bilibiliAccountJsonFile =
          File(join(profile.path, _userBilibiliAccountJsonName));
      await bilibiliAccountJsonFile
          .writeAsString(jsonEncode(userBiliAccountCookieMap));
      // 各平台账号（与局域网同步的 /sync/account/* 保持一致）
      var douyuAccountJsonFile =
          File(join(profile.path, _userDouyuAccountJsonName));
      await douyuAccountJsonFile.writeAsString(jsonEncode({
        'data': {'cookie': DouyuAccountService.instance.cookie}
      }));
      var huyaAccountJsonFile =
          File(join(profile.path, _userHuyaAccountJsonName));
      await huyaAccountJsonFile.writeAsString(jsonEncode({
        'data': {'cookie': HuyaAccountService.instance.cookie}
      }));
      var douyinAccountJsonFile =
          File(join(profile.path, _userDouyinAccountJsonName));
      await douyinAccountJsonFile.writeAsString(jsonEncode({
        'data': {
          'cookie': DouyinAccountService.instance.cookie,
          'loginCookie': DouyinAccountService.instance.loginCookie,
        }
      }));
      // settings（剔除账号 Cookie / WebDAV 凭据 / 本地缓存）
      var settingMap = <String, dynamic>{};
      LocalStorageService.instance.settingsBox.toMap().forEach((key, value) {
        var k = key.toString();
        if (_excludedSettingKeys.contains(k)) {
          return;
        }
        settingMap[k] = value;
      });
      var dataSettingListMap = {'data': settingMap};
      final settingJsonFile = File(join(profile.path, _userSettingsJsonName));
      await settingJsonFile.writeAsString(jsonEncode(dataSettingListMap));

      // 遍历profile路径下的所有文件压缩
      await archive.addDirectoryToArchive(profile.path, profile.path);
      final zipEncoder = ZipEncoder();
      zipBytes = zipEncoder.encode(archive);
      profile.clearSync();
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("备份失败：$e");
    }
    return zipBytes;
  }

  // webDAV恢复到本地
  void doWebDAVRecovery() async {
    SmartDialog.showLoading(msg: "正在恢复到本地");
    final data = await davClient.recovery();
    final archive = await Isolate.run<Archive>(() {
      final zipDecoder = ZipDecoder();
      return zipDecoder.decodeBytes(data);
    });
    for (ArchiveFile file in archive) {
      await _recovery(file);
    }
    SmartDialog.dismiss();
    SmartDialog.showToast('同步完成');
    DateTime recoverTime = DateTime.now();
    lastRecoverTime.value = Utils.parseTime(recoverTime);
    LocalStorageService.instance.setValue(
        LocalStorageService.kWebDAVLastRecoverTime,
        recoverTime.millisecondsSinceEpoch);
  }

  Future<void> _recovery(ArchiveFile file) async {
    if (file.isFile && file.name.endsWith('.json')) {
      var jsonString = utf8.decode(file.content);
      var jsonData = json.decode(jsonString)['data'];
      // 同步follows
      if (file.name == _userFollowJsonName && isSyncFollows.value) {
        // 当前云优先
        try {
          // 清空本地关注列表
          await DBService.instance.followBox.clear();
          for (var item in jsonData) {
            var user = FollowUser.fromJson(item);
            await DBService.instance.followBox.put(user.id, user);
          }
          Log.i('已同步关注用户列表');
        } catch (e) {
          Log.e('同步关注用户列表失败: $e', StackTrace.current);
        }
      } else if (file.name == _userHistoriesJsonName && isSyncHistories.value) {
        try {
          for (var item in jsonData) {
            var history = History.fromJson(item);
            if (DBService.instance.historyBox.containsKey(history.id)) {
              var old = DBService.instance.historyBox.get(history.id);
              //如果本地的更新时间比较新，就不更新
              if (old!.updateTime.isAfter(history.updateTime)) {
                continue;
              }
            }
            await DBService.instance.addOrUpdateHistory(history);
          }
          Log.i('已同步用户观看历史记录');
        } catch (e) {
          Log.e('同步用户观看历史记录失败: $e', StackTrace.current);
        }
      } else if (file.name == _userBlockedWordJsonName &&
          isSyncBlockWord.value) {
        try {
          for (var keyword in jsonData) {
            AppSettingsController.instance.addShieldList(keyword.trim());
          }
          Log.i('已同步用户屏蔽词');
        } catch (e) {
          Log.e('同步用户屏蔽词失败:$e', StackTrace.current);
        }
      } else if (file.name == _userBilibiliAccountJsonName &&
          isSyncBilibiliAccount.value) {
        try {
          var cookie = jsonData['cookie'];
          BiliBiliAccountService.instance.setCookie(cookie);
          BiliBiliAccountService.instance.loadUserInfo();
          Log.i('已同步哔哩哔哩账号');
        } catch (e) {
          Log.e('同步哔哩哔哩账号失败：$e', StackTrace.current);
        }
      } else if (file.name == _userDouyuAccountJsonName &&
          isSyncDouyuAccount.value) {
        try {
          var cookie = (jsonData['cookie'] ?? '').toString();
          if (cookie.isEmpty) {
            Log.i('云端未备份斗鱼账号，跳过');
          } else {
            DouyuAccountService.instance.setCookie(cookie);
            Log.i('已同步斗鱼账号');
          }
        } catch (e) {
          Log.e('同步斗鱼账号失败：$e', StackTrace.current);
        }
      } else if (file.name == _userHuyaAccountJsonName &&
          isSyncHuyaAccount.value) {
        try {
          var cookie = (jsonData['cookie'] ?? '').toString();
          if (cookie.isEmpty) {
            Log.i('云端未备份虎牙账号，跳过');
          } else {
            var service = HuyaAccountService.instance;
            service.setCookie(cookie);
            if (service.logined.value) {
              await service.fetchNickname();
            }
            Log.i('已同步虎牙账号');
          }
        } catch (e) {
          Log.e('同步虎牙账号失败：$e', StackTrace.current);
        }
      } else if (file.name == _userDouyinAccountJsonName &&
          isSyncDouyinAccount.value) {
        try {
          var service = DouyinAccountService.instance;
          var cookie = (jsonData['cookie'] ?? '').toString();
          var loginCookie = (jsonData['loginCookie'] ?? '').toString();
          if (cookie.isEmpty && loginCookie.isEmpty) {
            Log.i('云端未备份抖音账号，跳过');
          } else {
            if (cookie.isNotEmpty) {
              service.setCookie(cookie);
            }
            if (loginCookie.isNotEmpty) {
              service.setLoginCookie(loginCookie);
            }
            Log.i('已同步抖音账号');
          }
        } catch (e) {
          Log.e('同步抖音账号失败：$e', StackTrace.current);
        }
      } else if (file.name == _userSettingsJsonName) {
        try {
          // 合并而不是清空：账号 Cookie / WebDAV 凭据 / 缓存一律跳过
          var settings = Map<String, dynamic>.from(jsonData as Map);
          for (var entry in settings.entries) {
            if (_excludedSettingKeys.contains(entry.key)) {
              continue;
            }
            await LocalStorageService.instance.settingsBox
                .put(entry.key, entry.value);
          }
          Log.i('已同步用户设置');
        } catch (e) {
          Log.e("同步用户设置失败：$e", StackTrace.current);
        }
      } else if (file.name == _userTagsJsonName && isSyncFollows.value) {
        try {
          // 标签功能和关注具有依赖关系，必须同时同步
          // 清空本地标签列表
          await DBService.instance.tagBox.clear();
          for (var item in jsonData) {
            var tag = FollowUserTag.fromJson(item);
            await DBService.instance.tagBox.put(tag.id, tag);
            // 插入之后验证
            var insertedTag = DBService.instance.tagBox.get(tag.id);
            Log.i('Inserted tag: ${insertedTag?.tag}');
          }
          EventBus.instance.emit(Constant.kUpdateFollow, 0);
          Log.i('已同步用户自定义标签');
        } catch (e) {
          Log.e('同步用户自定义标签失败:$e', StackTrace.current);
        }
      } else {
        return;
      }
    } else {
      Log.i('不是正确的文件名');
    }
  }

  // ui控制--密码可见控制
  void changePasswordVisible() {
    passwordVisible.value = !passwordVisible.value;
  }

  void changeIsSyncFollows() {
    isSyncFollows.value = !isSyncFollows.value;
  }

  void changeIsSyncHistories() {
    isSyncHistories.value = !isSyncHistories.value;
  }

  void changeIsSyncBlockWord() {
    isSyncBlockWord.value = !isSyncBlockWord.value;
  }

  void changeIsSyncBilibiliAccount() {
    isSyncBilibiliAccount.value = !isSyncBilibiliAccount.value;
  }

  void changeIsSyncDouyuAccount() {
    isSyncDouyuAccount.value = !isSyncDouyuAccount.value;
  }

  void changeIsSyncHuyaAccount() {
    isSyncHuyaAccount.value = !isSyncHuyaAccount.value;
  }

  void changeIsSyncDouyinAccount() {
    isSyncDouyinAccount.value = !isSyncDouyinAccount.value;
  }
}
