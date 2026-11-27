# 多开直播工作区：实现契约

状态：用户已批准开发；本文是实现与验收契约，不代表功能已经实现或验证。

## 1. 范围与行为

- 设备容量策略（用户已确认）：Windows/macOS/Linux 桌面同窗口最多四路；Android/iOS 本版最多两路，平板暂沿用移动策略。默认仍为单房间观看，多开是可选入口。共享会话和布局内核保留四路能力，由宿主统一提供 maxRooms；下文的新增、替换、恢复与测试均遵守当前设备上限。
- 每路保留独立音量、静音、清晰度、线路和弹幕显示设置，允许多路同时有声；选中聊天目标不隐式修改声音。
- 桌面采用非重叠分屏：二路左右/上下、三路左一右二/上一下二、四路四宫格/左一右三，支持拖动分割线和标题栏交换。
- 手机双开竖屏上下、横屏左右，优先简化触控操作，保留添加/替换/关闭、点选聊天目标和临时放大/返回双屏。先完成桌面集成，再补齐移动适配；旋转仅改变布局，不重建会话。桌面缩小窗口不切换成移动容量，也不关闭既有房间。
- 增加、替换、关闭房间；临时最大化某一路，Esc 恢复之前布局。最大化、切换预设、交换位置不得创建新播放器、重新解析播放地址或者改变其他房间声音。
- 当前选中房间是聊天查看与发送目标，界面明确显示目标平台和房间。选中、最大化均不隐式静音其他房间。
- 保存房间、分屏树及比例、各房间音量/静音/弹幕设置和选中房间；重新进入提供恢复。临时最大化不写成永久布局。
- 单房间入口保留；直播间工具栏提供“多开直播”可选入口。桌面第五路、移动第三路在分配播放器之前拒绝并明确提示上限。重复添加同一平台同一房间选中已有房间。
- 沿用现有主题、AppStyle、图标和设置组件；不更改依赖版本、默认画质、系统音量，也不重构无关页面。

## 2. 已核实的现有结构

以下位置是本次检查的工作树，已有大量用户未提交改动，不能按 HEAD 覆盖或恢复。

- simple_live_app/lib/modules/live_room/live_room_controller.dart：LiveRoomController({required Site pSite, required String pRoomId})，每个实例创建 liveDanmaku；loadData()、getPlayUrl()、changePlayLine(int, {bool fromUser = false})、sendDanmaku(String)、resetRoom(Site, String)、onClose() 已存在。当前文件还已有 _roomLoadGeneration / isClosed 异步失效保护及有界聊天缓存，必须保留。
- simple_live_app/lib/modules/live_room/player/player_controller.dart：PlayerMixin 持有实例级 Player / VideoController；PlayerController.onInit() 同时初始化系统行为、流订阅和窗口监听；_realSetVolume(int) 当前操作 VolumeController 的系统音量；播放/结束/错误回调及销毁路径涉及全局 Wakelock。不能直接复制四份原页面控制器而不隔离这些副作用。
- simple_live_app/lib/modules/live_room/live_room_page.dart：LiveRoomPage extends GetView<LiveRoomController>，现有页面使用默认未加标签控制器。多开视图不使用这个默认查找来获得四个房间。
- simple_live_app/lib/routes/app_pages.dart：现有直播间由 GetPage + BindingsBuilder.put 构造 LiveRoomController；simple_live_app/lib/routes/route_path.dart 的现有入口为 /room/detail。
- simple_live_app/lib/routes/app_navigation.dart：AppNavigator.toLiveRoomDetail(...) 包含哔哩哔哩/斗鱼登录提示及单房间复用逻辑。新入口另加，不改普通入口的含义。
- simple_live_app/lib/services/local_storage_service.dart：T getValue<T>(dynamic key, T defaultValue)、Future setValue<T>(dynamic key, T value) 使用现有 Hive settingsBox。无需新依赖或新数据库。
- simple_live_core/lib/src/interface/live_danmaku.dart：LiveDanmaku 是被各平台 implements 的类，包含接收回调、start/stop、canSendDanmaku、sendDanmaku。直接增加抽象需求会影响全部平台实现，发送租约应使用独立的可选能力接口。
- simple_live_core/lib/src/danmaku/douyu_danmaku.dart：start() 会调度 _preheatSender()；_senderSocket / _senderFuture 与接收连接分开；stop() 当前关闭两者。同账号多房间应分别接收，但只能由选中目标持有需要认证的发送连接。

