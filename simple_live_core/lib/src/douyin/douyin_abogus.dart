import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

// ---------- SM3 ----------
const List<int> _sm3IV = [
  0x7380166f, 0x4914b2b9, 0x172442d7, 0xda8a0600,
  0xa96f30bc, 0x163138aa, 0xe38dee4d, 0xb0fb0e4e,
];

int _rotl(int x, int n) {
  n &= 31;
  x &= 0xFFFFFFFF;
  if (n == 0) return x;
  return ((x << n) | (x >> (32 - n))) & 0xFFFFFFFF;
}

int _tj(int j) => j < 16 ? 0x79CC4519 : 0x7A879D8A;
int _ff(int x, int y, int z, int j) => j < 16 ? (x ^ y ^ z) : ((x & y) | (x & z) | (y & z));
int _gg(int x, int y, int z, int j) => j < 16 ? (x ^ y ^ z) : ((x & y) | ((~x & 0xFFFFFFFF) & z));
int _p0(int x) => x ^ _rotl(x, 9) ^ _rotl(x, 17);
int _p1(int x) => x ^ _rotl(x, 15) ^ _rotl(x, 23);

Uint8List sm3Hash(List<int> msg) {
  final data = <int>[...msg];
  final bitLen = data.length * 8;
  data.add(0x80);
  while (data.length % 64 != 56) {
    data.add(0);
  }
  for (var i = 7; i >= 0; i--) {
    data.add((bitLen >> (8 * i)) & 0xFF);
  }
  var v = List<int>.from(_sm3IV);
  final w = List<int>.filled(68, 0);
  final w1 = List<int>.filled(64, 0);
  for (var off = 0; off < data.length; off += 64) {
    for (var i = 0; i < 16; i++) {
      w[i] = (data[off + i * 4] << 24) |
          (data[off + i * 4 + 1] << 16) |
          (data[off + i * 4 + 2] << 8) |
          data[off + i * 4 + 3];
    }
    for (var j = 16; j < 68; j++) {
      w[j] = (_p1(w[j - 16] ^ w[j - 9] ^ _rotl(w[j - 3], 15)) ^ _rotl(w[j - 13], 7) ^ w[j - 6]) &
          0xFFFFFFFF;
    }
    for (var j = 0; j < 64; j++) {
      w1[j] = (w[j] ^ w[j + 4]) & 0xFFFFFFFF;
    }
    var a = v[0], b = v[1], c = v[2], d = v[3], e = v[4], f = v[5], g = v[6], h = v[7];
    for (var j = 0; j < 64; j++) {
      final ss1 = _rotl((_rotl(a, 12) + e + _rotl(_tj(j), j)) & 0xFFFFFFFF, 7);
      final ss2 = ss1 ^ _rotl(a, 12);
      final tt1 = (_ff(a, b, c, j) + d + ss2 + w1[j]) & 0xFFFFFFFF;
      final tt2 = (_gg(e, f, g, j) + h + ss1 + w[j]) & 0xFFFFFFFF;
      d = c;
      c = _rotl(b, 9);
      b = a;
      a = tt1;
      h = g;
      g = _rotl(f, 19);
      f = e;
      e = _p0(tt2);
    }
    v = [
      (a ^ v[0]) & 0xFFFFFFFF,
      (b ^ v[1]) & 0xFFFFFFFF,
      (c ^ v[2]) & 0xFFFFFFFF,
      (d ^ v[3]) & 0xFFFFFFFF,
      (e ^ v[4]) & 0xFFFFFFFF,
      (f ^ v[5]) & 0xFFFFFFFF,
      (g ^ v[6]) & 0xFFFFFFFF,
      (h ^ v[7]) & 0xFFFFFFFF,
    ];
  }
  final out = Uint8List(32);
  for (var i = 0; i < 8; i++) {
    out[i * 4] = (v[i] >> 24) & 0xFF;
    out[i * 4 + 1] = (v[i] >> 16) & 0xFF;
    out[i * 4 + 2] = (v[i] >> 8) & 0xFF;
    out[i * 4 + 3] = v[i] & 0xFF;
  }
  return out;
}

