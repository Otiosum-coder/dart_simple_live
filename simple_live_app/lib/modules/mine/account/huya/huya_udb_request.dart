import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 虎牙 UDB 登录接口的「信封」协议（按网页端 2.6 / appId=5002 复刻）
///
/// 浏览器实际发出的 body（抓包对照，逐字段一致）：
/// { uri, version, context, appId, appSign, authId, sdid, lcid, byPass, requestId, data }
///
/// * version = 2.6、appId = 5002：旧版 0/2.5 会被服务端当成过期客户端，
///   扫码确认后一直停在 stage=7、拿不到登录票据
/// * appSign = md5(appId_version_appKey)，静态值
///   md5(5002_2.6_bfd434f70d40433c6b57a781dbcee91a) = 1ce3bf682483d03f146f58232ec10635
/// * context = WB-udb_guiddata-__yamid_new-guid（三个 Cookie 的值）
/// * requestId 与请求头 reqid 相同，同时出现在 referer 的 middle 路径里
class HuyaUdbRequest {
  static const String appId = "5002";
  static const String version = "2.6";
  static const String appKey = "bfd434f70d40433c6b57a781dbcee91a";
  static const String baseUrl = "https://udblgn.huya.com";

  static final String appSign = md5
      .convert(utf8.encode(appId + "_" + version + "_" + appKey))
      .toString();

  /// 组装请求信封
  static Map<String, dynamic> envelope({
    required String uri,
    required Map<String, dynamic> data,
    required String context,
    required String sdid,
    required String requestId,
  }) {
    return {
      "uri": uri,
      "version": version,
      "context": context,
      "appId": appId,
      "appSign": appSign,
      "authId": "",
      "sdid": sdid,
      "lcid": "2052",
      "byPass": "3",
      "requestId": requestId,
      "data": data,
    };
  }

  /// 用户行为埋点参数（网页端格式：furl/curl/user_action，URL 编码后的 JSON）
  static String behavior() {
    return Uri.encodeComponent(jsonEncode({
      "furl": "https://i.huya.com/",
      "curl": "https://i.huya.com/",
      "user_action": <dynamic>[],
    }));
  }

  /// page 参数同样是 URL 编码后的地址
  static String get page => Uri.encodeComponent("https://i.huya.com/");
}
