import 'package:tars_dart/tars/codec/tars_input_stream.dart';
import 'package:tars_dart/tars/codec/tars_output_stream.dart';
import 'package:tars_dart/tars/codec/tars_struct.dart';

import 'huya_user_id.dart';

/// 网页游客表情目录：wupui.getExpressionEmoticonPackage。
class HuyaEmoticonRequest extends TarsStruct {
  HuyaUserId user = HuyaUserId()..sHuYaUA = 'webh5&0.1.0&websocket';
  int presenterId = 0;
  int gameId = 0;
  int sceneType = 1;

  @override
  void writeTo(TarsOutputStream os) {
    os.write(user, 0);
    os.write(presenterId, 1);
    os.write(gameId, 2);
    os.write(sceneType, 3);
  }

  @override
  void readFrom(TarsInputStream input) {
    user = input.read(user, 0, true);
    presenterId = input.readInt(1, false);
    gameId = input.readInt(2, false);
    sceneType = input.readInt(3, false);
  }

  @override
  HuyaEmoticonRequest deepCopy() => HuyaEmoticonRequest()
    ..user = (user.deepCopy() as HuyaUserId)
    ..presenterId = presenterId
    ..gameId = gameId
    ..sceneType = sceneType;

  @override
  void displayAsString(StringBuffer sb, int level) =>
      sb.write('HuyaEmoticonRequest');
}

/// 仅解码接收显示所需的目录，不使用发送权限字段筛选表情。
class HuyaEmoticonResponse extends TarsStruct {
  String message = '';
  List<HuyaEmoticonPackage> packages = [];

  @override
  void readFrom(TarsInputStream input) {
    message = input.readString(0, false);
    packages = input.readList<HuyaEmoticonPackage>(
      [HuyaEmoticonPackage()],
      1,
      true,
    );
  }

  @override
  void writeTo(TarsOutputStream os) {
    os.write(message, 0);
    os.write(packages, 1);
  }

  @override
  HuyaEmoticonResponse deepCopy() => HuyaEmoticonResponse()
    ..message = message
    ..packages = packages.map((item) => item.deepCopy()).toList();

  @override
  void displayAsString(StringBuffer sb, int level) => sb.write(message);
}

class HuyaEmoticonPackage extends TarsStruct {
  String id = '';
  String name = '';
  List<HuyaEmoticonItem> items = [];
  List<HuyaEmoticonItem> unavailableItems = [];

  @override
  void readFrom(TarsInputStream input) {
    id = input.readString(0, false);
    name = input.readString(1, false);
    items = input.readList<HuyaEmoticonItem>([HuyaEmoticonItem()], 4, false);
    unavailableItems = input.readList<HuyaEmoticonItem>(
      [HuyaEmoticonItem()],
      5,
      false,
    );
  }

  @override
  void writeTo(TarsOutputStream os) {
    os.write(id, 0);
    os.write(name, 1);
    os.write(items, 4);
    os.write(unavailableItems, 5);
  }

  @override
  HuyaEmoticonPackage deepCopy() => HuyaEmoticonPackage()
    ..id = id
    ..name = name
    ..items = items.map((item) => item.deepCopy()).toList()
    ..unavailableItems = unavailableItems
        .map((item) => item.deepCopy())
        .toList();

  @override
  void displayAsString(StringBuffer sb, int level) => sb.write(name);
}

/// sUrl 是普通单图/静态预览；不读取 sFlexiUrl 等多帧长图字段。
class HuyaEmoticonItem extends TarsStruct {
  String name = '';
  String escape = '';
  String url = '';

  @override
  void readFrom(TarsInputStream input) {
    name = input.readString(1, false);
    escape = input.readString(2, false);
    url = input.readString(3, false);
  }

  @override
  void writeTo(TarsOutputStream os) {
    os.write(name, 1);
    os.write(escape, 2);
    os.write(url, 3);
  }

  @override
  HuyaEmoticonItem deepCopy() => HuyaEmoticonItem()
    ..name = name
    ..escape = escape
    ..url = url;

  @override
  void displayAsString(StringBuffer sb, int level) => sb.write(name);
}