// ---------- helpers ----------
const String kSalt = 'dhzx';
const String kAlphabetS3 = 'ckdp1h4ZKsUB80/Mfvw36XIgR25+WQAlEi7NLboqYTOPuzmFjJnryx9HVGDaStCe';
const String kAlphabetS4 = 'Dkdpgh2ZmsQB80/MfvV36XI1R45-WUAlEixNLwoqYTOPuzKFjJnry79HbGcaStCe';
const List<int> kGeo = [2560, 1215, 2560, 1392, 2560, 1392, 2560, 1440];
const String kGeoPlatform = 'Win32';
const int kFortnightEpoch = 1721836800000;
const List<int> kA98Perm = [
  34, 44, 56, 61, 73, 29, 70, 45, 35, 49, 38, 66, 51, 68, 28, 48, 64, 47,
  30, 71, 26, 55, 31, 69, 59, 40, 62, 63, 27, 72, 41, 74, 57, 52, 42, 39,
  33, 67, 53, 43, 65, 46, 36, 24, 60, 32, 79, 80, 84, 85,
];

String b64Custom(List<int> data, String alphabet) {
  final out = StringBuffer();
  for (var i = 0; i < data.length; i += 3) {
    final n = (data.length - i) < 3 ? (data.length - i) : 3;
    final b = List<int>.filled(3, 0);
    for (var k = 0; k < n; k++) {
      b[k] = data[i + k] & 0xFF;
    }
    final v = (b[0] << 16) | (b[1] << 8) | b[2];
    final idx = [(v >> 18) & 63, (v >> 12) & 63, (v >> 6) & 63, v & 63];
    if (n == 1) {
      out.write(alphabet[idx[0]] + alphabet[idx[1]] + '==');
    } else if (n == 2) {
      out.write(alphabet[idx[0]] + alphabet[idx[1]] + alphabet[idx[2]] + '=');
    } else {
      out.write(alphabet[idx[0]] + alphabet[idx[1]] + alphabet[idx[2]] + alphabet[idx[3]]);
    }
  }
  return out.toString();
}

List<int> rc4Variant(List<int> key, List<int> data) {
  final sbox = List<int>.generate(256, (x) => 255 - x);
  var j = 0;
  for (var i = 0; i < 256; i++) {
    j = (j * sbox[i] + j + key[i % key.length]) % 256;
    final t = sbox[i];
    sbox[i] = sbox[j];
    sbox[j] = t;
  }
  final out = <int>[];
  var i = 0;
  j = 0;
  for (final b in data) {
    i = (i + 1) % 256;
    j = (j + sbox[i]) % 256;
    final t = sbox[i];
    sbox[i] = sbox[j];
    sbox[j] = t;
    out.add((b ^ sbox[(sbox[i] + sbox[j]) % 256]) & 0xFF);
  }
  return out;
}

List<int> strToBytes(String s) {
  final out = <int>[];
  for (final c in s.codeUnits) {
    if (c & 0xFF00 != 0) {
      out.add((c >> 8) & 0xFF);
      out.add(c & 0xFF);
    } else {
      out.add(c & 0xFF);
    }
  }
  return out;
}

List<int> leBytes(int value, int count) {
  final out = <int>[];
  for (var i = 0; i < count; i++) {
    out.add((value >> (8 * i)) & 0xFF);
  }
  return out;
}

int toInt32(int x) {
  x &= 0xFFFFFFFF;
  return x >= 0x80000000 ? x - 0x100000000 : x;
}

List<int> z146Blend(int c0, int c1, int r0, int r1) {
  return [
    (r0 & 170) | (c0 & 85),
    (r0 & 85) | (c0 & 170),
    (r1 & 170) | (c1 & 85),
    (r1 & 85) | (c1 & 170),
  ];
}

