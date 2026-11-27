# 虎牙上头条 SC 接入与验证

验证日期：2026-11-25（Asia/Shanghai）。工作分支：dev。工具链：Flutter 3.38.3 / Dart 3.10.1。

## 交付行为

虎牙单直播间的 SC 页及播放器悬浮卡片可接收“上头条”留言。进房后匿名读取尚在展示期内的头条，并接收后续消息。首次列表与实时推送共用解码器及有界去重缓存，重复消息只展示一次；停止房间或切换参数后，迟到的 HTTP 响应不会进入新房间。

卡片显示头像、昵称、正文、虎牙币金额及倒计时。金额依据官网实际使用的 iCostPay / 100 标注“虎牙币”；缺失或负金额使用“上头条”标签。iCost 不作为人民币金额或缺失金额的回退值。B 站和斗鱼没有平台标签时继续沿用原来的人民币/免费显示。

本次沿用应用的 SC 展示，不复刻官网头条面板、礼物动画或官方档位视觉。多开窗口和 TV 端没有新增 SC 展示。

## 协议依据

直接对照当前官方网页生成代码和 Messageboard 组件：

- 普通直播间：https://a.msstatic.com/huya/main3/app/room_normal_0204d2fb.js
- 赛事直播间：https://a.msstatic.com/huya/main3/app/room_match_9b91f15a.js
- 头条组件：https://a.msstatic.com/huya/main3/components_Messageboard_index_tsx_f5b7292d.js

实时业务 URI 为 2001314，载荷为 GameEventMessageBoardPanel。支持 cmd7 单包和 cmd22 批量消息；批量中一个损坏的业务包不会阻止后面的普通弹幕。实时头条只接受当前主播的 live:<presenterUid> 分组，不能使用留言作者的房间字段判断投递房间。

| 结构 | Tag | 字段与用途 |
| --- | --- | --- |
| Panel | 1 | vGameEventMessageBoardInfo：条目列表 |
| Panel | 2 | iPanelState：未知业务含义，不据此推断清空或关闭 |
| Entry | 0 | tMessageUser：昵称和头像 |
| Entry | 1 | sContent：正文，按官网行为解转义 |
| Entry | 4 / 5 | iTotalSec / iCountDown：总秒数、剩余秒数 |
| Entry | 9 | lMessageId：64 位消息 ID |
| Entry | 11 | iLevel：应用内卡片配色参考 |
| Entry | 12 | iCostPay：除以 100 后为虎牙币 |

开始和结束时间由接收时刻与总/剩余秒数估算。剩余时间必须大于零，且限制在总时长内；不能将已经过期的条目重新赋予完整总时长。空面板不主动清空尚未到期的卡片，与官网组件的空列表行为一致。

首次列表请求为匿名 WUPv3 POST https://wup.huya.com/，servant=wupui，method=getHeadLineMessageBoard。请求 tReq：tag0=主播 UID、tag1=空 offset、tag2=匿名 UserId、tag3=scope 0、tag4=pageSize 10。匿名 UserId 的 UID 为 0，UA 为 webh5&0.1.0&websocket，不读取账号 Cookie。

主播 UID 来源为手机页 tProfileInfo.lUid，与同页 tLiveInfo.lUid、流里的 lPresenterUid 和桌面 TT_PROFILE_INFO.lp 对照一致。房间 60066 的主播 UID 为 1867489698，YY 号为 2120076550，两者不能混用。

## 实际采样

### 真实非空初始列表

[test/fixtures/huya_headline_room60066.json](../simple_live_core/test/fixtures/huya_headline_room60066.json) 保存了 2026-11-25 19:59:16.431324 抓取的匿名公开响应及其解码结果。该样本来自自然发生的留言，没有发送付费内容。

- 响应 1781 字节，SHA-256：7bb5db8c8d19f5a5ec9619b9a310a2d52127b167023b2a05ec83fe5eac2aa6c2。
- WUPv3、返回码 0、存在 tRsp，面板包含一条消息。
- lMessageId=3551299；iCostPay=100，对应 1 虎牙币；iCost=1，二者不同。
- iTotalSec=60，iCountDown=12，iLevel=1。
- 未知 tag13=-1 不影响解码；样本含 mExt 的 count、iItemType、lExpireTime、lPid，但这些扩展只有单条证据，本轮不依赖其未充分证实的语义。

另一位审查者以独立 Node Tars 解析器读取原始响应，未调用应用解码器；核对了正文、昵称、头像、金额、总时长、剩余时长和消息 ID，结果一致。回归测试以固定采样时钟重放原始响应。

### 实时连接与订阅兼容性

当前代码向旧 CDN 接收端与 wsapi 接收端发送注册、心跳后，均收到分组注册回包；35 秒采样均收到 cmd7 和 cmd22。旧 CDN 收到 390 个 cmd7、34 个 cmd22；wsapi 收到 250 个 cmd7、34 个 cmd22。该短窗口没有收到自然发生的非空 2001314，不能将它记为非空头条推送实测。