## 3. 分层与固定交接接口

### 3.1 会话层（playback 所有）

新增 simple_live_app/lib/modules/multi_live/session/ 下的模型、会话、发送租约与必要的资源协调器。

固定导出文件与接口：

- session/multi_live_room_spec.dart：MultiLiveRoomSpec。不可变；构造参数 required String siteId、required String roomId，以及可选 title、double volume = 100、bool muted = false、bool danmakuVisible = true；提供 roomKey、copyWith、toJson、tryFromJson(Object?)。volume 存储范围为 0..100，不是系统音量。只保存平台/房间标识及用户设置。
- session/multi_live_room_session.dart：MultiLiveRoomSession extends ChangeNotifier；构造参数 required String id、required MultiLiveRoomSpec spec。id 在会话生命周期内不变。提供 id、spec、LiveRoomController? room、bool initialized、bool closed；Future<void> initialize()、setVolume(double)、setMuted(bool)、setDanmakuVisible(bool)、setSenderActive(bool)、close()；Future<String?> sendDanmaku(String)。可以增加可选的测试注入参数，不能破坏这些交接签名。
- 同文件提供 typedef MultiLiveSessionFactory = MultiLiveRoomSession Function({required String id, required MultiLiveRoomSpec spec});，集成控制器可注入替身。

initialized 表示会话已准备好可引用的控制器/播放器，不代表首帧或网络加载成功。加载/播放状态继续由该房间原有响应式状态表示；初始化失败必须释放已取得的资源。

实现优先复用现有解析、播放、聊天与弹幕逻辑。在 LiveRoomController / PlayerController 上增加默认关闭的 embedded 模式或等效集中策略。默认单房间行为保持原样；多开明确传入嵌入模式，不能靠当前路由字符串猜测。

嵌入模式要求：

1. 控制器使用每个会话唯一的 GetX tag，或者完整且可验证的显式生命周期；不注册/查找默认未加标签的 LiveRoomController。
2. 不触发单房间自动全屏、迷你窗、系统音量手势、应用自动退出、独占窗口监听、后台媒体会话或全局设置写回。初始化可以读取默认设置，但更改房间清晰度/线路/音量不能改其他房间的配置。
3. 音量调用该实例 Player.setVolume；静音保留非零记忆音量以便恢复。任何关闭、错误或暂停不能清除别的活跃房间常亮状态。使用共有的所有者/引用计数协调器，或证明单房间到工作区的交接已完成且不存在迟到的全局关闭调用。
4. 会话持有并释放自己的订阅、定时器、弹幕连接、缓存与原生播放器；close() 幂等且可等待。路由销毁、替换和初始化途中关闭后，迟到的异步结果不得重新开流、重连或通知已销毁的界面。
5. 保留本轮之前的聊天上限、表情缓存、房间 generation 保护和日志脱敏；首帧计时等诊断状态不能在四路之间串用。

### 3.2 发送连接租约

新增独立可选能力接口，例如 simple_live_core/lib/src/interface/live_danmaku_sender_control.dart 中的 LiveDanmakuSenderControl，方法 Future<void> setSenderActive(bool active)。由需要独占认证连接的斗鱼实现；不让所有 LiveDanmaku 实现被迫新增无意义方法。

- 普通单房间默认允许发送，兼容现有行为。
- 嵌入房间必须在 start()/预热之前禁用发送；未选中房间仍正常接收。
- 工作区串行移交发送权限：先等待旧目标释放，再启用当前目标。快速连续切换使用 generation/队列，只允许最新选择最终取得权限；关闭旧目标不能释放新目标的租约。
- 禁用发送只关闭 senderSocket，不调用接收侧 stop()。预热延迟、正在登录的 Future、重连和迟到回调都必须检查租约 generation，不得在移交后重新夺回认证连接。
- 点击发送时固定目标 id 与消息，不把一个未完成发送转投新选中房间。不支持发送的平台显示既有能力提示。
- 不将 Cookie、Token、签名、完整发送文本或临时播放地址写入持久化或新增日志。

### 3.3 布局与表现层（layout 所有）

新增 layout/、widgets/ 和 multi_live_page.dart。表现层不导入原生播放器或 Get.find<LiveRoomController>()；通过界面模型和 WidgetBuilder 接入真正的房间。这样可独立编译、测试布局，集成阶段不需要改布局内部。

