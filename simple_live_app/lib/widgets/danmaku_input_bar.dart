
import 'package:characters/characters.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';

/// 弹幕输入条（胶囊样式：左侧输入 + 右侧橙色「发送(Enter)」按钮）
///
/// 回车行为三态：
/// - 没有输入框 → 显示输入框
/// - 有输入框、没内容 → 收起输入框
/// - 有输入框、有内容 → 发送
class DanmakuInputBar extends StatefulWidget {
  /// 是否有输入框正在打字（控制条自动隐藏要跳过）
  static bool typing = false;
  final LiveRoomController controller;

  /// 自动聚焦（全屏唤起时用）
  final bool autoFocus;

  /// 全屏浮层样式（自带外边距、无边框外框）
  final bool overlay;

  /// 横屏控制条内的紧凑样式：只有输入框，不带发送按钮（回车发送）
  final bool compact;

  /// 发送成功 / 空内容回车的回调（全屏用来收起自己）
  final VoidCallback? onFinished;
  const DanmakuInputBar({
    required this.controller,
    this.autoFocus = false,
    this.overlay = false,
    this.compact = false,
    this.onFinished,
    Key? key,
  }) : super(key: key);

  @override
  State<DanmakuInputBar> createState() => _DanmakuInputBarState();
}

class _DanmakuInputBarState extends State<DanmakuInputBar> {
  final TextEditingController _textController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  bool _sending = false;

  /// 平台弹幕字数上限（按字符计，emoji 算 1 个）
  int get _maxLength {
    switch (widget.controller.site.id) {
      case Constant.kDouyu:
        return 30;
      case Constant.kBiliBili:
        return 20;
      case Constant.kHuya:
        return 30;
      case Constant.kDouyin:
        return 50;
      default:
        return 30;
    }
  }

  int get _charCount => _textController.text.characters.length;

  @override
  void initState() {
    super.initState();
    _textController.text = widget.controller.danmakuDraft.value;
    _focusNode.addListener(() {
      DanmakuInputBar.typing = _focusNode.hasFocus;
    });
    _textController.addListener(_onTextChanged);
    if (widget.autoFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _focusNode.requestFocus();
        }
      });
    }
  }

  void _onTextChanged() {
    if (!mounted) {
      return;
    }
    // 同步草稿，避免切换横竖屏后内容丢失
    widget.controller.danmakuDraft.value = _textController.text;
    setState(() {});
  }

  @override
  void dispose() {
    _textController.removeListener(_onTextChanged);
    _textController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending) {
      return;
    }
    var text = _textController.text.trim();
    if (text.isEmpty) {
      // 有输入框但没内容 → 回车收起
      widget.onFinished?.call();
      return;
    }
    setState(() => _sending = true);
    var error = await widget.controller.sendDanmaku(text);
    if (!mounted) {
      return;
    }
    setState(() => _sending = false);
    if (error == "") {
      // 空串 = 用户在确认弹窗里取消：保留内容，不提示
      return;
    }
    if (error == null) {
      _textController.clear();
      widget.controller.danmakuDraft.value = "";
      if (widget.onFinished != null) {
        widget.onFinished!.call();
      } else {
        _focusNode.requestFocus();
      }
    } else {
      SmartDialog.showToast(error);
    }
  }

  @override
  Widget build(BuildContext context) {
    var scheme = Theme.of(context).colorScheme;
    // 平台是否支持发送（虎牙/抖音暂未实现 → 禁用态，布局保持一致）
    var supported = widget.controller.canSendDanmaku.value;
    if (!supported) {
      _focusNode.unfocus();
    }
    var pill = Container(
      height: 44,
      padding: const EdgeInsets.only(left: 16, right: 5),
      decoration: BoxDecoration(
        color: const Color(0xEB15181C),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _textController,
              focusNode: _focusNode,
              enabled: supported,
              // 回车 = 发送 / 空内容 = 收起
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              maxLength: _maxLength,
              maxLengthEnforcement: MaxLengthEnforcement.truncateAfterCompositionEnds,
              cursorColor: Colors.white,
              style: TextStyle(
                fontSize: 13.5,
                color: supported ? Colors.white : Colors.white54,
              ),
              decoration: InputDecoration(
                isDense: true,
                counterText: "",
                border: InputBorder.none,
                hintText: supported ? "说点什么吧~" : "该平台暂不支持发送弹幕",
                hintStyle: const TextStyle(
                  fontSize: 13.5,
                  color: Color(0xFF8B9299),
                ),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          if (_charCount > 0)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Text(
                "$_charCount/$_maxLength",
                style: TextStyle(
                  fontSize: 11,
                  color: _maxLength - _charCount <= 0
                      ? Colors.redAccent
                      : (_maxLength - _charCount <= 5
                          ? Colors.orangeAccent
                          : Colors.white38),
                ),
              ),
            ),
          const SizedBox(width: 8),
          _sending
              ? const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 14),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  ),
                )
              : TextButton(
                  onPressed: supported ? _send : null,
                  style: TextButton.styleFrom(
                    // 跟主题色保持一致
                    backgroundColor: scheme.primary,
                    foregroundColor: scheme.onPrimary,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    minimumSize: const Size(0, 34),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(17),
                    ),
                  ),
                  child: Text(
                    "发送",
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
        ],
      ),
    );

    if (widget.compact) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SizedBox(
            width: double.infinity,
            child: Container(
          height: 36,
          padding: const EdgeInsets.only(left: 14, right: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF1E2027),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white30),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _textController,
                  focusNode: _focusNode,
                  enabled: supported,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  maxLength: _maxLength,
                  maxLengthEnforcement:
                      MaxLengthEnforcement.truncateAfterCompositionEnds,
                  cursorColor: Colors.white,
                  style: const TextStyle(fontSize: 13, color: Colors.white),
                  decoration: InputDecoration(
                    isDense: true,
                    counterText: "",
                    border: InputBorder.none,
                    hintText: supported ? "说点什么吧~" : "该平台暂不支持发送",
                    hintStyle: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF9AA0A6),
                    ),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),
              if (_charCount > 0)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Text(
                    "$_charCount/$_maxLength",
                    style: TextStyle(
                      fontSize: 11,
                      color: _maxLength - _charCount <= 0
                          ? Colors.redAccent
                          : (_maxLength - _charCount <= 5
                              ? Colors.orangeAccent
                              : Colors.white38),
                    ),
                  ),
                ),
            ],
          ),
        ),
          ),
        ),
      );
    }
    if (widget.overlay) {
      return pill;
    }
    // 非全屏：内嵌在消息区底部（底部留出系统导航条安全区）
    return Container(
      padding: EdgeInsets.fromLTRB(
        12,
        6,
        12,
        6 + MediaQuery.paddingOf(context).bottom,
      ),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        border: Border(top: BorderSide(color: Colors.grey.withAlpha(25))),
      ),
      child: pill,
    );
  }
}

