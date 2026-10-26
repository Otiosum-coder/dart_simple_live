// 临时诊断脚本：按 tars_dart 的语义手工遍历虎牙 WS 帧字段
// 用法：dart tool/huya_tars_dump.dart <base64文件>
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:tars_dart/tars/codec/tars_input_stream.dart';

String hex(Uint8List b, [int limit = 40]) {
  var n = b.length < limit ? b.length : limit;
  return b
      .sublist(0, n)
      .map((e) => e.toRadixString(16).padLeft(2, "0"))
      .join(" ");
}

String printable(Uint8List b) {
  var text = utf8.decode(b, allowMalformed: true);
  return text.replaceAll(RegExp(r"[^\x20-\x7e\u4e00-\u9fa5]"), ".");
}

void dump(Uint8List data, String label, {int depth = 0}) {
  print("${"  " * depth}--- $label len=${data.length} head=${hex(data, 24)}");
  var s = TarsInputStream(data);
  var guard = 0;
  while (s.br.position < data.length && guard++ < 60) {
    var start = s.br.position;
    var hd = HeadData();
    try {
      s.readHead(hd);
    } catch (e) {
      print("${"  " * depth}  <readHead failed at $start>");
      break;
    }
    var pad = "  " * (depth + 1);
    switch (hd.type) {
      case 0:
        print("$pad tag=${hd.tag} BYTE ${s.br.readInt(1)}");
        break;
      case 1:
        print("$pad tag=${hd.tag} SHORT ${s.br.readInt(2)}");
        break;
      case 2:
        print("$pad tag=${hd.tag} INT ${s.br.readInt(4)}");
        break;
      case 3:
        print("$pad tag=${hd.tag} LONG ${s.br.readInt(8)}");
        break;
      case 6:
        var len = s.br.readInt(1);
        var str = utf8.decode(s.br.readBytes(len), allowMalformed: true);
        print("$pad tag=${hd.tag} STRING1($len) \"$str\"");
        break;
      case 7:
        var len = s.br.readInt(4);
        var str = utf8.decode(s.br.readBytes(len), allowMalformed: true);
        print("$pad tag=${hd.tag} STRING4($len) \"$str\"");
        break;
      case 12:
        print("$pad tag=${hd.tag} ZERO");
        break;
      case 13:
        var hh = HeadData();
        s.readHead(hh);
        var size = 0;
        if (hh.type == 0) {
          var h2 = HeadData();
          s.readHead(h2);
          if (h2.type == 0) {
            size = s.br.readInt(1);
          } else if (h2.type == 1) {
            size = s.br.readInt(2);
          } else if (h2.type == 2) {
            size = s.br.readInt(4);
          }
        }
        var bytes = s.br.readBytes(size);
        print("$pad tag=${hd.tag} BYTES($size) ${hex(bytes, 32)}");
        if (depth < 4 && size > 6) {
          try {
            dump(bytes, "tag${hd.tag}-bytes", depth: depth + 1);
          } catch (e) {
            print("$pad    text: ${printable(bytes).substring(0, printable(bytes).length.clamp(0, 160))}");
          }
        }
        break;
      case 10:
        print("$pad tag=${hd.tag} STRUCT_BEGIN");
        break;
      case 11:
        print("$pad tag=${hd.tag} STRUCT_END");
        break;
      default:
        print("$pad tag=${hd.tag} <unhandled type ${hd.type}>");
        break;
    }
    if (s.br.position <= start) {
      print("$pad <no progress, stop>");
      break;
    }
  }
}

void main(List<String> argv) {
  var b64 = File(argv[0]).readAsStringSync().trim();
  var u8 = Uint8List.fromList(base64.decode(b64));
  dump(u8, "frame");
  print("");
  var s = TarsInputStream(u8);
  var cmdId = s.read(0, 0, false);
  var payload = s.readBytes(1, false);
  print("== cmdId = $cmdId   payload=${payload.length}B");
  // payload 前 4 字节是自身的长度前缀（大端），真正的结构在后面
  var inner = payload;
  if (payload.length > 4) {
    var declared = (payload[0] << 24) | (payload[1] << 16) | (payload[2] << 8) | payload[3];
    if (declared == payload.length) {
      inner = Uint8List.fromList(payload.sublist(4));
      print("   payload 前缀长度=$declared，跳过 4 字节");
    }
  }
  print("");
  dump(Uint8List.fromList(inner), "payload-struct");
}
