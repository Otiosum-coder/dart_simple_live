import 'dart:convert';
import 'dart:typed_data';

import 'package:simple_live_core/src/danmaku/huya_headline_client.dart';
import 'package:simple_live_core/src/model/tars/huya_user_id.dart';
import 'package:tars_dart/tars/codec/tars_input_stream.dart';
import 'package:tars_dart/tars/codec/tars_output_stream.dart';
import 'package:tars_dart/tars/codec/tars_struct.dart';
import 'package:tars_dart/tars/tup/const.dart';
import 'package:tars_dart/tars/tup/tars_uni_packet.dart';
import 'package:test/test.dart';

// 2026-11-25 11:47:30Z，匿名 POST https://wup.huya.com/，房间 998。
// 服务返回 HTTP 200、WUP code 0，tRsp.panel.entries 为空。
// 此请求由独立 Tars 编码器按官网 GetGameEventMessageBoardReq 构造。
const _acceptedRoom998Request =
    'AAAAcxADLDxAAVYFd3VwdWlmF2dldEhlYWRMaW5lTWVzc2FnZUJvYXJkfQAAPggAAQYEdFJlcR0AADEK'
    'AhGPyvAWACoMFgAmADYVd2ViaDUmMC4xLjAmd2Vic29ja2V0RgBcZgB2AAs8QAoLgR9AmAyoDA==';

void main() {
  test('构造与服务已接受的匿名头条请求逐字节一致', () {
    final bytes = buildHuyaHeadlineRequest(294636272);
    expect(bytes, orderedEquals(base64Decode(_acceptedRoom998Request)));
    expect(ByteData.sublistView(bytes).getUint32(0), bytes.length);

    final packet = TarsUniPacket()..decode(bytes);
    expect(packet.getTarsVersion(), Const.PACKET_TYPE_TUP3);
    expect(packet.servantName, 'wupui');
    expect(packet.funcName, 'getHeadLineMessageBoard');
    expect(packet.requestId, 1);
    expect(packet.getTarsTimeout(), 8000);
    expect(packet.containsKey('tReq'), isTrue);

    final request = packet.getByClass('tReq', _RequestProbe());
    expect(request.presenterUid, 294636272);
    expect(request.offset, isEmpty);
    expect(request.scope, 0);
    expect(request.pageSize, 10);
    expect(request.user.lUid, 0);
    expect(request.user.sGuid, isEmpty);
    expect(request.user.sToken, isEmpty);
    expect(request.user.sHuYaUA, 'webh5&0.1.0&websocket');
    expect(request.user.sCookie, isEmpty);
    expect(request.user.iTokenType, 0);
    expect(request.user.sDeviceInfo, isEmpty);
    expect(request.user.sQIMEI, isEmpty);
  });

  test('主播 UID 按 int64 保留，不截断成频道号或 32 位数', () {
    const presenterUid = 7654321090;
    final packet = TarsUniPacket()
      ..decode(buildHuyaHeadlineRequest(presenterUid));
    final request = packet.getByClass('tReq', _RequestProbe());
    expect(request.presenterUid, presenterUid);
  });

  test('无效主播 UID 在构包时拒绝', () {
    expect(() => buildHuyaHeadlineRequest(0), throwsArgumentError);
    expect(() => buildHuyaHeadlineRequest(-1), throwsArgumentError);
  });
}

/// 独立读取官网的 tag 合同；不导入客户端的私有请求类。
class _RequestProbe extends TarsStruct {
  int presenterUid = 0;
  String offset = '';
  HuyaUserId user = HuyaUserId();
  int scope = -1;
  int pageSize = -1;

  @override
  void readFrom(TarsInputStream input) {
    presenterUid = input.readInt(0, true);
    offset = input.readString(1, true);
    user = input.read(user, 2, true);
    scope = input.readInt(3, true);
    pageSize = input.readInt(4, true);
  }

  @override
  void writeTo(TarsOutputStream output) {
    throw UnsupportedError('RequestProbe is read-only');
  }

  @override
  _RequestProbe deepCopy() => _RequestProbe();

  @override
  void displayAsString(StringBuffer sb, int level) =>
      sb.write('HeadlineRequestProbe');
}
