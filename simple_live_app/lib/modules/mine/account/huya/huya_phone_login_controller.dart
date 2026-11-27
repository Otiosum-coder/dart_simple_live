import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/modules/mine/account/huya/huya_phone_login_api.dart';
import 'package:simple_live_app/modules/mine/account/huya/huya_safe_auth_page.dart';
import 'package:simple_live_app/services/huya_account_service.dart';

/// 虎牙手机号（短信验证码）登录 —— 原生页面控制器
class HuyaPhoneLoginController extends BaseController {
  HuyaPhoneLoginController({HuyaPhoneLoginApi? api})
      : api = api ?? HuyaPhoneLoginApi();

  final HuyaPhoneLoginApi api;

  final TextEditingController phoneCtrl = TextEditingController();
  final TextEditingController codeCtrl = TextEditingController();

  var agreed = false.obs;
  var sending = false.obs;
  var logining = false.obs;
  var countdown = 0.obs;

  String _authId = "";
  Timer? _timer;

  static final RegExp _phoneReg = RegExp(r"^1[3-9]\d{9}$");
  static final RegExp _codeReg = RegExp(r"^\d{4,6}$");

  static bool isValidPhone(String value) => _phoneReg.hasMatch(value.trim());

  static bool isValidCode(String value) => _codeReg.hasMatch(value.trim());

  Future<void> sendCode() async {
    if (sending.value || countdown.value > 0) {
      return;
    }
    var phone = phoneCtrl.text.trim();
    if (!isValidPhone(phone)) {
      SmartDialog.showToast("请输入正确的手机号");
      return;
    }
    sending.value = true;
    try {
      var result = await api.sendCode(phone);
      if (result.needCaptcha && result.safeAuthUrl.isNotEmpty) {
        SmartDialog.showToast("请先完成安全验证");
        var authId = await Get.to<String>(() => HuyaSafeAuthPage(
              url: result.safeAuthUrl,
              userAgent: api.userAgent,
              cookies: api.cookies,
            ));
        if (authId == null || authId.isEmpty) {
          SmartDialog.showToast("未完成安全验证，无法获取验证码");
          return;
        }
        result = await api.sendCode(phone, authcode: authId);
      }
      if (!result.ok) {
        SmartDialog.showToast(
            result.message.isEmpty ? "验证码发送失败，请稍后重试" : result.message);
        return;
      }
      _authId = result.authId;
      _startCountdown();
      SmartDialog.showToast("验证码已发送");
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("验证码发送失败，请检查网络后重试");
    } finally {
      sending.value = false;
    }
  }

  void _startCountdown() {
    _timer?.cancel();
    countdown.value = 60;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (countdown.value <= 1) {
        timer.cancel();
        countdown.value = 0;
      } else {
        countdown.value--;
      }
    });
  }

  Future<void> submit() async {
    if (logining.value) {
      return;
    }
    var phone = phoneCtrl.text.trim();
    var code = codeCtrl.text.trim();
    if (!isValidPhone(phone)) {
      SmartDialog.showToast("请输入正确的手机号");
      return;
    }
    if (!isValidCode(code)) {
      SmartDialog.showToast("请输入收到的短信验证码");
      return;
    }
    if (!agreed.value) {
      SmartDialog.showToast("请先阅读并同意《用户服务协议》和《隐私政策》");
      return;
    }
    logining.value = true;
    try {
      var result = await api.login(
        phone: phone,
        authcode: code,
        authId: _authId,
        sessionData: api.cookies["udb_wession"] ?? "",
      );
      if (!result.ok) {
        SmartDialog.showToast(
            result.message.isEmpty ? "登录失败，请检查验证码" : result.message);
        return;
      }
      await HuyaAccountService.instance.setCookie(result.cookie,
          freshLogin: true, cookieMetadata: result.cookieMetadata);
      if (!HuyaAccountService.instance.logined.value) {
        SmartDialog.showToast("登录态不完整，请改用扫码或 Cookie 登录");
        return;
      }
      SmartDialog.showToast("虎牙登录成功：${HuyaAccountService.instance.name.value}");
      Get.back();
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("登录失败，请稍后重试");
    } finally {
      logining.value = false;
    }
  }

  @override
  void onClose() {
    _timer?.cancel();
    phoneCtrl.dispose();
    codeCtrl.dispose();
    super.onClose();
  }
}
