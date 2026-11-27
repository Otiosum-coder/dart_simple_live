import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:simple_live_core/src/model/tars/huya_user_id.dart';
import 'package:tars_dart/tars/codec/tars_input_stream.dart';
import 'package:tars_dart/tars/codec/tars_output_stream.dart';
import 'package:tars_dart/tars/codec/tars_struct.dart';
import 'package:tars_dart/tars/tup/const.dart';
import 'package:tars_dart/tars/tup/tars_uni_packet.dart';

/// 返回完整 WUP 响应，由接收端与实时头条共用解码和去重逻辑。
typedef HuyaHeadlineLoader = Future<List<int>> Function(int presenterUid);

/// 游客只读获取主播的当前头条面板，不共享账号 Cookie 或全局 HTTP 客户端。
Future<List<int>> fetchHuyaHeadlines(int presenterUid) async {
  final bytes = buildHuyaHeadlineRequest(presenterUid);
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 5),
      sendTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 8),
    ),
  );
  try {
    final response = await dio.post<List<int>>(
      'https://wup.huya.com/',
      data: Stream<List<int>>.value(bytes),
      options: Options(
        responseType: ResponseType.bytes,
        contentType: 'application/octet-stream',
        headers: {'content-length': bytes.length},
      ),
    );
    final data = response.data;
    if (data == null || data.length < 4) {
      throw const FormatException('虎牙头条 WUP 响应为空');
    }
    return data;
  } finally {
    dio.close(force: true);
  }
}

/// 官网 Messageboard 以 TTA.lp（主播 UID）调用 wupui.getHeadLineMessageBoard。
///
/// presenterUid 对应 tProfileInfo.lUid，不能使用 YYID、房间号或频道 ID。
/// 请求字段来自当前网页 GameEventMessageBoardServant；匿名请求已实测可用。
Uint8List buildHuyaHeadlineRequest(int presenterUid) {
  if (presenterUid <= 0) {
    throw ArgumentError.value(presenterUid, 'presenterUid', '必须是有效的主播 UID');
  }
  final packet = TarsUniPacket()
    ..setTarsVersion(Const.PACKET_TYPE_TUP3)
    ..setTarsTimeout(8000)
    ..requestId = 1
    ..servantName = 'wupui'
    ..funcName = 'getHeadLineMessageBoard';
  packet.put('tReq', _HuyaHeadlineRequest(presenterUid));
  return packet.encode();
}

class _HuyaHeadlineRequest extends TarsStruct {
  _HuyaHeadlineRequest(this.presenterUid);

  final int presenterUid;

  @override
  void writeTo(TarsOutputStream output) {
    final user = HuyaUserId()..sHuYaUA = 'webh5&0.1.0&websocket';
    output.write(presenterUid, 0);
    output.write('', 1);
    output.write(user, 2);
    output.write(0, 3);
    output.write(10, 4);
  }

  @override
  void readFrom(TarsInputStream input) {
    throw UnsupportedError('HuyaHeadlineRequest is write-only');
  }

  @override
  _HuyaHeadlineRequest deepCopy() => _HuyaHeadlineRequest(presenterUid);

  @override
  void displayAsString(StringBuffer sb, int level) =>
      sb.write('HuyaHeadlineRequest($presenterUid)');
}
