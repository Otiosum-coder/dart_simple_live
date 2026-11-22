import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/multi_live/integration/multi_live_room_link.dart';

void main() {
  final supported = Sites.allSites.keys;
  final cases = <String, (String, String)>{
    'https://live.bilibili.com/12345': ('bilibili', '12345'),
    'https://live.bilibili.com/blanc/54321?share_source=copy': (
      'bilibili',
      '54321'
    ),
    'https://www.douyu.com/3484': ('douyu', '3484'),
    'https://m.douyu.com/room_alias': ('douyu', 'room_alias'),
    'https://www.douyu.com/topic/game?rid=3484&from=share': ('douyu', '3484'),
    'https://www.huya.com/660000': ('huya', '660000'),
    'https://m.huya.com/room_alias': ('huya', 'room_alias'),
    'https://live.douyin.com/123456789': ('douyin', '123456789'),
    'https://webcast.amemv.com/douyin/webcast/reflow/123456789?from=share': (
      'douyin',
      '123456789'
    ),
    '来看看直播 https://live.bilibili.com/12345 。': ('bilibili', '12345'),
  };
  for (final entry in cases.entries) {
    test('existing parser resolves supported room: ${entry.key}', () async {
      final room = await MultiLiveRoomLinkResolver(supportedSiteIds: supported)
          .resolve(entry.key);
      expect(room.siteId, entry.value.$1);
      expect(room.roomId, entry.value.$2);
      expect(room.title, isNull);
    });
  }

  test('only canonical room identity reaches the existing parser', () async {
    String? parsedUrl;
    final room = await MultiLiveRoomLinkResolver(
      supportedSiteIds: supported,
      parse: (url) async {
        parsedUrl = url;
        return ['3484', Sites.allSites['douyu']!];
      },
    ).resolve('https://www.douyu.com/topic/game?rid=3484&token=private#secret');
    expect(parsedUrl, 'https://www.douyu.com/3484');
    expect(room.roomKey, 'douyu:3484');
  });

  for (final short in [
    'https://b23.tv/abc123',
    'https://v.douyin.com/abc123/'
  ]) {
    test('trusted short link resolves: $short', () async {
      final bili = short.contains('b23.tv');
      final room = await MultiLiveRoomLinkResolver(
        supportedSiteIds: supported,
        redirect: (_) async => bili
            ? 'https://live.bilibili.com/12?share=copy'
            : 'https://live.douyin.com/34?share=copy',
      ).resolve(short);
      expect(room.roomKey, bili ? 'bilibili:12' : 'douyin:34');
    });
  }

  final invalid = [
    '',
    '3484',
    '某个主播的房间',
    'live.bilibili.com/123',
    'https://example.com/123',
    'https://live.bilibili.com.attacker.test/123',
    'https://example.com/?next=https://live.bilibili.com/123',
    'https://user:password@live.bilibili.com/123',
    'https://live.bilibili.com:444/123',
    'https://www.bilibili.com/video/BV123',
    'https://live.bilibili.com/',
    'https://live.bilibili.com/123/more',
    'https://live.bilibili.com/video',
    'https://www.douyu.com/directory',
    'https://www.douyu.com/topic/game',
    'https://www.douyu.com/topic/game?rid=123&rid=456',
    'https://www.huya.com/g',
    'https://live.douyin.com/',
    'https://www.douyu.com/123 https://www.huya.com/456',
  ];
  for (final url in invalid) {
    test('reject unsupported or ambiguous input: $url', () async {
      var parseCalls = 0;
      var redirectCalls = 0;
      final resolver = MultiLiveRoomLinkResolver(
        supportedSiteIds: supported,
        parse: (_) async {
          parseCalls++;
          return [];
        },
        redirect: (_) async {
          redirectCalls++;
          return '';
        },
      );
      await expectLater(
          resolver.resolve(url), throwsA(isA<MultiLiveRoomLinkException>()));
      expect(parseCalls, 0);
      expect(redirectCalls, 0);
    });
  }

  test('disabled platform is rejected before parsing', () async {
    await expectLater(
      MultiLiveRoomLinkResolver(supportedSiteIds: ['huya'])
          .resolve('https://live.bilibili.com/12'),
      throwsA(isA<MultiLiveRoomLinkException>()),
    );
  });

  test('short link cannot change platforms or resolve a video page', () async {
    for (final target in [
      'https://www.huya.com/12',
      'https://www.bilibili.com/video/BV123',
      'https://example.com/123',
    ]) {
      await expectLater(
        MultiLiveRoomLinkResolver(
          supportedSiteIds: supported,
          redirect: (_) async => target,
        ).resolve('https://b23.tv/abc'),
        throwsA(isA<MultiLiveRoomLinkException>()),
      );
    }
  });

  test('redirect loops and bounded chains stop without unbounded requests',
      () async {
    var calls = 0;
    final loop = MultiLiveRoomLinkResolver(
      supportedSiteIds: supported,
      redirect: (url) async {
        calls++;
        return url;
      },
    );
    await expectLater(loop.resolve('https://b23.tv/abc'),
        throwsA(isA<MultiLiveRoomLinkException>()));
    expect(calls, lessThanOrEqualTo(2));
    calls = 0;
    final chain = MultiLiveRoomLinkResolver(
      supportedSiteIds: supported,
      redirect: (_) async => 'https://b23.tv/next${calls++}',
    );
    await expectLater(chain.resolve('https://b23.tv/start'),
        throwsA(isA<MultiLiveRoomLinkException>()));
    expect(calls, 4);
  });

  test('timeout surfaces a local error and ignores eventual completion',
      () async {
    final pending = Completer<String>();
    final resolver = MultiLiveRoomLinkResolver(
      supportedSiteIds: supported,
      timeout: const Duration(milliseconds: 5),
      redirect: (_) => pending.future,
    );
    await expectLater(
        resolver.resolve('https://b23.tv/abc'),
        throwsA(isA<MultiLiveRoomLinkException>()
            .having((error) => error.message, 'message', contains('超时'))));
    pending.complete('https://live.bilibili.com/12');
  });

  test('existing parser cannot silently truncate or change identity', () async {
    for (final result in [
      <dynamic>[],
      ['12', Sites.allSites['bilibili']!],
      ['123', Sites.allSites['huya']!],
    ]) {
      await expectLater(
        MultiLiveRoomLinkResolver(
          supportedSiteIds: supported,
          parse: (_) async => result,
        ).resolve('https://live.bilibili.com/123'),
        throwsA(isA<MultiLiveRoomLinkException>()),
      );
    }
  });
}