固定主入口：MultiLivePage({super.key, required MultiLiveViewModel model})。

widgets/multi_live_view_model.dart 定义：

- abstract class MultiLiveViewModel implements Listenable。
- List<MultiLiveTileData> get rooms；MultiLiveLayoutNode? get layout；String? get selectedRoomId；String? get maximizedRoomId；int get maxRooms；bool get busy；bool get allMuted；WidgetBuilder? get selectedRoomChatBuilder。maxRooms 由集成层按设备策略提供，页面按钮、提示与后台创建校验使用同一个容量值；移动布局按宿主策略和当前方向适配，不以桌面窗口宽度猜测容量。
- Future<void> addRoom()、replaceRoom(String id)、closeRoom(String id)、setVolume(String id, double volume)、toggleMute(String id)、setAllMuted(bool muted)。
- void selectRoom(String id)、toggleDanmaku(String id)、maximizeRoom(String? id)、setPreset(MultiLiveLayoutPreset preset)、resizeSplit(String nodeId, double ratio)、swapRooms(String sourceId, String targetId)。
- MultiLiveTileData 提供 id/title/subtitle（String）、volume（double）、muted/danmakuVisible（bool）、bodyBuilder（WidgetBuilder），以及可选 settingsBuilder（WidgetBuilder），供集成端接入独立清晰度/线路等设置。构造参数同名；title/subtitle 可用空串默认值。

布局模型放在 layout/multi_live_layout.dart：

- enum MultiLiveLayoutPreset { sideBySide, stacked, leftMain, topMain, grid, leftMainThree }，依次对应本方案六个预设。
- MultiLiveLayoutNode 表示稳定 id 的叶子/二叉分割树，提供 toJson、tryFromJson；叶子引用会话 id，分割节点有 id、Axis axis、double ratio、first、second。具体辅助类/工厂由 layout 实现并在首次交接中明确。
- 空工作区 layout 为 null；非空布局每个活跃会话恰好出现一次。预设按当前房间数启用，不能因选择预设悄悄删除房间；添加/关闭时重建合法树或折叠空分支。
- 纯模型实现交换、移除、预设、比例更新和验证，保持房间 id 不变。比例必须有限、范围合法，布局树不能循环、重复或引用不存在的房间。
- 使用当前尺寸计算分隔条拖动和最小子窗约束；小窗口时不得负尺寸/溢出。改变比例只更新对应布局，不持续写磁盘。
- 房间视图以稳定 id 保持身份，原生 Player / VideoController 始终由会话持有；临时最大化不得 dispose 其他房间。提供可聚焦操作、按钮提示、拖动反馈与 Esc 恢复。

以现有 Theme、AppStyle、设置面板和图标为准，不为该功能引入第二套视觉语言。独立聊天面板显示当前目标名称，切换后不出现上一个目标的输入/历史串线。

### 3.4 集成与保存（architect 所有）

新增 multi_live_controller.dart、必要的 route 包装和 storage/。MultiLiveController 持有会话表、布局、选中目标和保存调度，落实 MultiLiveViewModel；通过真实 WidgetBuilder 接入该会话的视频、弹幕、聊天和独立清晰度/线路菜单。交付不接受占位视频或只演示布局。

- 增加 RoutePath.kMultiLive 以及 GetPage 绑定；AppNavigator 新增多开入口；单房间工具栏提供入口。
- 从正在播放的单房间转入工作区时先快照房间标识，再停止/释放原路由拥有的播放和发送资源。不能留下隐藏的第五路或旧房间声音。单房间异步销毁与工作区常亮交接需纳入测试。
- 添加/替换对话框至少提供已关注房间选择及平台+房间号输入，沿用已有登录提示；校验平台和房间号，处理加载/离线/失败状态。替换释放旧会话后再分配新播放器，其他房间保留原身份和状态。
- 超过当前 maxRooms 的请求在工厂调用之前拒绝（桌面第五路、移动第三路）。并发增加/替换/关闭必须串行化或预留名额；界面 busy 不能作为唯一并发保护。
- 关闭被选中房间后选一个仍存在的房间，并移交发送租约；全部关闭时展示空态，可继续添加。退出工作区取消所有保存/选择任务并等待会话清理。

