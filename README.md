# Simple Live（增强版）

> 基于 [xiaoyaocz/dart_simple_live](https://github.com/xiaoyaocz/dart_simple_live) 的个人自用增强版。
> 在原项目基础上补充了一些实用功能，并对日常使用体验做了调整。
>
> **仅供个人学习与自用，请勿用于商业用途；直播内容版权归各平台与主播所有。**

<p align="center">
    <img width="128" src="/assets/logo.png" alt="Simple Live logo">
</p>
<h2 align="center">Simple Live</h2>
<p align="center">简简单单的看直播</p>

![首页](/assets/screenshot_light.jpg)
![直播页](/assets/screenshot_dark.jpg)

## 功能特性

### 播放
- **斗鱼音频线路**：在「线路」中选择「🎧 音频线路」即可只听声音，只接收音频数据，
  相比普通线路可大幅节省流量，适合用流量听直播。
- **只播放声音**：一键关闭画面只保留声音；与音频线路联动 —— 选音频线路会自动开启，切回普通线路会自动关闭。
- **后台播放**：退到后台或锁屏后继续播放，Android 端以前台服务和媒体通知常驻，不易被系统回收；通知和锁屏媒体卡支持播放、暂停、停止，以及上一台/下一台切换，并显示主播头像、平台角标和平台名。

### 多开直播
- **同时观看多路**：桌面端最多 4 路，手机/平板最多 2 路，默认仍是单房间；每路独立音量、静音、清晰度、线路和弹幕开关，切换聊天/发送目标不会影响其他房间的声音。
- **添加与管理**：可从「正在直播」的关注主播中多选，也可粘贴直播间链接；支持替换、关闭，拖动标题栏交换画面。
- **布局与全屏**：桌面支持左右/上下双屏、左一右二、上一下二、四宫格和左一右三，可拖动分割条调整比例；单路可临时放大，顶栏或 F11 进入整窗全屏，Esc 逐层退出。
- **弹幕列表与发送**：手机端可通过聊天入口查看当前选中房间的弹幕列表，底栏为当前选中房间的弹幕发送框，发送目标跟随当前画面选择。
- **保存与恢复**：可保存房间、布局比例、逐路音量/静音、弹幕开关和聊天目标，并在再次进入时选择恢复；存档不包含 Cookie、Token、签名或临时播放地址。

### 弹幕
- **发送弹幕**：哔哩哔哩、斗鱼、虎牙均可在直播间直接发送弹幕；发送长度按各平台上限自动截断，emoji 按一个字符计算，不会切坏表情。
  斗鱼发送贴近官方客户端：登录态临近过期自动静默续期，平台限流或回执超时按「已发出」处理，不会频繁弹错。
- **弹幕表情渲染**：聊天区与画面上的弹幕都能显示平台表情。
  B站支持**直播间专属表情包**（进房间后自动拉取该房间的表情表，按原图比例缩放）；斗鱼支持按房间拉取钻粉/房间图片表情，抖音使用内置表情包（无需联网加载）。
- **屏蔽图片表情**：「弹幕设置」里可一键屏蔽整条只有图片表情的弹幕，支持 B站直播间专属表情、斗鱼钻粉/房间表情、虎牙图片表情；含文字的弹幕与全站 emoji 不受影响。
- **关键词屏蔽**：按关键词过滤弹幕。
- **快捷发送与复制**：Enter 在无输入框时打开、空内容时收起、有内容时发送，输入法确认候选词不会误发；桌面左键/右键点击弹幕、移动端单击弹幕可复制弹幕正文或「昵称：内容」。

### 直播间信息
- **开播时长**：直播中显示主播已经开播了多久。
- **上次开播时间**：未开播时显示主播上一次开播的时间（多久之前 + 具体日期时间）。
- **醒目留言（SC）**：直播间画面内可显示醒目留言内容；画面内的 SC 卡片为半透明浮层，10 秒后自动消失，不挡画面。斗鱼高能弹幕（付费留言/语音弹幕）也会进入 SC 页展示，支持免费高能弹幕、头像、金额和过期倒计时。

### 通知与提醒
- **特别关注开播提醒**：关注设置中开启后，每分钟检查一次特别关注主播，从未开播变为开播时发送系统通知；首次检查只建立状态基线，不补发历史开播提醒。需保持应用运行并允许系统通知。

### 分区与列表
- **关注列表**：对不同平台的主播可以进行筛选，并新增「特别关注」筛选；未开播的直播间弱化显示，更容易找到正在直播的主播。
- **观看记录**：按平台分类筛选并显示条数；手机竖屏使用半屏底部弹层，手机横屏和桌面端保持右侧面板。
- **局域网同步**：可在两台设备间同步关注、标签、观看记录，以及已登录账号（Cookie）；账号可一键全部同步，也可按平台单独同步。
  **同步方向可自选**（本机覆盖对方 / 对方覆盖本机），设备列表会显示双方关注数量便于判断。
- **搜索联动**：首页搜索默认在当前所在平台内搜索。

### 账号
- **哔哩哔哩**：支持扫码、网页、Cookie 三种登录方式，登录状态更稳定。
- **斗鱼**：支持扫码登录，也可手动填写 Cookie；Cookie 含 `LTP0` 时，播放 token 临近过期会自动静默续期，减少重新登录。
- **虎牙**：支持扫码登录，也可手动填写 Cookie（发送弹幕需要登录）；登录态失效时会提示重新登录，不再出现「显示已登录、实际发不出弹幕」。
- **抖音**：支持填写完整 Cookie，或仅填写 ttwid；登录后显示账号昵称。
- **Cookie 输入**：支持多行粘贴，可直接粘贴整段 cURL 自动提取 Cookie。

## 支持平台

| 平台 | 直播 | 弹幕 | 发送弹幕 | 登录方式 |
| --- | :---: | :---: | :---: | :--- |
| 哔哩哔哩 | ✅ | ✅ | ✅ | 扫码 / Web / Cookie |
| 斗鱼 | ✅ | ✅ | ✅ | 扫码 / Web / Cookie |
| 虎牙 | ✅ | ✅ | ✅ | 扫码 / Cookie |
| 抖音 | ✅ | ✅ | ❌（平台风控，暂不支持） | Cookie / ttwid |

> Web 登录只在手机端显示入口（B站限 Android / iOS，斗鱼限手机竖屏）；桌面窗口用扫码或 Cookie。

## 客户端

- [x] Android（已验证）
- [x] Windows（已验证）
- [x] macOS（CI 手动构建，提供 arm64 / x64 ZIP 与 DMG）
- [x] iOS（可自行编译；本版本未提供构建产物）
- [x] Linux（CI 构建，未广泛实机验证）
- [ ] Android TV（暂未提供构建）

## 下载

前往 **[Releases](https://github.com/Otiosum-coder/dart_simple_live/releases)** 页面下载最新版本：

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| **Android**（大多数手机） | `SimpleLive-x.y.z-arm64-v8a.apk` | 64 位 ARM，绝大多数手机选这个 |
| Android（老设备） | `SimpleLive-x.y.z-armeabi-v7a.apk` | 32 位 ARM |
| Android（模拟器） | `SimpleLive-x.y.z-x86_64.apk` | x86 设备 / 模拟器 |
| **Windows 便携版** | `SimpleLive-x.y.z-windows-x64.zip` | 解压后运行 `simple_live_app.exe`，**整个文件夹需一起保留** |
| Windows 安装程序 | `SimpleLive-x.y.z-windows-x64-setup.exe` | 安装后可从开始菜单启动，并可卸载 |
| **Linux 便携版** | `SimpleLive-x.y.z-linux-x64.zip` | 解压后运行 `bundle/simple_live_app` |
| Linux Debian / Ubuntu | `SimpleLive-x.y.z-linux-x64.deb` | 使用系统软件包安装器安装 |
| macOS Apple Silicon | `SimpleLive-x.y.z-macos-arm64.zip` / `SimpleLive-x.y.z-macos-arm64.dmg` | 手动构建；DMG 内可拖入 Applications |
| macOS Intel | `SimpleLive-x.y.z-macos-x64.zip` / `SimpleLive-x.y.z-macos-x64.dmg` | 手动构建；DMG 内可拖入 Applications |

> APK 使用正式签名，可直接覆盖安装升级，无需卸载旧版本。
> macOS ZIP / DMG 与 iOS IPA 仅在手动工作流中构建；macOS 包未公证，首次打开可能需要右键选择「打开」。iOS IPA 未签名。

## 自行编译

需要 Flutter 3.38 或更高版本：

```bash
cd simple_live_app
flutter pub get

# Android
flutter build apk --release --split-per-abi

# Windows（插件源码含中文注释，需指定 UTF-8，否则部分环境会编译失败）
set CL=/utf-8
flutter build windows --release

# macOS（connectivity_plus 7.1+ 需要 Xcode 26 SDK，务必先切到 Xcode 26）
sudo xcode-select -s /Applications/Xcode_26.3.app
flutter build macos --release

# iOS（不签名 ipa）
flutter build ios --release --no-codesign

# Linux（需要系统依赖）
sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libasound2-dev libmpv-dev
flutter build linux --release
```

## 项目结构

- `simple_live_core`：核心库，各直播平台的信息获取与弹幕解析。
- `simple_live_app`：Flutter 客户端（Android / Windows / macOS / iOS / Linux）。
- `simple_live_app/third_party/canvas_danmaku`：支持表情的弹幕渲染库。
- `simple_live_console` / `simple_live_tv_app`：原项目的控制台与 TV 客户端，本版本未改动。

## 参考及引用

- [xiaoyaocz/dart_simple_live](https://github.com/xiaoyaocz/dart_simple_live)：本项目的基础
- [Predidit/canvas_danmaku](https://github.com/Predidit/canvas_danmaku)：弹幕渲染库，表情渲染基于它实现
- [xiaoyaocz/AllLive](https://github.com/xiaoyaocz/AllLive)：本项目的 C# 版
- [dart_tars_protocol](https://github.com/xiaoyaocz/dart_tars_protocol.git)
- [wbt5/real-url](https://github.com/wbt5/real-url)
- [lovelyyoshino/Bilibili-Live-API](https://github.com/lovelyyoshino/Bilibili-Live-API/blob/master/API.WebSocket.md)
- [IsoaSFlus/danmaku](https://github.com/IsoaSFlus/danmaku)
- [BacooTang/huya-danmu](https://github.com/BacooTang/huya-danmu)

## 许可

沿用原项目许可：[GPL-3.0](LICENSE)。
