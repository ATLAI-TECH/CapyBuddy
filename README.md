<div align="center">

# CapyBuddy

**Your friendly Mac companion — a menu-bar multi-tool.**

100% free and open source. No paywall, no accounts, no tracking.

**English** · [中文](#中文)

![Menu bar](push/01-menu-bar.png)

</div>

## What it does

CapyBuddy lives in your menu bar and bundles a set of everyday Mac utilities.
Turn individual tools on or off in **Settings → General**, and choose which
ones appear in the dropdown in **Settings → Menu Bar**.

| Tool | Description |
|------|-------------|
| **Screenshot** | Capture a region with a global hotkey, then annotate, OCR, copy, save, or pin it. |
| **Screen Recording** | Capture full-screen, a window, or a drag-selected region to MP4/MOV with optional system audio and microphone. |
| **Video Editor** | Play, trim, crop, mute or re-speed a clip and export it — handy right after a recording. |
| **Clipboard** | Keeps a history of recent clipboard items so you can paste anything you copied earlier. |
| **Keep Awake** | Prevents your Mac from sleeping or dimming the display for a chosen duration. |
| **System Monitor** | A menu-bar status item showing live CPU, memory, and other system stats. |
| **Picture Converter** | Drag-and-drop conversion between PNG, JPEG, HEIC, TIFF, GIF, AVIF, ICO, BMP, ICNS, JP2. |
| **Compressor** | Compress and extract zip, tar, tar.gz, and gz archives. |
| **QR Code** | Generate QR codes — colors, dot/eye shapes, embedded logo, save or copy. |
| **Space Shortcut** | Hold Space and tap a key to instantly launch or focus your most-used apps. |

<div align="center">

![Screenshot tool](push/02-screenshot.png)
![Clipboard](push/03-clipboard.png)
![System monitor](push/05-system-monitor.png)

</div>

## Install

Download the latest notarized `CapyBuddy.app` from the
[**Releases**](https://github.com/ATLAI-TECH/CappyBuddyOfficial/releases) page,
unzip it, and drag it to `/Applications`. The app auto-updates via Sparkle.

Some tools need permissions you grant on first use:
- **Screen Recording** — Screenshot, Screen Recording
- **Accessibility** — Space Shortcut, snap-to-element screenshots, recording hotkey

> CapyBuddy is distributed directly (Developer ID, notarized) rather than via the
> Mac App Store, because features like Space Shortcut rely on a global event tap
> that the App Store sandbox forbids. See `design/DISTRIBUTION_STRATEGY.md`.

## Build from source

Requirements: macOS, Xcode 16+, an Apple Developer ID (only needed for signing
a distributable build).

```bash
git clone https://github.com/ATLAI-TECH/CappyBuddyOfficial.git
cd CappyBuddyOfficial
open CapyBuddy.xcodeproj   # then build & run the "CapyBuddy" scheme
```

Or from the command line:

```bash
xcodebuild -project CapyBuddy.xcodeproj -scheme CapyBuddy -configuration Debug build
xcodebuild -project CapyBuddy.xcodeproj -scheme CapyBuddy test
```

### Cutting a release

`scripts/release.sh` archives, signs, notarizes, staples, zips, and regenerates
the Sparkle `appcast.xml`. It needs your Developer ID certificate, a notary
credential profile, and Sparkle's signing key — see the header of the script.

## Architecture

Each tool conforms to the `Feature` protocol (`CapyBuddy/Core/Feature.swift`)
and is registered in `AppDelegate`. `FeatureRegistry` owns lifecycle
(start/stop) and persistence of enabled/visible state. UI is SwiftUI; the
menu-bar plumbing is AppKit (`MenuBarManager`).

## License

[MIT](LICENSE) © AtLAI-tech.

---

<div align="center">

## 中文

**你的 Mac 贴身小助手 —— 一个菜单栏多功能工具箱。**

完全免费、开源。没有付费墙，无需账号，不收集任何数据。

[English](#capybuddy) · **中文**

</div>

### 功能介绍

CapyBuddy 常驻菜单栏，把一系列日常 Mac 小工具集成在一起。在 **设置 → 通用**
里可以单独开启/关闭每个工具，在 **设置 → 菜单栏** 里选择哪些工具显示在下拉菜单中。

| 工具 | 说明 |
|------|------|
| **截图** | 全局快捷键框选截图，支持标注、OCR 文字识别、复制、保存、贴图。 |
| **录屏** | 录制全屏、单个窗口或拖选区域为 MP4/MOV，可选系统声音与麦克风。 |
| **视频编辑** | 播放、裁剪、剪裁画面、变速、静音并导出 —— 录屏后顺手就能用。 |
| **剪贴板** | 保留最近复制的历史记录，随时粘贴之前复制过的内容。 |
| **防休眠** | 在设定的时长内防止 Mac 休眠或屏幕变暗。 |
| **系统监控** | 在菜单栏实时显示 CPU、内存等系统状态。 |
| **图片转换** | 拖拽转换 PNG、JPEG、HEIC、TIFF、GIF、AVIF、ICO、BMP、ICNS、JP2 等格式。 |
| **压缩** | 压缩与解压 zip、tar、tar.gz、gz 等归档格式。 |
| **二维码** | 生成二维码 —— 自定义颜色、码点/定位点形状、内嵌 Logo，可保存或复制。 |
| **空格快捷启动** | 按住空格再敲一个键，瞬间启动或切换到常用 App。 |

### 安装

从 [**Releases**](https://github.com/ATLAI-TECH/CappyBuddyOfficial/releases)
页面下载最新已公证的 `CapyBuddy.app`，解压后拖到 `/Applications`。应用通过 Sparkle 自动更新。

部分工具首次使用时需要授权：
- **屏幕录制权限** —— 截图、录屏
- **辅助功能权限** —— 空格快捷启动、截图智能贴边、录屏快捷键

> CapyBuddy 通过开发者 ID 直接分发（已公证），而非 Mac App Store。因为像空格快捷启动这类
> 功能依赖全局事件监听（global event tap），App Store 沙盒不允许。详见
> `design/DISTRIBUTION_STRATEGY.md`。

### 从源码构建

环境要求：macOS、Xcode 16+，以及 Apple Developer ID（仅在签名分发版本时需要）。

```bash
git clone https://github.com/ATLAI-TECH/CappyBuddyOfficial.git
cd CappyBuddyOfficial
open CapyBuddy.xcodeproj   # 然后构建并运行 "CapyBuddy" scheme
```

或使用命令行：

```bash
xcodebuild -project CapyBuddy.xcodeproj -scheme CapyBuddy -configuration Debug build
xcodebuild -project CapyBuddy.xcodeproj -scheme CapyBuddy test
```

#### 发布新版本

`scripts/release.sh` 会自动归档、签名、公证、装订（staple）、打包，并重新生成
Sparkle 的 `appcast.xml`。需要你的 Developer ID 证书、公证凭据（notary profile）
以及 Sparkle 签名密钥 —— 详见脚本头部说明。

### 架构

每个工具都遵循 `Feature` 协议（`CapyBuddy/Core/Feature.swift`），在 `AppDelegate`
中注册。`FeatureRegistry` 负责生命周期（start/stop）以及启用/可见状态的持久化。
界面用 SwiftUI，菜单栏部分用 AppKit（`MenuBarManager`）。

### 许可证

[MIT](LICENSE) © AtLAI-tech。
