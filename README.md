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

<!-- 截图区（发布前替换）
![首页](/assets/screenshot_light.jpg)
![直播页](/assets/screenshot_dark.jpg)
-->

## 功能特性

### 播放
- **斗鱼音频线路**：在「线路」中选择「🎧 音频线路」即可只听声音，只接收音频数据，
  相比普通线路可大幅节省流量，适合用流量听直播。
- **只播放声音**：一键关闭画面只保留声音；与音频线路联动 —— 选音频线路会自动开启，切回普通线路会自动关闭。
- **后台播放**：退到后台或锁屏后继续播放，Android 端以低优先级通知常驻，不易被系统回收。

- **弹幕表情渲染**：聊天区与画面上的弹幕都能显示平台表情。
  B站使用弹幕自带的表情图，抖音使用内置表情包（无需联网加载）。

### 直播间信息
- **开播时长**：直播中显示主播已经开播了多久。
- **上次开播时间**：未开播时显示主播上一次开播的时间（多久之前 + 具体日期时间）。
- **醒目留言（SC）**：直播间画面内可显示醒目留言内容。

### 分区与列表
- **关注列表**：对不同平台的主播可以进行筛选。未开播的直播间弱化显示，更容易找到正在直播的主播。
- **局域网同步**：可在两台设备间同步关注、标签、观看记录；
  **同步方向可自选**（本机覆盖对方 / 对方覆盖本机），设备列表会显示双方关注数量便于判断。

### 账号
- **哔哩哔哩**：支持扫码、网页、Cookie 三种登录方式，登录状态更稳定。
- **斗鱼**：支持扫码登录，也可手动填写 Cookie。
- **抖音**：支持填写完整 Cookie，或仅填写 ttwid。
- **虎牙**：无需登录。

## 支持平台

| 平台 | 直播 | 弹幕 | 发送弹幕 | 音频线路 |
| --- | :---: | :---: | :---: | :---: |
| 哔哩哔哩 | ✅ | ✅ | ✅ | — |
| 斗鱼 | ✅ | ✅ | — | ✅ |
| 虎牙 | ✅ | ✅ | — | — |
| 抖音 | ✅ | ✅ | — | — |

## 客户端

- [x] Android
- [x] Windows
- [ ] iOS / macOS / Linux / Android TV（原项目支持，本版本未验证）

## 下载

**普通用户**：直接下载打包好的安装包即可使用 ——
Android 安装 APK；Windows 下载 ZIP 后解压，运行 `simple_live_app.exe`
（整个文件夹需一起保留）。

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
```

## 项目结构

- `simple_live_core`：核心库，各直播平台的信息获取与弹幕解析。
- `simple_live_app`：Flutter 客户端（Android / Windows 等）。
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
- 抖音表情映射表：参考自 [xuanxuan123xuan/simple-live-kuaishou](https://github.com/xuanxuan123xuan/simple-live-kuaishou)

## 许可

沿用原项目许可：[GPL-3.0](LICENSE)。
