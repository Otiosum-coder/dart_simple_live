import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 虎牙 UDB 登录接口的「信封」协议
///
/// 虎牙登录接口（udblgn.huya.com）看起来像加密，实际只是统一信封包装：
/// ```
/// POST https://udblgn.huya.com/<path>
/// Content-Type: application/json;charset=UTF-8
/// { url, method, uri, version, context, appId, appSign, authId, sdid,
///   lcid, byPass, requestId, data }
/// ```
///
/// 其中 `appSign` 是**静态值**，不是逐次签名：
/// ```
/// md5("${appId}_${version}_${appKey}")
/// appId = 0, version = 2.5, appKey = bfd434f70d40433c6b57a781dbcee91a
/// => c2131b7a1145437cd97e186a817b5497
/// ```
/// 也就是说既不需要逐次签名，也不需要加密 body，普通 JSON POST 即可。
///
/// `uri` 是接口编号：
/// * `70001` getQrId        获取二维码 id
/// * `70003` tryQrLogin     轮询扫码状态
/// * `70005` scanQrPicNotify 已扫码通知
/// * `70009` cancelLogin    取消登录
///
/// 响应里的 `uri` 会比请求大 1（70002 / 70004），属于正常现象。
class HuyaUdbRequest {
  static const String appId = "0";
  static const String version = "2.5";
  static const String appKey = "bfd434f70d40433c6b57a781dbcee91a";
  static const String baseUrl = "https://udblgn.huya.com";

  static final String appSign =
      md5.convert(utf8.encode("${appId}_${version}_$appKey")).toString();

  /// 组装请求信封
  static Map<String, dynamic> envelope({
    required String url,
    required String uri,
    required Map<String, dynamic> data,
    String context = "WB---",
  }) {
    return {
      "url": url,
      "method": "post",
      "uri": uri,
      "version": version,
      "context": context,
      "appId": appId,
      "appSign": appSign,
      "authId": "",
      "sdid": "",
      "lcid": "2052",
      "byPass": "3",
      "requestId": DateTime.now().millisecondsSinceEpoch.toString(),
      "data": data,
    };
  }

  /// 用户行为埋点参数，虎牙要求带上，格式是 URL 编码后的 JSON
  static String behavior() {
    return Uri.encodeComponent(jsonEncode({
      "user_action": <dynamic>[],
      "enterTime": DateTime.now().millisecondsSinceEpoch,
    }));
  }
}
