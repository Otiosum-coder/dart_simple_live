import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class DouyinAccountService extends GetxService {
  static DouyinAccountService get instance =>
      Get.find<DouyinAccountService>();

  var cookie = "";
  var hasCookie = false.obs;

  @override
  void onInit() {
    cookie = LocalStorageService.instance
        .getValue(LocalStorageService.kDouyinCookie, "");
    hasCookie.value = cookie.isNotEmpty;
    setSite();
    super.onInit();
  }

  void setSite() {
    var site = (Sites.allSites[Constant.kDouyin]!.liveSite as DouyinSite);
    site.cookie = cookie;
  }

  void setCookie(String rawCookie) {
    // 归一化：只填了 ttwid 的值就补上字段名；填的是完整 Cookie（含 = 或 ;）就原样保存
    var value = rawCookie.trim();
    if (value.isNotEmpty && !value.contains("=")) {
      value = "ttwid=$value";
    }
    this.cookie = value;
    LocalStorageService.instance
        .setValue(LocalStorageService.kDouyinCookie, value);
    hasCookie.value = value.isNotEmpty;
    setSite();
  }

  void clearCookie() {
    cookie = "";
    LocalStorageService.instance
        .setValue(LocalStorageService.kDouyinCookie, "");
    hasCookie.value = false;
    setSite();
  }
}
