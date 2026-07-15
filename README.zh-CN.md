# VBAN Receiver for macOS

<p align="center">
  <img src="Resources/AppIconTransparent.png" width="96" alt="VBAN Receiver 图标">
</p>

<p align="center">
  <strong>一个原生 macOS VBAN 音频接收器。</strong><br>
  从 VoiceMeeter 接收 VBAN UDP 音频流，并通过 macOS 默认输出设备播放。
</p>

<p align="center">
  <a href="README.md">English README</a>
  ·
  <a href="docs/wiki.md">详细 Wiki</a>
  ·
  <a href="docs/wiki.en.md">English Wiki</a>
</p>

<p align="center">
  <img alt="macOS 13+" src="https://img.shields.io/badge/macOS-13%2B-2f8ef7">
  <img alt="Apple Silicon arm64" src="https://img.shields.io/badge/Apple%20Silicon-arm64-111827">
  <img alt="Objective-C" src="https://img.shields.io/badge/Objective--C-AppKit-334155">
  <img alt="CoreAudio" src="https://img.shields.io/badge/Audio-CoreAudio-0f766e">
  <img alt="VBAN" src="https://img.shields.io/badge/Protocol-VBAN-f97316">
</p>

![VBAN Receiver 主界面](docs/assets/vban-receiver-app.png)

## 接收中状态

![VBAN Receiver 接收中](docs/assets/vban-receiver-receiving-zh.png)

## 主要功能

- 原生 AppKit 界面，支持中文和英文切换。
- 当前版本是 Apple Silicon `arm64` / `aarch64` 架构构建。
- 通过 UDP 接收 VBAN AUDIO 数据包。
- 将 PCM 音频播放到 macOS 默认输出设备。
- 可按流名和发送端主机过滤。
- 支持音量、静音、自动修复和延迟策略。
- 提供数据、丢包、过滤、错误和队列状态计数。

## 快速开始

要求：

- macOS 13 或更高版本。
- Apple Silicon Mac，例如 M1/M2/M3/M4。当前 release 不是 Universal binary，不包含 Intel `x86_64` 架构。
- Xcode Command Line Tools。

在仓库根目录构建并打开 app：

```bash
make test
make app
open "dist/VBAN Receiver.app"
```

不打包 app、直接运行命令行程序：

```bash
make build
./.build/VBANReceiver
```

## VoiceMeeter 设置

1. 在 VoiceMeeter 中打开 `VBAN`。
2. 启用一个 outgoing stream。
3. 目标 IP 填这台 Mac 的局域网 IP。
4. 端口使用 `6980`，除非你在 app 里改过。
5. 音频格式建议使用 PCM，例如 `48 kHz / 16-bit / stereo`。

## 使用说明

![VBAN Receiver 使用说明](docs/assets/vban-receiver-usage-guide.png)

1. 填写 UDP 端口，默认是 `6980`。
2. `流` 留空表示接收任意 VBAN 流，也可以填写指定流名。
3. `来源` 留空表示接收任意发送端，也可以填写发送端主机名或 IP。
4. 点击 `开始接收`。
5. 根据网络情况调整音量、静音、自动修复和延迟策略。

## 支持的输入

- UDP 上的 VBAN AUDIO 数据包。
- PCM 8-bit、16-bit、24-bit、32-bit integer。
- PCM 32-bit float 和 64-bit float。

压缩 VBAN 编码、serial/text 等非音频子协议会被忽略。

## 播放选项

延迟菜单用于控制播放前和播放中的音频缓冲量：

- `最佳`：默认策略，适合普通局域网环境。
- `快速`：队列更短，适合稳定网络下追求更低延迟。
- `中等`：增加缓冲，适合偶发网络抖动。
- `慢速`：更深缓冲，适合不稳定 Wi-Fi。
- `非常慢`：最大缓冲，适合数据突发或不可靠的音频流。

## 打包说明

`make app` 会在 `dist/` 下生成 Apple Silicon `arm64` app bundle，并用 ad-hoc 签名用于本机测试。若要公开分发 `.app`，仍需要 Developer ID 签名和 notarization。

## 工具链说明

本项目基于 Objective-C/AppKit，使用 `clang` 构建。构建时需要 Xcode Command Line Tools，但无需安装完整 Xcode。当前 release 是仅包含 `arm64` 架构的 Mach-O，面向 Apple Silicon，不是 Universal binary。

## 贡献者

- [XiaoLeXLDW](https://github.com/XiaoLeXLDW) - 项目创建与维护。
- OpenAI Codex - 开发、文档与发布协作。
