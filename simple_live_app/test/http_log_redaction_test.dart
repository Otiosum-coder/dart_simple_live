import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/requests/custom_log_interceptor.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/custom_interceptor.dart';

class _LogTestAdapter implements HttpClientAdapter {
  _LogTestAdapter(this.statusCode);

  final int statusCode;
  RequestOptions? received;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    received = options;
    return ResponseBody.fromString(
      jsonEncode({
        'code': statusCode == 200 ? 0 : -101,
        'message': 'diagnostic reason',
        'access_token': 'response-body-secret',
      }),
      statusCode,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
        'set-cookie': ['SESSDATA=response-cookie-secret; HttpOnly'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late bool oldEnabled;
  late RequestLogType oldMode;
  late Function(Level, String)? oldSink;
  late Logger oldLogger;
  final coreMessages = <String>[];

  setUp(() {
    oldEnabled = CoreLog.enableLog;
    oldMode = CoreLog.requestLogType;
    oldSink = CoreLog.onPrintLog;
    oldLogger = Log.logger;
    Log.logger = Logger(level: Level.off);
    Log.debugLogs.clear();
    coreMessages.clear();
    CoreLog.enableLog = true;
    CoreLog.requestLogType = RequestLogType.all;
    CoreLog.onPrintLog = (_, message) => coreMessages.add(message);
  });

  tearDown(() {
    CoreLog.enableLog = oldEnabled;
    CoreLog.requestLogType = oldMode;
    CoreLog.onPrintLog = oldSink;
    Log.logger = oldLogger;
    Log.debugLogs.clear();
  });

  for (final useCore in [false, true]) {
    for (final status in [200, 403]) {
      test('HTTP log redaction core=$useCore status=$status', () async {
        final adapter = _LogTestAdapter(status);
        final dio = Dio()..httpClientAdapter = adapter;
        dio.interceptors.add(
          useCore ? CustomInterceptor() : CustomLogInterceptor(),
        );
        final payload = {
          'msg': 'private-danmaku-message',
          'csrf': 'csrf-secret'
        };
        final request = dio.post<dynamic>(
          'https://example.com/msg/send?room_id=123&signature=query-secret',
          data: payload,
          options: Options(headers: {
            'Cookie': 'SESSDATA=request-cookie-secret',
            'Authorization': 'Bearer bearer-secret',
          }),
        );
        if (status == 200) {
          await request;
        } else {
          await expectLater(request, throwsA(isA<DioException>()));
        }
        final output = [
          ...coreMessages,
          ...Log.debugLogs.map((entry) => entry.content),
        ].join('\n');
        expect(output, isNotEmpty);
        expect(output, contains('example.com/msg/send'));
        expect(output, contains(status.toString()));
        expect(output, contains('diagnostic reason'));
        for (final secret in [
          'request-cookie-secret',
          'bearer-secret',
          'csrf-secret',
          'query-secret',
          'response-cookie-secret',
          'response-body-secret',
          'private-danmaku-message',
        ]) {
          expect(output, isNot(contains(secret)), reason: secret);
        }
        expect(payload['msg'], 'private-danmaku-message');
        expect(payload['csrf'], 'csrf-secret');
        expect(adapter.received!.headers['Cookie'],
            'SESSDATA=request-cookie-secret');
        expect(
            adapter.received!.uri.queryParameters['signature'], 'query-secret');
        dio.close(force: true);
      });
    }
  }
}