/// 全屏弹幕输入浮层
///
/// 默认不显示（全屏保持干净），回车唤起；收起后把焦点还给这一层，
/// 所以下一次回车依然能唤起（之前只生效一次就是这个原因）。
class DanmakuInputOverlay extends StatefulWidget {
  final LiveRoomController controller;
  const DanmakuInputOverlay({required this.controller, Key? key})
      : super(key: key);

  @override
  State<DanmakuInputOverlay> createState() => _DanmakuInputOverlayState();
}

class _DanmakuInputOverlayState extends State<DanmakuInputOverlay> {
  final FocusNode _playerFocus = FocusNode(debugLabel: "danmakuInputOverlay");

  @override
  void dispose() {
    _playerFocus.dispose();
    super.dispose();
  }

  bool get _canSend =>
      AppSettingsController.instance.playerSendDanmaku.value &&
      widget.controller.canSendDanmaku.value;

  /// 输入条收起后把焦点还给播放器层，下一次回车才能再唤起
  void _focusPlayer() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _playerFocus.requestFocus();
      }
    });
  }

  void _hide() {
    widget.controller.showDanmakuInput.value = false;
    _focusPlayer();
  }

  @override
  Widget build(BuildContext context) {
    return Obx(
      () {
        if (!_canSend) {
          return const SizedBox.shrink();
        }
        var show = widget.controller.showDanmakuInput.value;
        return Focus(
          focusNode: _playerFocus,
          autofocus: true,
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent &&
                (event.logicalKey == LogicalKeyboardKey.enter ||
                    event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
              // 没有输入框 → 显示；有输入框时由输入框自己处理（发送/收起）
              if (!show) {
                widget.controller.showDanmakuInput.value = true;
                return KeyEventResult.handled;
              }
            }
            return KeyEventResult.ignored;
          },
          child: show
              ? Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding:
                        const EdgeInsets.only(left: 16, right: 16, bottom: 56),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 520),
                      child: DanmakuInputBar(
                        controller: widget.controller,
                        autoFocus: true,
                        overlay: true,
                        onFinished: _hide,
                      ),
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        );
      },
    );
  }
}