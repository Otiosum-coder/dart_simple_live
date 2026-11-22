import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/http_client.dart' as core_http;

const _roomId = '1369397';
const _showTime = '1795162394';

class _DouyuRoomAdapter implements HttpClientAdapter {
  _DouyuRoomAdapter(this.room,
      {this.htmlResponse = false, this.statusCode = 200});

  final Map<String, dynamic> room;
  final bool htmlResponse;
  final int statusCode;
  final requests = <String>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options.uri.path);
    final isBetard = options.uri.path == '/betard/$_roomId';
    Object body;
    var code = 200;
    if (isBetard) {
      body = {'room': room};
      code = statusCode;
    } else if (options.uri.path == '/swf_api/h5room/$_roomId') {
      body = {
        'data': {'show_time': _showTime}
      };
    } else if (options.uri.path == '/swf_api/homeH5Enc') {
      body = {
        'data': {
          'room$_roomId':
              "function ub98484234() { return 'fixture-signature'; }",
        },
      };
    } else {
      throw StateError(
          'Unexpected isolated fixture request: ${options.uri.path}');
    }
    return ResponseBody.fromString(jsonEncode(body), code, headers: {
      Headers.contentTypeHeader: [
        htmlResponse && isBetard ? 'text/html' : 'application/json',
      ],
    });
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _room(Object? showStatus, Object? videoLoop) => {
      'room_id': int.parse(_roomId),
      'show_status': showStatus,
      'videoLoop': videoLoop,
      'show_time': int.parse(_showTime),
      'end_time': '1795203662',
      'room_pic': 'https://example.invalid/cover.jpg',
      'room_biz_all': {'hot': 123},
      'room_name': 'fixture-room',
      'owner_name': 'fixture-anchor',
      'owner_avatar': 'https://example.invalid/avatar.jpg',
      'show_details': 'fixture-description',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Dio originalDio;
  late bool originalLogging;
  late Dio dio;
  late DouyuSite site;

  setUp(() {
    originalDio = core_http.HttpClient.instance.dio;
    originalLogging = CoreLog.enableLog;
    CoreLog.enableLog = false;
    dio = Dio();
    core_http.HttpClient.instance.dio = dio;
    site = DouyuSite();
  });

  tearDown(() {
    core_http.HttpClient.instance.dio = originalDio;
    CoreLog.enableLog = originalLogging;
    dio.close(force: true);
  });

  for (final textFields in [false, true]) {
    for (final showStatus in [0, 1, 2]) {
      for (final videoLoop in [0, 1]) {
        test(
            'all room APIs agree for status=$showStatus loop=$videoLoop text=$textFields',
            () async {
          final adapter = _DouyuRoomAdapter(
            _room(textFields ? '$showStatus' : showStatus,
                textFields ? '$videoLoop' : videoLoop),
            htmlResponse: textFields,
          );
          dio.httpClientAdapter = adapter;
          final expectedLive = showStatus == 1 && videoLoop == 0;

          final status = await site.getRoomStatus(roomId: _roomId);
          expect(status.querySucceeded, isTrue);
          expect(status.roomNotFound, isFalse);
          expect(status.isLive, expectedLive);
          expect(status.roomId, _roomId);
          expect(status.startTime, expectedLive ? _showTime : null);
          expect(status.lastLiveTime, expectedLive ? null : _showTime);
          expect(adapter.requests, ['/betard/$_roomId']);

          expect(await site.getLiveStatus(roomId: _roomId), expectedLive);
          final detail = await site.getRoomDetail(roomId: _roomId);
          expect(detail.status, expectedLive);
          expect(detail.isRecord, videoLoop == 1);
          expect(detail.roomNotFound, isFalse);
          expect(detail.roomId, _roomId);
          expect(detail.showTime, expectedLive ? _showTime : null);
          expect(detail.lastLiveTime, expectedLive ? null : _showTime);
          expect(detail.data, 'fixture-signature');
          expect(adapter.requests.where((p) => p == '/betard/$_roomId'),
              hasLength(3));
        });
      }
    }
  }

  final invalidStates = <String, Map<String, dynamic>>{
    'missing live status': {'videoLoop': 0},
    'null live status': {'show_status': null, 'videoLoop': 0},
    'unknown live status': {'show_status': 3, 'videoLoop': 0},
    'negative live status': {'show_status': -1, 'videoLoop': 0},
    'fractional live status': {'show_status': 1.5, 'videoLoop': 0},
    'boolean live status': {'show_status': true, 'videoLoop': 0},
    'malformed live status': {'show_status': 'online', 'videoLoop': 0},
    'missing loop status': {'show_status': 1},
    'null loop status': {'show_status': 2, 'videoLoop': null},
    'unknown loop status': {'show_status': 1, 'videoLoop': 2},
    'boolean loop status': {'show_status': 1, 'videoLoop': false},
    'malformed loop status': {'show_status': 1, 'videoLoop': 'no'},
  };
  for (final entry in invalidStates.entries) {
    test('${entry.key} stays a failed query instead of offline', () async {
      final adapter = _DouyuRoomAdapter(entry.value);
      dio.httpClientAdapter = adapter;

      final status = await site.getRoomStatus(roomId: _roomId);
      expect(status.querySucceeded, isFalse);
      expect(status.roomNotFound, isFalse);
      expect(status.isLive, isFalse);
      expect(status.startTime, isNull);
      expect(status.lastLiveTime, isNull);
      await expectLater(
          site.getLiveStatus(roomId: _roomId), throwsA(isA<FormatException>()));
      await expectLater(
          site.getRoomDetail(roomId: _roomId), throwsA(isA<FormatException>()));
      expect(adapter.requests, everyElement('/betard/$_roomId'));
    });
  }

  for (final statusCode in [403, 404, 500]) {
    test('HTTP $statusCode keeps not-found separate from query failure',
        () async {
      final adapter = _DouyuRoomAdapter(_room(2, 0), statusCode: statusCode);
      dio.httpClientAdapter = adapter;
      final status = await site.getRoomStatus(roomId: _roomId);
      expect(status.roomNotFound, statusCode == 404);
      expect(status.querySucceeded, statusCode == 404);
      expect(status.isLive, isFalse);
      expect(status.startTime, isNull);
      expect(status.lastLiveTime, isNull);
      await expectLater(
          site.getLiveStatus(roomId: _roomId), throwsA(isA<CoreError>()));
      if (statusCode == 404) {
        final detail = await site.getRoomDetail(roomId: _roomId);
        expect(detail.roomNotFound, isTrue);
        expect(detail.status, isFalse);
      } else {
        await expectLater(
            site.getRoomDetail(roomId: _roomId), throwsA(isA<CoreError>()));
      }
      expect(adapter.requests, everyElement('/betard/$_roomId'));
    });
  }
}
