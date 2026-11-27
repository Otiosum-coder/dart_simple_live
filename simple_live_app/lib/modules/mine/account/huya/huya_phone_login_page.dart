import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/modules/mine/account/huya/huya_phone_login_controller.dart';
import 'package:simple_live_app/routes/route_path.dart';

/// 虎牙手机号（短信验证码）登录 —— 原生 UI（不使用网页登录弹窗）
class HuyaPhoneLoginPage extends GetView<HuyaPhoneLoginController> {
  const HuyaPhoneLoginPage({super.key});

  static const Color _brand = Color(0xFFFFC100);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text("虎牙手机号登录"),
        actions: [
          TextButton.icon(
            onPressed: () => Get.offNamed(RoutePath.kHuyaQRLogin),
            icon: const Icon(Icons.qr_code_2),
            label: const Text("扫码登录"),
          ),
        ],
      ),
      body: SafeArea(
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => FocusScope.of(context).unfocus(),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            children: [
              Text(
                "手机号登录",
                style: theme.textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                "未注册的手机号验证后将自动创建虎牙账号",
                style:
                    theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
              ),
              const SizedBox(height: 28),
              _phoneField(context),
              const SizedBox(height: 16),
              _codeField(context),
              const SizedBox(height: 24),
              _submitButton(context),
              const SizedBox(height: 16),
              _agreement(context, theme),
              const SizedBox(height: 24),
              _tips(theme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _phoneField(BuildContext context) {
    return TextField(
      controller: controller.phoneCtrl,
      keyboardType: TextInputType.phone,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(11),
      ],
      decoration: InputDecoration(
        prefixIcon: const Padding(
          padding: EdgeInsets.only(left: 16, right: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text("+86", style: TextStyle(fontWeight: FontWeight.w500)),
              SizedBox(width: 8),
              SizedBox(
                height: 20,
                child: VerticalDivider(width: 1, thickness: 1),
              ),
              SizedBox(width: 8),
            ],
          ),
        ),
        prefixIconConstraints: const BoxConstraints(minWidth: 0),
        hintText: "请输入手机号",
        counterText: "",
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Widget _codeField(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller.codeCtrl,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(6),
            ],
            decoration: InputDecoration(
              hintText: "请输入验证码",
              counterText: "",
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 118,
          height: 56,
          child: Obx(() {
            var counting = controller.countdown.value > 0;
            return OutlinedButton(
              onPressed: counting || controller.sending.value
                  ? null
                  : controller.sendCode,
              style: OutlinedButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: controller.sending.value
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      counting ? "${controller.countdown.value}s 后重发" : "获取验证码",
                      style: const TextStyle(fontSize: 13),
                    ),
            );
          }),
        ),
      ],
    );
  }

  Widget _submitButton(BuildContext context) {
    return Obx(() {
      var loading = controller.logining.value;
      return SizedBox(
        height: 50,
        width: double.infinity,
        child: FilledButton(
          onPressed: loading ? null : controller.submit,
          style: FilledButton.styleFrom(
            backgroundColor: _brand,
            foregroundColor: Colors.black,
            disabledBackgroundColor: _brand.withValues(alpha: 0.5),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(25),
            ),
            textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          child: loading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.black45,
                  ),
                )
              : const Text("登录"),
        ),
      );
    });
  }

  Widget _agreement(BuildContext context, ThemeData theme) {
    return Obx(
      () => Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: Checkbox(
              value: controller.agreed.value,
              onChanged: (v) => controller.agreed.value = v ?? false,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: GestureDetector(
              onTap: () => controller.agreed.value = !controller.agreed.value,
              child: Text.rich(
                TextSpan(
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.hintColor),
                  children: const [
                    TextSpan(text: "我已阅读并同意 "),
                    TextSpan(
                      text: "《用户服务协议》",
                      style: TextStyle(color: Color(0xFF3B82F6)),
                    ),
                    TextSpan(text: " 和 "),
                    TextSpan(
                      text: "《隐私政策》",
                      style: TextStyle(color: Color(0xFF3B82F6)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tips(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: theme.hintColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              "收不到验证码？请确认手机号无误，或稍后再试。\n"
              "登录即代表你同意虎牙的用户协议与隐私政策；本登录方式仅移动端提供。",
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.hintColor, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}
