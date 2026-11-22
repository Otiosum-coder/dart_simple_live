import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/widgets/net_image.dart';
import 'package:simple_live_core/simple_live_core.dart';

import 'multi_live_quick_danmaku.dart';

class MultiLiveChat extends StatelessWidget {
  const MultiLiveChat({super.key, required this.room, required this.send});
  final LiveRoomController room;
  final Future<String?> Function(String) send;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final keyboard = MediaQuery.viewInsetsOf(context).bottom;
          final bottom = keyboard
              .clamp(
                  0.0, (constraints.maxHeight - 56).clamp(0.0, double.infinity))
              .toDouble();
          return Padding(
            padding: EdgeInsets.only(bottom: bottom),
            child: Column(children: [
              Expanded(child: Obx(() {
                final messages = room.messages.toList();
                if (messages.isEmpty) {
                  return const Center(child: Text('暂无聊天消息'));
                }
                return ListView.builder(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  reverse: true,
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final message = messages[messages.length - index - 1];
                    return _ChatLine(key: ObjectKey(message), message: message);
                  },
                );
              })),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.only(left: 8, right: 4),
                child: MultiLiveDanmakuComposer(room: room, send: send),
              ),
            ]),
          );
        },
      );
}

class _ChatLine extends StatelessWidget {
  const _ChatLine({super.key, required this.message});
  final LiveMessage message;

  InlineSpan _emoji(String url, {double scale = 1, double ratio = 1}) {
    final height = 18 * scale.clamp(.5, 3).toDouble();
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: NetImage(url,
          width: height * ratio.clamp(.5, 4),
          height: height,
          fit: BoxFit.contain),
    );
  }

  Widget _messageText(BuildContext context, {int? maxLines}) {
    final theme = Theme.of(context);
    final parts = message.spans;
    return Text.rich(
        TextSpan(children: [
          TextSpan(
            text: '${message.userName}：',
            style: TextStyle(
                color: message.isSelf
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant),
          ),
          if (parts != null && parts.isNotEmpty)
            for (final part in parts)
              if (part.isImage)
                _emoji(part.imageUrl!,
                    scale: part.imageScale ?? 1, ratio: part.imageRatio ?? 1)
              else
                TextSpan(text: part.text)
          else ...[
            TextSpan(text: message.message),
            for (final url in message.imageUrls ?? const <String>[])
              _emoji(url),
          ],
        ]),
        style: theme.textTheme.bodySmall,
        maxLines: maxLines,
        overflow: maxLines == null ? TextOverflow.clip : TextOverflow.ellipsis);
  }

  Future<void> _copy(BuildContext context, {Offset? position}) async {
    // Capture values before opening the route. Incoming messages may evict or
    // reorder this row while the menu is still open.
    final content = message.message.trim();
    if (content.isEmpty) return;
    final full = '${message.userName}：${message.message}'.trim();
    String? selected;
    if (position != null) {
      final overlay = Overlay.of(context).context.findRenderObject();
      if (overlay is! RenderBox) return;
      final local = overlay.globalToLocal(position);
      selected = await showMenu<String>(
        context: context,
        position: RelativeRect.fromRect(Rect.fromLTWH(local.dx, local.dy, 1, 1),
            Offset.zero & overlay.size),
        items: const [
          PopupMenuItem(
              value: 'content',
              height: 40,
              child: Text('复制弹幕', style: TextStyle(fontSize: 13))),
          PopupMenuItem(
              value: 'full',
              height: 40,
              child: Text('复制「昵称：内容」', style: TextStyle(fontSize: 13))),
        ],
      );
    } else {
      final preview = _messageText(context, maxLines: 4);
      selected = await showModalBottomSheet<String>(
        context: context,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(14))),
        builder: (context) => SafeArea(
            child: SingleChildScrollView(
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
              Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
                  child: Text('复制弹幕',
                      style: Theme.of(context).textTheme.labelMedium)),
              Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: preview),
              const SizedBox(height: 12),
              const Divider(height: 1),
              ListTile(
                  leading: const Icon(Icons.copy_all_outlined),
                  title: const Text('复制弹幕'),
                  onTap: () => Navigator.of(context).pop('content')),
              ListTile(
                  leading: const Icon(Icons.copy_rounded),
                  title: const Text('复制「昵称：内容」'),
                  onTap: () => Navigator.of(context).pop('full')),
              const SizedBox(height: 12),
            ]))),
      );
    }
    if (selected == 'content') {
      Utils.copyToClipboard(content);
    } else if (selected == 'full') {
      Utils.copyToClipboard(full);
    }
  }

  @override
  Widget build(BuildContext context) {
    final child = Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: _messageText(context));
    if (message.message.trim().isEmpty) return child;
    final desktop = switch (Theme.of(context).platform) {
      TargetPlatform.windows ||
      TargetPlatform.macOS ||
      TargetPlatform.linux =>
        true,
      _ => false,
    };
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: desktop
          ? (details) => _copy(context, position: details.globalPosition)
          : null,
      onSecondaryTapUp: desktop
          ? (details) => _copy(context, position: details.globalPosition)
          : null,
      onTap: desktop ? null : () => _copy(context),
      child: child,
    );
  }
}