List<int> z148Expand(List<int> arr, int Function() randInt) {
  final out = <int>[];
  var i = 0;
  final n = arr.length;
  while (i < n) {
    if (i + 2 < n) {
      final r = randInt() & 0xFF;
      final b0 = (r & 145) | (arr[i] & 110);
      final b1 = (r & 66) | (arr[i + 1] & 189);
      final b2 = (r & 44) | (arr[i + 2] & 211);
      final b3 = (arr[i] & 145) | (arr[i + 1] & 66) | (arr[i + 2] & 44);
      out.addAll([b0 & 0xFF, b1 & 0xFF, b2 & 0xFF, b3 & 0xFF]);
    } else {
      out.add(arr[i] & 0xFF);
      if (i + 1 < n && arr[i + 1] != 0) {
        out.add(arr[i + 1] & 0xFF);
      }
    }
    i += 3;
  }
  return out;
}

int z144Check(double r, int flagsByte) {
  if (flagsByte & 64 != 0) {
    final v = (r * 109).floor();
    return v + 110 + (v % 2);
  }
  final rr = (r * 240).floor();
  return rr > 109 ? rr + (rr % 2) + 1 : rr;
}

int z145PermissionsBits(double r) {
  final base = (r * 255).floor() & 77;
  return base | 2 | 16 | 32 | 128;
}

int z149CounterBucket(int counter) {
  if (counter > 10745) return 3;
  if (counter > 1283) return 4;
  if (counter > 139) return 5;
  return 6;
}

int _browserOffset(String ua) {
  final l = ua.toLowerCase();
  if (l.contains('chrome') && !l.contains('chromium')) return 0;
  if (l.contains('firefox')) return 40;
  if (l.contains('safari') && !l.contains('chrome')) return 81;
  if (l.contains('edg')) return 125;
  if (l.contains('huawei')) return 170;
  return 210;
}

