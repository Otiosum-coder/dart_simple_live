import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/services/follow_service.dart';

import '../session/multi_live_room_spec.dart';
import '../storage/multi_live_workspace_store.dart';
import 'multi_live_room_link.dart';

Future<MultiLiveRoomSpec?> pickMultiLiveRoom(BuildContext context) =>
    showDialog<MultiLiveRoomSpec>(
      context: context,
      builder: (_) => MultiLiveRoomPicker(
        sites: Sites.supportSites,
        follow: FollowService.instance,
      ),
    );

Future<List<MultiLiveRoomSpec>?> pickMultiLiveRooms(BuildContext context,
        {required int maxSelection, Set<String> existingRoomKeys = const {}}) =>
    showDialog<List<MultiLiveRoomSpec>>(
      context: context,
      builder: (_) => MultiLiveRoomPicker(
        sites: Sites.supportSites,
        follow: FollowService.instance,
        multiSelect: true,
        maxSelection: maxSelection,
        existingRoomKeys: Set.unmodifiable(existingRoomKeys),
      ),
    );

/// The explicit service and resolver inputs keep async dialog behavior testable.
class MultiLiveRoomPicker extends StatefulWidget {
  const MultiLiveRoomPicker({
    super.key,
    required this.sites,
    required this.follow,
    this.resolveLink,
    this.multiSelect = false,
    this.maxSelection = 1,
    this.existingRoomKeys = const {},
  }) : assert(maxSelection >= 0);

  final List<Site> sites;
  final FollowService follow;
  final Future<MultiLiveRoomSpec> Function(String)? resolveLink;
  final bool multiSelect;
  final int maxSelection;
  final Set<String> existingRoomKeys;

  @override
  State<MultiLiveRoomPicker> createState() => _MultiLiveRoomPickerState();
}

class _MultiLiveRoomPickerState extends State<MultiLiveRoomPicker> {
  final _link = TextEditingController();
  final _scroll = ScrollController();
  final _shortScroll = ScrollController(keepScrollOffset: false);
  final _linkFocus = FocusNode();
  final _linkFormKey = GlobalKey();
  late final _sites = {for (final site in widget.sites) site.id: site};
  late final _resolveLink = widget.resolveLink ??
      MultiLiveRoomLinkResolver(supportedSiteIds: _sites.keys).resolve;
  final _selection = <String, MultiLiveRoomSpec>{};
  final _fromFollow = <String>{};
  bool _confirming = false;
  bool get _busy => _submitting || _confirming;
  int get _remaining => math.max(0, widget.maxSelection - _selection.length);
  String get _selectionLabel => '已选 ${_selection.length} · 还可选 $_remaining';
  String? _selectionError;
  bool _submitting = false;
  bool _refreshing = false;
  bool _finished = false;
  bool _showFollows = false;
  String? _linkError;
  String? _refreshError;

  @override
  void initState() {
    super.initState();
    if (widget.follow.followList.isEmpty) {
      unawaited(_loadCachedFollows());
    }
  }

  Future<void> _loadCachedFollows() async {
    try {
      await widget.follow.loadData(updateStatus: false);
    } catch (_) {
      if (mounted && !_finished) {
        setState(() => _refreshError = '关注列表读取失败，请刷新重试');
      }
    }
  }

  Future<void> _refresh() async {
    if (_refreshing || widget.follow.updating.value) return;
    setState(() {
      _refreshing = true;
      _refreshError = null;
    });
    try {
      await widget.follow.loadData();
    } catch (_) {
      if (mounted && !_finished) {
        setState(() => _refreshError = '刷新失败，请稍后重试');
      }
    } finally {
      if (mounted && !_finished) setState(() => _refreshing = false);
    }
  }

