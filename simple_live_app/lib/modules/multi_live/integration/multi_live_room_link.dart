import 'dart:async';

import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/mine/parse/parse_controller.dart';

import '../session/multi_live_room_spec.dart';
import '../storage/multi_live_workspace_store.dart';

typedef MultiLiveLinkParser = Future<List<dynamic>> Function(String url);
typedef MultiLiveLinkRedirect = Future<String> Function(String url);

class MultiLiveRoomLinkException implements Exception {
  const MultiLiveRoomLinkException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Validates the URL boundary before using the application's existing parser.
/// Only the resulting platform and room ID leave this resolver.
class MultiLiveRoomLinkResolver {
  MultiLiveRoomLinkResolver({
    required Iterable<String> supportedSiteIds,
    MultiLiveLinkParser? parse,
    MultiLiveLinkRedirect? redirect,
    this.timeout = const Duration(seconds: 20),
  })  : _supportedSiteIds = supportedSiteIds.toSet(),
        _parse = parse ?? _parseExisting,
        _redirect = redirect ?? _redirectExisting;

  final Set<String> _supportedSiteIds;
  final MultiLiveLinkParser _parse;
  final MultiLiveLinkRedirect _redirect;
  final Duration timeout;

  Future<MultiLiveRoomSpec> resolve(String text) => _resolve(text).timeout(
        timeout,
        onTimeout: () =>
            throw const MultiLiveRoomLinkException('解析超时，请检查网络后重试'),
      );

  Future<MultiLiveRoomSpec> _resolve(String text) async {
    if (text.trim().isEmpty) {
      throw const MultiLiveRoomLinkException('请粘贴直播间链接');
    }
    final matches = _urlPattern.allMatches(text).toList();
    if (text.length > 4096 || matches.length != 1) {
      throw const MultiLiveRoomLinkException('请输入一个完整的 http 或 https 直播间链接');
    }
    var uri = _readUri(
        matches.single.group(0)!.replaceFirst(RegExp(r'[)\]}>]+$'), ''));
    final expectedSite = _siteId(uri.host);
    if (expectedSite == null || !_supportedSiteIds.contains(expectedSite)) {
      throw const MultiLiveRoomLinkException('暂不支持此平台，请使用已支持平台的直播间链接');
    }

    final visited = <String>{};
    for (var hop = 0; _isShortHost(uri.host); hop++) {
      if (hop >= 4 ||
          !visited.add(uri.toString()) ||
          uri.pathSegments.where((part) => part.isNotEmpty).length != 1 ||
          !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(uri.pathSegments
              .firstWhere((part) => part.isNotEmpty, orElse: () => ''))) {
        throw const MultiLiveRoomLinkException('无法解析此短链接，请复制直播间页面链接');
      }
      // Share parameters are not needed to resolve a short URL.
      final location = await _redirect(
          Uri(scheme: uri.scheme, host: uri.host, path: uri.path).toString());
      if (location.isEmpty) {
        throw const MultiLiveRoomLinkException('无法解析此短链接，请复制直播间页面链接');
      }
      uri = _readUri(uri.resolve(location).toString());
      if (_siteId(uri.host) != expectedSite) {
        throw const MultiLiveRoomLinkException('该链接没有指向同平台的直播间');
      }
    }

    final roomId = _directRoomId(uri, expectedSite);
    if (roomId == null || !isMultiLiveRoomId(roomId)) {
      throw const MultiLiveRoomLinkException('链接中没有可识别的直播间，请复制直播间页面链接');
    }
    // Normalize to the direct URLs understood by ParseController.parse. This
    // prevents substring host matches, query credentials and truncated IDs.
    final canonical = switch (expectedSite) {
      Constant.kBiliBili => 'https://live.bilibili.com/$roomId',
      Constant.kDouyu => 'https://www.douyu.com/$roomId',
      Constant.kHuya => 'https://www.huya.com/$roomId',
      _ => 'https://live.douyin.com/$roomId',
    };
    final parsed = await _parse(canonical);
    if (parsed.length != 2 ||
        parsed[0] != roomId ||
        parsed[1] is! Site ||
        (parsed[1] as Site).id != expectedSite) {
      throw const MultiLiveRoomLinkException('无法识别直播间，请检查链接后重试');
    }
    return MultiLiveRoomSpec(siteId: expectedSite, roomId: roomId);
  }

  static final _urlPattern =
      RegExp(r'''https?://[^\s<>"'，。；！？]+''', caseSensitive: false);

  static Uri _readUri(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme.toLowerCase()) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && uri.port != (uri.scheme == 'https' ? 443 : 80))) {
      throw const MultiLiveRoomLinkException('请输入有效的直播间网页链接');
    }
    return uri.replace(
        scheme: uri.scheme.toLowerCase(), host: uri.host.toLowerCase());
  }

  static String? _siteId(String host) => switch (host) {
        'live.bilibili.com' || 'b23.tv' => Constant.kBiliBili,
        'douyu.com' || 'www.douyu.com' || 'm.douyu.com' => Constant.kDouyu,
        'huya.com' || 'www.huya.com' || 'm.huya.com' => Constant.kHuya,
        'live.douyin.com' ||
        'v.douyin.com' ||
        'webcast.amemv.com' =>
          Constant.kDouyin,
        _ => null,
      };

  static bool _isShortHost(String host) =>
      host == 'b23.tv' || host == 'v.douyin.com';

  static String? _directRoomId(Uri uri, String site) {
    final parts = uri.pathSegments.where((part) => part.isNotEmpty).toList();
    final single = parts.length == 1 ? parts.single : null;
    if (site == Constant.kBiliBili) {
      final id =
          parts.length == 2 && parts.first == 'blanc' ? parts.last : single;
      return id != null && RegExp(r'^[0-9]+$').hasMatch(id) ? id : null;
    }
    if (site == Constant.kDouyu &&
        parts.length == 2 &&
        parts.first == 'topic') {
      final ids = uri.queryParametersAll['rid'];
      return ids?.length == 1 && RegExp(r'^[0-9]+$').hasMatch(ids!.single)
          ? ids.single
          : null;
    }
    if (site == Constant.kDouyin && uri.host == 'webcast.amemv.com') {
      return parts.length == 4 &&
              parts[0] == 'douyin' &&
              parts[1] == 'webcast' &&
              parts[2] == 'reflow' &&
              RegExp(r'^[0-9]+$').hasMatch(parts[3])
          ? parts[3]
          : null;
    }
    if (single == null || !RegExp(r'^[A-Za-z0-9_]{1,128}$').hasMatch(single)) {
      return null;
    }
    const reserved = {
      'topic',
      'directory',
      'search',
      'category',
      'member',
      'api',
      'g',
      'l',
      'live',
      'room',
      'about',
      'download',
      'home',
      'betard',
    };
    return reserved.contains(single.toLowerCase()) ? null : single;
  }

  static Future<T> _useExisting<T>(
      Future<T> Function(ParseController) use) async {
    final parser = ParseController();
    try {
      return await use(parser);
    } finally {
      parser.roomJumpToController.dispose();
      parser.getUrlController.dispose();
    }
  }

  static Future<List<dynamic>> _parseExisting(String url) =>
      _useExisting((parser) => parser.parse(url));

  static Future<String> _redirectExisting(String url) =>
      _useExisting((parser) => parser.getLocation(url));
}
