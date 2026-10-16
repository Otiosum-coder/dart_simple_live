import 'dart:convert';

T? asT<T>(dynamic value) {
  if (value is T) {
    return value;
  }
  return null;
}

class SyncClientInfoModel {
  SyncClientInfoModel({
    required this.name,
    required this.version,
    required this.address,
    required this.port,
    required this.type,
    this.followCount = 0,
  });

  factory SyncClientInfoModel.fromJson(Map<String, dynamic> json) =>
      SyncClientInfoModel(
        type: asT<String>(json['type'])!,
        name: asT<String>(json['name'])!,
        version: asT<String>(json['version'])!,
        address: asT<String>(json['address'])!,
        port: asT<int>(json['port'])!,
        // 对方关注数量：用于同步方向判断（旧版本不带这个字段，默认 0）
        followCount: asT<int>(json['followCount']) ?? 0,
      );
  String type;
  String name;
  String version;
  String address;
  int port;

  /// 对方设备上的关注数量
  int followCount;

  @override
  String toString() {
    return jsonEncode(this);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'version': version,
        'address': address,
        'port': port,
        'type': type,
        'followCount': followCount,
      };
}