  void _finish([Object? room]) {
    if (!mounted || _finished || ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    _finished = true;
    Navigator.of(context).pop(room);
  }

  Future<void> _submit() async {
    if (_submitting || _finished) return;
    if (widget.multiSelect && _remaining == 0) {
      setState(() => _linkError = '选择已满，请先取消一位已选主播');
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _submitting = true;
      _showFollows = false;
      _linkError = null;
    });
    try {
      final room = await _resolveLink(_link.text);
      if (!_sites.containsKey(room.siteId) || !isMultiLiveRoomId(room.roomId)) {
        throw const MultiLiveRoomLinkException('无法识别此平台或直播间链接');
      }
      if (!mounted || _finished || ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      if (!widget.multiSelect) {
        _finish(room);
      } else if (widget.existingRoomKeys.contains(room.roomKey)) {
        setState(() => _linkError = '此直播间已打开');
      } else if (_selection.containsKey(room.roomKey)) {
        setState(() => _linkError = '此直播间已在待选列表中');
      } else if (_remaining == 0) {
        setState(() => _linkError = '选择已满，请先取消一位已选主播');
      } else {
        setState(() {
          _selection[room.roomKey] = room;
          _selectionError = null;
          _link.clear();
        });
      }
    } on MultiLiveRoomLinkException catch (error) {
      if (mounted && !_finished) setState(() => _linkError = error.message);
    } catch (_) {
      if (mounted && !_finished) {
        setState(() => _linkError = '解析失败，请检查链接后重试');
      }
    } finally {
      if (mounted && !_finished) setState(() => _submitting = false);
    }
  }

  void _toggleFollow(FollowUser room) {
    if (_busy || _finished) return;
    final spec = MultiLiveRoomSpec(
        siteId: room.siteId,
        roomId: room.roomId,
        title: room.userName,
        streamerName: room.userName);
    if (!widget.multiSelect) {
      _finish(spec);
      return;
    }
    if (widget.existingRoomKeys.contains(spec.roomKey)) return;
    setState(() {
      _selectionError = null;
      if (_selection.remove(spec.roomKey) != null) {
        _fromFollow.remove(spec.roomKey);
      } else if (_remaining > 0 && room.liveStatus.value == 2) {
        _selection[spec.roomKey] = spec;
        _fromFollow.add(spec.roomKey);
      } else {
        _selectionError = '选择已满，请先取消一位已选主播';
      }
    });
  }

  Future<void> _confirm() async {
    if (_busy || _finished) return;
    setState(() => _confirming = true);
    try {
      if (_link.text.trim().isNotEmpty) {
        await _submit();
        if (_link.text.trim().isNotEmpty || _linkError != null) return;
      }
      if (!mounted || _finished || ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      final live = {
        for (final room in widget.follow.followList)
          if (_sites.containsKey(room.siteId) &&
              room.liveStatus.value == 2 &&
              isMultiLiveRoomId(room.roomId))
            '${room.siteId}:${room.roomId}'
      };
      final before = _selection.length;
      _selection.removeWhere((key, spec) =>
          widget.existingRoomKeys.contains(key) ||
          !_sites.containsKey(spec.siteId) ||
          !isMultiLiveRoomId(spec.roomId) ||
          (_fromFollow.contains(key) && !live.contains(key)));
      if (before != _selection.length) {
        setState(() => _selectionError = '部分主播已下播、移除或已打开，已移出待选，请再次确认');
        return;
      }
      if (_selection.length > widget.maxSelection) {
        setState(
            () => _selectionError = '剩余空位已变化，请减少到 ${widget.maxSelection} 个');
        return;
      }
      if (_selection.isNotEmpty) {
        _finish(List<MultiLiveRoomSpec>.unmodifiable(_selection.values));
      } else {
        setState(() => _selectionError = '请先选择主播或粘贴一个直播间链接');
      }
    } finally {
      if (mounted && !_finished) setState(() => _confirming = false);
    }
  }

  @override
  void dispose() {
    _finished = true;
    _link.dispose();
    _scroll.dispose();
    _shortScroll.dispose();
    _linkFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final textScale = media.textScaler.scale(14) / 14;
    final extraScale = math.max(0.0, textScale - 1);
    final usableHeight = media.size.height - media.viewInsets.vertical;
    final tightInsets = usableHeight < 240 + extraScale * 100;
    return PopScope<Object?>(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _finished = true;
      },
      child: Dialog(
        insetPadding: EdgeInsets.symmetric(
            horizontal: 16, vertical: tightInsets ? 8 : 24),
        child: SizedBox(
          width: 720,
          height: 640,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: tightInsets ? 8 : 16),
            child: LayoutBuilder(builder: (context, constraints) {
              final columns = constraints.maxWidth >= 600 ? 2 : 1;
              final itemHeight = 68 + extraScale * 40;
              final short = constraints.maxHeight <
                  (widget.multiSelect ? 300 : 180) + extraScale * 110;
              final linkPanel = short && !_showFollows;
              final showHeader =
                  !short || constraints.maxHeight >= 160 + extraScale * 80;
              return Obx(() {
                // Read each Rx status so both entering and leaving live state
                // update immediately, including during a shared batch refresh.
                final rooms = widget.follow.followList
                    .where((room) =>
                        _sites.containsKey(room.siteId) &&
                        isMultiLiveRoomId(room.roomId) &&
                        room.liveStatus.value == 2)
                    .toList();
                final refreshing = _refreshing || widget.follow.updating.value;
                final compact = constraints.maxHeight < 460 || textScale > 1.4;
                final header = _header(compact: compact, constrained: short);
                final section = _section(rooms.length, refreshing);
                final link = _linkForm(compact: compact, constrained: short);
                final actions = _actions(
                    compact: compact,
                    constrained: short,
                    browsing: short && _showFollows);
                final grid = SliverGrid.builder(
                  itemCount: rooms.length,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisExtent: itemHeight,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemBuilder: (_, index) => _followTile(rooms[index]),
                );
                final empty = _empty(refreshing, separateLink: short);
                // Below the height needed for fixed content, use one bounded
                // viewport for either the short form or the virtual follow
                // list. Form scroll distance never depends on follow count.
                final controller = linkPanel ? _shortScroll : _scroll;
                final list = Scrollbar(
                  controller: controller,
                  child: CustomScrollView(
                    key: ValueKey(linkPanel
                        ? 'multi-live-link-panel'
                        : 'multi-live-follows'),
                    controller: controller,
                    slivers: [
                      if (linkPanel) ...[
                        if (widget.multiSelect)
                          SliverToBoxAdapter(child: _selectionSummary()),
                        SliverToBoxAdapter(child: link),
                        SliverToBoxAdapter(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                              key: const ValueKey('multi-live-browse-follows'),
                              onPressed:
                                  _busy ? null : () => _switchShortPane(true),
                              child: Text('浏览关注（${rooms.length}）'),
                            ),
                          ),
                        ),
                      ] else ...[
                        if (compact) SliverToBoxAdapter(child: section),
                        if (rooms.isEmpty)
                          SliverToBoxAdapter(child: empty)
                        else
                          grid,
                      ],
                    ],
                  ),
                );
                return Column(children: [
                  if (showHeader) header,
                  if (!compact) section,
                  Expanded(
                    child:
                        rooms.isEmpty && !compact ? Center(child: empty) : list,
                  ),
                  if (!short) link,
                  actions,
                ]);
              });
            }),
          ),
        ),
      ),
    );
  }

  void _switchShortPane(bool showFollows) {
    _linkFocus.unfocus();
    setState(() => _showFollows = showFollows);
  }

  Widget _header({bool compact = false, bool constrained = false}) => Padding(
        padding: EdgeInsets.only(
            top: constrained ? 4 : (compact ? 8 : 20),
            bottom: constrained ? 0 : (compact ? 4 : 8)),
        child: compact
            ? Row(children: [
                Expanded(
                  child: Text('选择直播间',
                      style: constrained
                          ? Theme.of(context).textTheme.titleSmall
                          : Theme.of(context).textTheme.titleMedium),
                ),
                const SizedBox(width: 8),
                IconButton(
                  key: const ValueKey('multi-live-close'),
                  tooltip: '关闭',
                  onPressed: _finish,
                  icon: const Icon(Icons.close),
                ),
              ])
            : Align(
                alignment: Alignment.centerLeft,
                child: Text('选择直播间',
                    style: Theme.of(context).textTheme.titleLarge),
              ),
      );

  Widget _section(int count, bool refreshing) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text(widget.multiSelect ? _selectionLabel : '正在直播的关注',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall),
            ),
            const SizedBox(width: 8),
            Text('$count 位', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(width: 8),
            IconButton(
              tooltip: refreshing ? '正在刷新直播状态' : '刷新直播状态',
              onPressed: refreshing ? null : _refresh,
              icon: refreshing
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh, size: 20),
            ),
          ]),
          if (widget.multiSelect &&
              (_selectionError != null ||
                  _selection.keys.any((key) => !_fromFollow.contains(key))))
            _selectionSummary(showCount: false),
          if (_refreshError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(_refreshError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
        ],
      );

  Widget _selectionSummary({bool showCount = true}) => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (_selectionError != null || showCount)
            Text(_selectionError ?? _selectionLabel,
                key: const ValueKey('multi-live-selection-summary'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: _selectionError == null
                        ? null
                        : Theme.of(context).colorScheme.error)),
          Wrap(spacing: 4, children: [
            for (final room in _selection.values)
              if (!_fromFollow.contains(room.roomKey))
                InputChip(
                  key: ValueKey('multi-live-selected-link-${room.roomKey}'),
                  label: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 180),
                      child: Text(
                          '${_sites[room.siteId]?.name} · ${room.roomId}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis)),
                  onDeleted: _busy
                      ? null
                      : () => setState(() {
                            _selection.remove(room.roomKey);
                            _selectionError = null;
                          }),
                  deleteButtonTooltipMessage: '移出待选',
                ),
          ]),
        ]),
      );

  Widget _empty(bool refreshing, {bool separateLink = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 12),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.live_tv_outlined, size: 28),
          const SizedBox(height: 8),
          Text(refreshing ? '正在更新直播状态…' : '暂无正在直播的关注主播'),
          const SizedBox(height: 4),
          Text(separateLink ? '可刷新状态，或返回链接添加' : '可刷新状态，或在下方粘贴直播间链接',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall),
        ]),
      );

  Widget _followTile(FollowUser room) {
    final theme = Theme.of(context);
    final key = '${room.siteId}:${room.roomId}';
    final selected = widget.multiSelect && _selection.containsKey(key);
    final existing =
        widget.multiSelect && widget.existingRoomKeys.contains(key);
    return Semantics(
      checked: widget.multiSelect ? selected : null,
      enabled: !_busy && !existing,
      label: existing ? '${room.userName}，已打开' : null,
      child: Material(
        key: ValueKey('multi-live-follow-${room.id}'),
        color: selected
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _busy || existing ? null : () => _toggleFollow(room),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(children: [
              _avatar(room),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(room.userName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(
                        '${_sites[room.siteId]!.name} · ${existing ? '已打开' : '直播中'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                  widget.multiSelect
                      ? (existing
                          ? Icons.check_circle_outline
                          : (selected
                              ? Icons.check_box
                              : Icons.check_box_outline_blank))
                      : Icons.chevron_right,
                  size: 18),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _avatar(FollowUser room) {
    final fallback = CircleAvatar(
      key: ValueKey('multi-live-avatar-fallback-${room.id}'),
      radius: 20,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Icon(Icons.person_outline, size: 22),
    );
    if (room.face.trim().isEmpty) return fallback;
    return ClipOval(
      child: Image.network(
        room.face,
        width: 40,
        height: 40,
        cacheWidth: 80,
        fit: BoxFit.cover,
        excludeFromSemantics: true,
        frameBuilder: (_, child, frame, __) => frame == null ? fallback : child,
        errorBuilder: (_, __, ___) => fallback,
      ),
    );
  }

  Widget _linkForm({bool compact = false, bool constrained = false}) => Padding(
        key: _linkFormKey,
        padding: EdgeInsets.only(top: compact ? 8 : 16),
        child: TextField(
          key: const ValueKey('multi-live-room-link'),
          controller: _link,
          focusNode: _linkFocus,
          enabled: !_busy,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.done,
          autocorrect: false,
          enableSuggestions: false,
          onChanged: (_) {
            if (_linkError != null) setState(() => _linkError = null);
          },
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            labelText: '直播间链接',
            hintText: 'https://live.bilibili.com/…',
            prefixIcon: const Icon(Icons.link),
            suffixIcon: widget.multiSelect
                ? IconButton(
                    key: const ValueKey('multi-live-stage-link'),
                    tooltip: '将单个链接加入待选',
                    onPressed: _busy ? null : _submit,
                    icon: const Icon(Icons.add),
                  )
                : null,
            border: const OutlineInputBorder(),
            isDense: true,
            errorText: _linkError,
            errorMaxLines: 2,
            helperText: constrained
                ? null
                : (widget.multiSelect
                    ? '单个链接可加入待选，确认时统一添加'
                    : (compact ? '未关注也可添加' : '支持哔哩哔哩、斗鱼、虎牙、抖音，未关注也可添加')),
            helperMaxLines: 2,
          ),
        ),
      );

  Widget _actions(
      {bool compact = false, bool constrained = false, bool browsing = false}) {
    final label = Text(
        widget.multiSelect
            ? (_submitting ? '解析中…' : '确认添加 ${_selection.length} 个')
            : (browsing ? '返回链接添加' : (_submitting ? '解析中…' : '添加直播间')),
        textAlign: TextAlign.center);
    final progress = _submitting
        ? const SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : null;
    final submit = compact
        ? FilledButton(
            key: widget.multiSelect
                ? const ValueKey('multi-live-confirm-selection')
                : (browsing ? const ValueKey('multi-live-return-link') : null),
            onPressed: widget.multiSelect
                ? (_busy ? null : _confirm)
                : (browsing
                    ? () => _switchShortPane(false)
                    : (_submitting ? null : _submit)),
            style: FilledButton.styleFrom(
                padding:
                    EdgeInsets.symmetric(horizontal: constrained ? 4 : 12)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (progress != null) ...[progress, const SizedBox(width: 8)],
              Flexible(child: label),
            ]),
          )
        : FilledButton.icon(
            key: widget.multiSelect
                ? const ValueKey('multi-live-confirm-selection')
                : null,
            onPressed: _busy ? null : (widget.multiSelect ? _confirm : _submit),
            icon: progress ?? const Icon(Icons.add, size: 18),
            label: label,
          );
    return Padding(
      padding:
          EdgeInsets.symmetric(vertical: constrained ? 4 : (compact ? 8 : 12)),
      child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        TextButton(
          onPressed: _finish,
          style: compact
              ? TextButton.styleFrom(
                  padding:
                      EdgeInsets.symmetric(horizontal: constrained ? 4 : 12))
              : null,
          child: const Text('取消'),
        ),
        if (widget.multiSelect && browsing)
          IconButton(
            key: const ValueKey('multi-live-return-link'),
            tooltip: '返回链接添加',
            onPressed: _busy ? null : () => _switchShortPane(false),
            icon: const Icon(Icons.link),
          ),
        SizedBox(width: constrained ? 4 : 8),
        Flexible(child: submit),
      ]),
    );
  }
}