/// 生成 a_bogus。
/// [query] 为最终 query 字符串（不含 a_bogus），[body] 为最终 body 字符串。
String generateABogus({
  required String query,
  String body = '',
  required String ua,
  required String host,
  int? nowMs,
  Random? random,
}) {
  const Map<String, ({int aid, int pageId, int sdkMinor, int l40, int l41, int l42})> hostCfg = {
    'www.douyin.com': (aid: 6383, pageId: 11881, sdkMinor: 8, l40: 132, l41: 1, l42: 1),
    'login.douyin.com': (aid: 6383, pageId: 6241, sdkMinor: 14, l40: 0, l41: 0, l42: 0),
    'live.douyin.com': (aid: 6383, pageId: 7571, sdkMinor: 12, l40: 0, l41: 0, l42: 0),
    'creator.douyin.com': (aid: 2906, pageId: 33638, sdkMinor: 12, l40: 0, l41: 0, l42: 0),
  };
  final cfg = hostCfg[host] ?? hostCfg['www.douyin.com']!;
  final rng = random ?? Random();
  double nextRand() => rng.nextDouble();
  int rand255() => (nextRand() * 256).floor() & 0xFF;

  final t = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  const sdkVersion = 1;
  final v14 = cfg.sdkMinor;
  final h1 = sm3Hash(sm3Hash(utf8.encode('${query}${kSalt}')));
  final h2 = sm3Hash(sm3Hash(utf8.encode('${body}${kSalt}')));
  final uaKey = [sdkVersion ~/ 256, sdkVersion % 256, v14 % 256];
  final uaCipher = rc4Variant(uaKey, ua.trim().codeUnits);
  final hUa = sm3Hash(utf8.encode(b64Custom(uaCipher, kAlphabetS3)));
  final ink = t - 1;

  final L = <int, dynamic>{};
  L[12] = 3;
  L[14] = t;
  L[23] = [3, 82];
  L[24] = 41;
  L[25] = [1, 0, 1, 0, 1];
  L[26] = ((t - kFortnightEpoch) ~/ 1000 ~/ 60 ~/ 60 ~/ 24 ~/ 14);
  L[27] = z149CounterBucket(4);
  L[28] = 3;
  for (var i = 0; i < 6; i++) {
    L[29 + i] = leBytes(t, 6)[i];
  }
  L[35] = leBytes(sdkVersion, 2)[0];
  L[36] = leBytes(sdkVersion, 2)[1];
  final flags = 1 | (_browserOffsetBrowser(ua) ? 32 : 0);
  L[37] = [0, 0, 0, 0, flags];
  L[38] = flags & 0xFF;
  L[39] = (flags >> 8) & 0xFF;
  L[40] = cfg.l40;
  L[41] = cfg.l41;
  L[42] = cfg.l42;
  L[43] = 0;
  for (var i = 0; i < 4; i++) {
    L[44 + i] = leBytes(v14, 4)[i];
  }
  int escapeDigest(List<int> digest, int idx, int reserved, int fallback, bool force) {
    var v = idx < digest.length ? digest[idx] : fallback;
    while (v == reserved) {
      idx += 1;
      v = idx < digest.length ? digest[idx] : fallback;
    }
    return force ? reserved : v;
  }

  L[48] = h1[9];
  L[49] = h1[18];
  L[51] = escapeDigest(h1, 3, 11, 12, flags & 2 != 0);
  L[52] = h2[10];
  L[53] = h2[19];
  L[55] = escapeDigest(h2, 4, 8, 9, flags & 4 != 0);
  L[56] = hUa[11];
  L[57] = hUa[21];
  L[59] = escapeDigest(hUa, 5, 12, 13, flags & 8 != 0);
  for (var i = 0; i < 6; i++) {
    L[60 + i] = leBytes(ink, 6)[i];
  }
  L[66] = L[12];
  for (var i = 0; i < 4; i++) {
    L[67 + i] = leBytes(cfg.pageId, 4)[i];
  }
  for (var i = 0; i < 4; i++) {
    L[71 + i] = leBytes(cfg.aid, 4)[i];
  }
  final geoStr = '${kGeo.join('|')}|${kGeoPlatform}';
  L[77] = strToBytes(geoStr);
  L[78] = (L[77] as List<int>).length;
  L[79] = leBytes(L[78] as int, 2)[0];
  L[80] = leBytes(L[78] as int, 2)[1];
  L[81] = '${((t + 3) & 255)},';
  L[82] = strToBytes(L[81] as String);
  L[83] = (L[82] as List<int>).length;
  L[84] = leBytes(L[83] as int, 2)[0];
  L[85] = leBytes(L[83] as int, 2)[1];
  final v6 = nextRand() * 65535;
  var a8 = z146Blend((L[25] as List<int>)[0], (L[25] as List<int>)[1], v6.toInt() & 0xFF, (v6.toInt() >> 8) & 0xFF);
  nextRand();
  a8 = a8 +
      z146Blend(
        (L[25] as List<int>)[2],
        (L[25] as List<int>)[3],
        z144Check(nextRand(), flags),
        z145PermissionsBits(nextRand()),
      );
  L[86] = a8;
  var chk = 0;
  final chkFields = [
    24, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 38, 39, 40, 41, 42, 43,
    44, 45, 46, 47, 48, 49, 51, 52, 53, 55, 56, 57, 59, 60, 61, 62, 63, 64,
    65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 79, 80, 84, 85,
  ];
  for (final b in a8) {
    chk ^= b;
  }
  for (final s in chkFields) {
    chk ^= L[s] as int;
  }
  L[87] = toInt32(chk);
  final a98 = <int>[
    for (final s in kA98Perm) L[s] as int,
    ...(L[77] as List<int>),
    ...(L[82] as List<int>),
    L[87] as int,
  ];
  L[88] = a98;
  final hr0 = (nextRand() * 65535).toInt() & 0xFF;
  final off = (nextRand() * 40).toInt() + _browserOffset(ua);
  final l89 = z146Blend(3, 82, hr0, off & 0xFF);
  final plain = <int>[...a8, ...z148Expand(a98, rand255)];
  final cipher = rc4Variant([211], plain);
  return b64Custom([...l89, ...cipher], kAlphabetS4);
}

bool _browserOffsetBrowser(String ua) => ua.toLowerCase().contains('firefox');
