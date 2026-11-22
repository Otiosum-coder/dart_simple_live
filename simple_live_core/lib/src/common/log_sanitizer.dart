import 'dart:convert';

/// Redacts log copies only; never changes the data sent to a server.
class LogSanitizer {
  static const redacted = '[redacted]';
  static final _normalizeKey = RegExp('[^a-z0-9]');
  static final _urls = RegExp(r'''(?:https?|wss?)://[^\s<>"']+''');
  static final _header = RegExp(
    r'\b(?:set-cookie|cookie|(?:proxy-)?authorization)\s*[:=]\s*[^\r\n]*',
    caseSensitive: false,
  );
  static final _assignment = RegExp(
    r'''(["']?[\w-]+["']?\s*[:=]\s*)("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[^&;\s,}\]]+)''',
  );
  static final _bearer = RegExp(
    r'\bBearer\s+[\w.~+/-]+=*',
    caseSensitive: false,
  );

  static bool _sensitive(String key) {
    final name = key.toLowerCase().replaceAll(_normalizeKey, '');
    return const {
          'cookie',
          'setcookie',
          'authorization',
          'proxyauthorization',
          'sessdata',
          'bilijct',
          'session',
          'sessionid',
          'signature',
          'sign',
          'sig',
          'wrid',
          'password',
          'passwd',
          'pwd',
          'secret',
          'apikey',
          'key',
          'qrcodekey',
          'authkey',
          'refreshkey',
          'jwt',
          'dmjwt',
          'ltk',
          'ltkid',
          'stk',
          'biz',
          'devid',
          'deviceid',
          'buvid',
          'baseinfo',
          'useruniqueid',
          'nonce',
        }.contains(name) ||
        name.contains('token') ||
        name.contains('csrf') ||
        name.endsWith('password') ||
        name.endsWith('secret') ||
        name.endsWith('signature');
  }

  /// Keeps endpoint and non-secret query parameters useful for diagnostics.
  static String url(Object? value) {
    final input = value?.toString() ?? '';
    final uri = Uri.tryParse(input);
    if (uri == null) {
      return redacted;
    }
    try {
      final query = <String, List<String>>{};
      for (final entry in uri.queryParametersAll.entries) {
        query[entry.key] = _sensitive(entry.key)
            ? [redacted]
            : entry.value.map(text).toList();
      }
      return uri
          .replace(
            userInfo: uri.userInfo.isEmpty ? null : 'redacted',
            queryParameters: uri.hasQuery ? query : null,
            fragment: uri.hasFragment ? text(uri.fragment) : null,
          )
          .toString();
    } on FormatException {
      return redacted;
    }
  }

  /// Handles URLs and credential assignments embedded in error messages.
  static String text(Object? value) {
    var output = value?.toString() ?? '';
    output = output.replaceAllMapped(_header, (m) {
      final separator = m[0]!.indexOf(RegExp('[:=]'));
      return '${m[0]!.substring(0, separator + 1)} $redacted';
    });
    output = output.replaceAllMapped(_urls, (m) => url(m[0]));
    output = output.replaceAllMapped(_assignment, (m) {
      final key = m[1]!.split(RegExp('[:=]')).first.trim();
      if (!_sensitive(key) || m[2] == redacted || m[2] == '[redacted') {
        return m[0]!;
      }
      return '${m[1]}$redacted';
    });
    return output.replaceAllMapped(_bearer, (_) => 'Bearer $redacted');
  }

  /// Copies maps/lists and JSON/form strings, preserving status and error data.
  static Object? data(Object? value, {bool hideMessage = false}) {
    if (value is Map) {
      return value.map((key, item) {
        final name = key.toString();
        final isMessage =
            hideMessage &&
            const {
              'msg',
              'message',
              'content',
              'text',
            }.contains(name.toLowerCase());
        return MapEntry(
          name,
          _sensitive(name) || isMessage
              ? redacted
              : data(item, hideMessage: hideMessage),
        );
      });
    }
    if (value is List) {
      return value.map((item) => data(item, hideMessage: hideMessage)).toList();
    }
    if (value is String) {
      final trimmed = value.trimLeft();
      if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
        try {
          return jsonEncode(data(jsonDecode(value), hideMessage: hideMessage));
        } on FormatException {
          // An incomplete JSON response remains useful after text redaction.
        }
      }
      if (RegExp(r'^[^=&\s]+=').hasMatch(value)) {
        try {
          final fields = Uri.splitQueryString(value);
          final safe = data(fields, hideMessage: hideMessage) as Map;
          return Uri(
            queryParameters: safe.map(
              (key, item) => MapEntry(key.toString(), item.toString()),
            ),
          ).query;
        } on FormatException {
          // Not a valid form body; sanitize the original diagnostic text.
        }
      }
      return text(value);
    }
    return value;
  }

  /// Normal response messages are retained; outgoing danmaku text is omitted.
  static Object? requestData(Uri uri, Object? value) {
    return data(value, hideMessage: uri.path == '/msg/send');
  }
}
