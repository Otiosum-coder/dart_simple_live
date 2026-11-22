import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';

/// The sidebar and quick prompt share the room's existing draft and send guard.
class MultiLiveDanmakuComposer extends StatefulWidget {
  const MultiLiveDanmakuComposer(
      {super.key,
      required this.room,
      required this.send,
      this.focusNode,
      this.isCurrent,
      this.onSent,
      this.onEmptySubmit,
      this.inputKey = const ValueKey('multi-live-danmaku-input'),
      this.sendKey = const ValueKey('multi-live-danmaku-send')});

  final LiveRoomController room;
  final Future<String?> Function(String) send;
  final FocusNode? focusNode;
  final bool Function()? isCurrent;
  final VoidCallback? onSent;
  final VoidCallback? onEmptySubmit;

  /// Overridable so a host can mount a second, independently keyed composer.
  final Key inputKey;
  final Key sendKey;

  @override
  State<MultiLiveDanmakuComposer> createState() =>
      _MultiLiveDanmakuComposerState();
}

class _MultiLiveDanmakuComposerState extends State<MultiLiveDanmakuComposer> {
  late final TextEditingController _input;
  late Worker _draftWorker;
  bool _sending = false;
  bool _compositionGuard = false;
  int _compositionEpoch = 0;
  bool _enterHeld = false;
  bool _hardwareActionGuard = false;
  int _hardwareEpoch = 0;
  String? _error;

  bool get _composing =>
      _input.value.composing.isValid && !_input.value.composing.isCollapsed;
  bool get _current =>
      !widget.room.isClosed && (widget.isCurrent?.call() ?? true);

  @override
  void initState() {
    super.initState();
    // The key that opens the prompt is already down before this field exists.
    _enterHeld = HardwareKeyboard.instance.logicalKeysPressed.any(_isEnter);
    _hardwareActionGuard = _enterHeld;
    _input = TextEditingController(text: widget.room.danmakuDraft.value)
      ..addListener(_edited);
    _watchDraft();
  }

  void _watchDraft() {
    _draftWorker = ever<String>(widget.room.danmakuDraft, (text) {
      if (!mounted || _input.text == text) return;
      _input.value = TextEditingValue(
          text: text, selection: TextSelection.collapsed(offset: text.length));
    });
  }

  @override
  void didUpdateWidget(MultiLiveDanmakuComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.room, widget.room)) {
      _draftWorker.dispose();
      _input.text = widget.room.danmakuDraft.value;
      _error = null;
      _watchDraft();
    }
  }

  void _edited() {
    widget.room.danmakuDraft.value = _input.text;
    final epoch = ++_compositionEpoch;
    if (_composing) {
      _compositionGuard = true;
    } else if (_compositionGuard) {
      // An IME may commit text before delivering its Enter/send action. Keep
      // that same frame protected; a subsequent deliberate Enter can send.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && epoch == _compositionEpoch && !_composing) {
          setState(() => _compositionGuard = false);
        }
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    }
    if (mounted) setState(() {});
  }

  Future<void> _submit({bool fromEnter = false}) async {
    if (_sending || _composing || _compositionGuard || !_current) return;
    final original = _input.text;
    final text = original.trim();
    if (text.isEmpty) {
      if (fromEnter) widget.onEmptySubmit?.call();
      return;
    }
    final room = widget.room;
    final send = widget.send;
    setState(() {
      _sending = true;
      _error = null;
    });
    String? error;
    try {
      error = await send(text);
    } catch (_) {
      error = '发送失败，请重试';
    }
    if (!mounted || !identical(widget.room, room)) return;
    if (!_current) {
      setState(() => _sending = false);
      return;
    }
    final unchanged =
        room.danmakuDraft.value == original && _input.text == original;
    if (error == null && unchanged) {
      room.danmakuDraft.value = '';
      _input.clear();
    }
    setState(() {
      _sending = false;
      _error = error;
    });
    if (error == null && unchanged) widget.onSent?.call();
  }

  @override
  void dispose() {
    _draftWorker.dispose();
    _input.removeListener(_edited);
    _input.dispose();
    super.dispose();
  }

  bool _isEnter(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter;

  void _submitted(String _) {
    // Some input systems follow a hardware Enter with a text-input action.
    // The key handler has already handled that press (including IME confirm).
    if (_enterHeld || _hardwareActionGuard) return;
    unawaited(_submit(fromEnter: true));
  }

  KeyEventResult _inputKey(FocusNode node, KeyEvent event) {
    if (!_isEnter(event.logicalKey)) return KeyEventResult.ignored;
    if (event is KeyUpEvent) {
      _enterHeld = false;
      final epoch = ++_hardwareEpoch;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && epoch == _hardwareEpoch && !_enterHeld) {
          _hardwareActionGuard = false;
        }
      });
      WidgetsBinding.instance.ensureVisualUpdate();
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    _enterHeld = true;
    _hardwareActionGuard = true;
    ++_hardwareEpoch;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed ||
        keyboard.isShiftPressed ||
        _composing ||
        _compositionGuard) {
      // Leave IME confirmation and modified keys to the text system.
      return KeyEventResult.skipRemainingHandlers;
    }
    // HardwareKeyboard distinguishes a fresh down from repeats. A key-up may
    // have gone to another focus target, so local held state cannot veto it.
    if (event is KeyDownEvent && !event.synthesized) {
      unawaited(_submit(fromEnter: true));
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(
                  child: Focus(
                canRequestFocus: false,
                onKeyEvent: _inputKey,
                child: TextField(
                  key: widget.inputKey,
                  controller: _input,
                  focusNode: widget.focusNode,
                  decoration: const InputDecoration(
                      hintText: '输入弹幕，回车发送', isDense: true),
                  textInputAction: TextInputAction.send,
                  onEditingComplete: () {},
                  onSubmitted: _submitted,
                ),
              )),
              IconButton(
                  key: widget.sendKey,
                  tooltip: _sending ? '正在发送' : '发送弹幕',
                  onPressed:
                      _sending || _composing || _compositionGuard || !_current
                          ? null
                          : _submit,
                  icon: _sending
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.send_outlined)),
            ]),
            if (_error != null)
              Padding(
                  padding: const EdgeInsets.only(top: 6, bottom: 4),
                  child: Semantics(
                      liveRegion: true,
                      child: Text(_error!,
                          key: const ValueKey('multi-live-danmaku-error'),
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                  color:
                                      Theme.of(context).colorScheme.error)))),
          ]);
}