另用两条并行连接核对旧频道注册与额外分组的兼容性：

| 额外订阅 | 普通弹幕包 | 唯一 payload | 重复 payload | 同包最多份数 |
| --- | ---: | ---: | ---: | ---: |
| 仅 live | 9 | 9 | 0 | 1 |
| live + chat | 21 | 12 | 9 | 2 |

因此最终实现保留旧频道注册，只增加头条所需的 live 分组，避免再次订阅 chat 导致普通弹幕重复。离线协议测试锁定该注册列表；这项采样是短时对照，不作为长期零重复的保证。

真实公开空面板 WebSocket 帧也已回归，来源为 https://raw.githubusercontent.com/wzgrx/PureLive/master/fixtures/huya/danmaku/S19-headline/frames.jsonl 。非空实时帧的路由和批量异常隔离通过按官网字段构造的协议样本覆盖，测试中明确区分构造样本与实录。

## 生命周期与显示修复

- 去重 ID 包含主播 UID 和消息 ID；缓存到期清除且最多 2048 条。无效消息不抢占有效消息的去重位置。
- HTTP 使用独立 Dio，连接/发送/接收超时分别为 5/5/8 秒，finally 关闭；读取失败不触发普通弹幕断线。
- 首次列表和实时消息无论哪个先到，相同 ID 都只展示一次。
- 房间停用后递增代际并清空解码缓存；迟到响应同时校验代际、参数对象身份及消息回调。
- SC 列表为卡片提供稳定 key，卡片更换消息时重置倒计时，避免删除前一条后沿用错误剩余时间。
- 悬浮显示截止时间取平台结束时间与本地显示上限的较早者；房间自身负责清理过期 SC，不依赖列表是否挂载。
- 头条适配层修正现有 Tars BYTE 无符号读取对负倒计时/负金额的影响，没有修改全局 Tars 读取规则。

## 自动验证

固定工具链路径：E:/Enviroment/sdk383/flutter/bin/flutter.bat 和 E:/Enviroment/sdk383/flutter/bin/cache/dart-sdk/bin/dart.exe。

| 检查 | 结果 |
| --- | --- |
| 核心离线测试（头条、请求、斗鱼去重、WebSocket 生命周期、斗鱼 passport） | 59 项通过 |
| 应用完整回归（含新增 12 项卡片测试） | 394 项通过 |
| 新增核心模块、共享模型及头条测试静态分析 | 无问题 |
| 6 个应用改动文件及卡片测试静态分析 | 无问题 |
| 改动文件 git diff --check | 通过 |
| Android Release 分架构构建及 APK 验签 | 三个架构构建成功；APK Signature Scheme v2 验签均通过，退出码均为 0 |

核心全量测试含外部平台联网用例，不作为离线验收门槛。核心库整体分析仍有本次工作之外的历史 warning/info；上表的“无问题”对应已明确选择的新增模块与应用改动范围。

复验命令（在对应子项目目录运行）：

~~~text
simple_live_core:
dart.exe test --reporter expanded test/huya_superchat_test.dart test/huya_headline_request_test.dart test/douyu_voice_dedup_test.dart test/web_socket_lifecycle_test.dart test/douyu_passport_test.dart

simple_live_app:
flutter.bat --suppress-analytics test --no-pub --concurrency=2 --reporter expanded
flutter.bat --suppress-analytics build apk --release --split-per-abi --no-pub
~~~

## 安装包交付

2026-11-25 20:14 构建完成，版本名均为 1.12.2，包名为 com.xycz.simple_live。aapt2 核对原生库架构与文件名一致；分架构 versionCode 如下。三个 APK 的 apksigner verify --verbose --print-certs 均返回 Verifies，使用同一发布证书，v2 签名有效。

| 安装包 | versionCode | 字节数 | SHA-256 |
| --- | ---: | ---: | --- |
| [arm64-v8a（通常用于手机）](../simple_live_app/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk) | 15122 | 50,052,804 | 37e9392019af25c0d9d191c8afbad2307b9731e0835ab7799c87568b9c8058b5 |
| [armeabi-v7a（32 位 ARM）](../simple_live_app/build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk) | 14122 | 47,922,340 | b72af344332a8a5d469f8f21806d15335a946b13004d58307284a404ca9dd2fd |
| [x86_64](../simple_live_app/build/app/outputs/flutter-apk/app-x86_64-release.apk) | 17122 | 55,006,743 | 192d77ba6b2d898a82c0492d75427791ea4f4b74cfbd5774ccac2117af99c9a6 |

## 尚未覆盖

本轮 adb devices -l 没有发现连接设备，未安装到 Android 真机验证前后台切换、厂商 ROM、长时间运行及真实实时头条出现时的端到端展示。实际付费消息已验证到 1 虎牙币档位；其他金额、所有礼物类型和全站活动不能视为已经实测。iPanelState、tTarUser 及 mExt 的业务含义只保留已证实的部分。

接收协议、真实初始列表、卡片行为、资源释放与构建验证分别记录，避免以其中一项代替其他项的证据。