持久化使用单独的版本化 key multiLive.workspace.v1，调用现有 LocalStorageService 的 getValue/setValue；不更改数据库适配器和全局播放器设置。建议保存 JSON 字符串，字段为 version、rooms、layout、selectedRoomId；rooms 中每项为稳定 id 和 spec 数据。

只保存平台、房间号、可选展示标题、音量/静音/弹幕开关和布局；不保存平台凭证、临时 URL、HTTP 头或发送文本。恢复时重新通过平台接口取得地址和权限。

恢复验证：版本、类型、支持的平台、当前 maxRooms、重复房间/会话 id、有限音量、有限比例及精确叶子集合。不可信或旧版本数据提供安全空态/默认布局，不启动无界数量的会话。超过本设备容量的存档不自动全部开流，不静默截断并覆盖原存档；显示容量说明，允许用户选择房间或重新添加，发生明确用户修改前保留原存档。写入去抖并串行化，最终退出时 flush；旧保存完成不能覆盖更新的布局。保留当前工作区时不被异步恢复覆盖。

## 4. 并行写入边界

本文件完成后 t2 与 t3 并行；t4 同时依赖两者完成，再由 t5 独立验证、t6 汇总。除下列协调范围，成员不得改其他成员文件。文中 playback、layout、architect 是初始职责名称；故障恢复可能转派执行成员，当前负责人及写入授权以 AgentTeams 已分配任务的 assignee 和任务范围为准，不需要等待已移除成员确认。

- playback / t2：session/**、session_* / sender_* 测试；允许对现有 player/player_controller.dart、live_room_controller.dart 做最小嵌入隔离；可选发送接口、core 导出、douyu_danmaku.dart 的租约支持也由 playback 独占。这些现有文件已经有用户改动，逐处小改，禁止覆盖整文件。
- layout / t3：layout/**、widgets/**、multi_live_page.dart，layout_* / page_* 测试；不改现有直播间控制器、路由、存储和 core。
- architect / t4：multi_live_controller.dart、storage/**、integration/**、必要的设备策略文件、新的 route 包装、routes/app_pages.dart、routes/route_path.dart、routes/app_navigation.dart、live_room_page.dart 的入口及集成；不与 playback 同时修改现有控制器/core。需要额外范围先通过 captain 协调。
- verifier / t5：独立审查实现与测试；仅写 integration_* / lifecycle_* 测试或验证报告，生产修复交给负责实现成员。

playback 先交付 spec / session 公共接口，layout 先交付布局与视图模型接口；新签名或范围变更在团队消息中明确后再改。不要提交代码、重置工作树、安装覆盖当前程序、重启用户播放器或升级依赖。

## 5. 验证与完成条件

工作目录 simple_live_app，使用已经存在的 E:/Enviroment/sdk383/flutter/bin/flutter.bat，不改变 SDK 或依赖：

1. flutter.bat test --no-pub test/multi_live：桌面六个预设、分割边界、交换不改会话身份、最大化/恢复、桌面0..4路及第五路拒绝、移动0..2路及第三路拒绝、并发名额/恢复容量检查、桌面窄窗口不降容量、移动横竖屏不重建播放器、重复房间、关闭/替换、独立音量/静音、发送租约连续切换/在途取消、初始化失败与销毁、持久化往返/畸形数据/写入顺序。
2. flutter.bat test --no-pub test/bounded_chat_buffer_test.dart test/emoji_image_cache_test.dart test/log_sanitizer_test.dart test/http_log_redaction_test.dart：保留既有性能与日志回归覆盖。
3. flutter.bat analyze --no-pub --no-fatal-infos --no-fatal-warnings；不得引入新的错误、警告或 lint。若完整分析遇到工具超时，记录限制并补齐改动范围分析，不能声称全项目分析通过。
4. Git diff --check、人工审查最终差异，确认只新增/更改授权范围并保留原有用户改动。
5. 可行时运行不安装覆盖的桌面调试/构建验证：实际四路、各路声音和音量、同平台双房间弹幕接收与发送目标、拖分割线/交换/最大化、快速关开、恢复、空态和失败态。无法访问直播或无法执行时明确写未验证，替身测试不能冒充真实平台验证。

性能验收关注不会因拖布局重新建流、退出后播放器/订阅/定时器被释放、缓存上界保持、没有隐藏的额外房间。四路解码天然增加 CPU/GPU/内存，不宣称未测量的百分比改善，不自动降低用户画质。
