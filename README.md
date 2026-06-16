# Codex Token Bar

简体中文 | [English](#english)

<table align="center">
  <tr>
    <td align="center" width="180">
      <img src="Assets/AppIcon.png" width="112" alt="Codex Token Bar app icon"><br>
      <strong>Codex Token Bar</strong>
    </td>
    <td align="center" width="280">
      <img src="Assets/wechat-group-qr.jpeg" width="220" alt="HTT 的仓库交流群二维码"><br>
      欢迎扫码加入群聊，讨论使用问题、交流想法，也会发布产品发布和更新通知。
    </td>
  </tr>
</table>

Codex Token Bar 是一个本地优先的 macOS SwiftUI 应用，用来从本地 Codex 日志和账号接口查看 token 用量、实时输出速度、缓存命中率、Codex 额度和重置卡详情。

<p align="center">
  <img src="Assets/DashboardPreview.png" alt="Codex Token Bar 主界面截图" width="100%">
</p>

<p align="center">
  <img src="Assets/FloatingPanelPreview.png" alt="悬浮实时 token 速率窗口" width="420">
</p>

## 亮点

- 全会话实时 token 速率，支持悬浮窗、透明度、缩放和单会话下钻。
- 年度 token 热力图、最近 24 小时 5 分钟粒度曲线、缓存命中率曲线和缓存排行。
- Codex 5h / 7d 额度显示、本地轻量历史记录和“使劲蹬”等节奏提示。
- 重置卡详情：显示可用重置机会、每张卡的状态、来源、发放时间、到期时间和使用记录。
- “会话消失修复”向导：扫描、备份、修复、验证和多备份回滚。
- 本地优先：读取 `~/.codex` 本地数据，不上传 prompt、输出、日志或账号额度。
- Sparkle 更新检查：菜单栏 `Codex Token Bar -> 检查更新...`。

## 为什么

Codex 的本地日志里已经有很多有用信息，但平时很难快速看清“今天用了多少”“现在输出多快”“缓存是不是命中”“额度够不够烧”。这个应用把这些本地数据整理成一个轻量 dashboard，并提供一个不挡视线的小悬浮窗。

## 特色：重置卡详情

Codex Token Bar 会读取 Codex 自己使用的本地账号接口，把“重置机会 / 重置卡”展示成可读详情。你可以看到当前有几张可用重置卡、每张卡是否可用、什么时候发放、什么时候到期、是否已经开始兑换或使用完成，以及来源说明。

这个功能是只读的：应用只展示信息，不会调用消耗重置卡的接口，也不会上传账号额度或会话内容。

## 安装

推荐从 [GitHub Releases](https://github.com/hututuo/codex-token-bar/releases/latest) 下载最新 `.dmg`：

1. 下载 `CodexTokenBar-v0.5.1-macos-arm64.dmg` 和 `SHA256SUMS-v0.5.1.txt`。
2. 可选校验：

```bash
shasum -a 256 CodexTokenBar-v0.5.1-macos-arm64.dmg
cat SHA256SUMS-v0.5.1.txt
```

3. 打开 DMG，把 `Codex Token Bar.app` 拖到 Applications。

这个构建是 ad-hoc 签名，尚未 Apple notarize。首次打开如果提示“未知开发者”：系统设置 -> 隐私与安全 -> 找到 `Codex Token Bar` -> 点“仍要打开” -> 确认“打开”。

备用一行安装方式：

```bash
curl -fsSL https://raw.githubusercontent.com/hututuo/codex-token-bar/main/install.sh | bash
```

脚本会下载 GitHub Releases 里的 `CodexTokenBar.app.zip`，安装到可写的 `/Applications`，否则安装到 `~/Applications`，只移除该 App 上的 `com.apple.quarantine` 标记并打开应用。

## 更新

App 内置 Sparkle 更新检查。首次引导或菜单栏可以开启“自动检查更新”；开启后，App 会定期读取 GitHub 上的 `appcast.xml`，发现更高版本后弹窗提示，由你确认后再安装，不会静默替换应用。

也可以随时打开菜单栏 `Codex Token Bar -> 检查更新...` 手动检查 GitHub appcast 中的更新。

也可以重新运行一行安装命令，它会下载 latest release 并替换本地 App：

```bash
curl -fsSL https://raw.githubusercontent.com/hututuo/codex-token-bar/main/install.sh | bash
```

## 可选：Codex Desktop 侧边栏补丁

部分 Codex Desktop 版本会只从全局最近会话第一页生成项目侧边栏。如果某个 workspace 的很多本地会话不在第一页里，侧边栏就可能只显示几条对话，但本地数据库其实还在。

Codex Token Bar 附带一个可选的本机热补丁脚本：

```bash
curl -fsSL https://raw.githubusercontent.com/hututuo/codex-token-bar/main/scripts/patch_codex_desktop_sidebar.sh | bash -s -- install
```

查看状态：

```bash
curl -fsSL https://raw.githubusercontent.com/hututuo/codex-token-bar/main/scripts/patch_codex_desktop_sidebar.sh | bash -s -- status
```

回滚到最近一次备份：

```bash
curl -fsSL https://raw.githubusercontent.com/hututuo/codex-token-bar/main/scripts/patch_codex_desktop_sidebar.sh | bash -s -- rollback
```

脚本会备份 `app.asar` 和原始签名，本地改写 Codex Desktop renderer bundle，重新 ad-hoc 签名 `Codex.app` 并重新打开。它不会修改 `~/.codex` 数据。后续官方 Codex 更新可能会覆盖这个补丁。

## 数据源

应用会把包含以下内容的目录视为 Codex Home：

```text
sessions/
state_5.sqlite
```

`sessions/` 用于精确 token_count、缓存命中率和会话轮次统计。`state_5.sqlite` 在可用时用于补充会话元数据。账号额度通过本地 Codex 账户接口读取，并只把轻量额度百分比历史写入 `~/Library/Application Support/CodexTokenBar/quota-history.sqlite`。

## 从源码运行

```bash
brew install git-lfs
git lfs install
scripts/prepare_tiktoken_lfs.sh
swift run CodexTokenBar
```

精确 `o200k_base` tokenizer 依赖一个 Swift 二进制 FFI 包。准备脚本只会获取此应用需要的 macOS binary slice。如果 tokenizer 运行时不可用，应用会回退到轻量校准估算。

## 本地打包

调试包：

```bash
scripts/package_app.sh debug
```

发布包：

```bash
SPARKLE_PRIVATE_KEY_FILE="$HOME/.config/codex-token-bar/sparkle-ed25519-private.key" \
  scripts/build_release.sh v0.5.1
```

发布脚本会生成 `.app`、DMG、Sparkle zip、兼容安装 zip、`SHA256SUMS` 和 `appcast.xml`。私钥文件不要提交到 Git。

## License

MIT

---

## English

Codex Token Bar is a local-first macOS SwiftUI app for reading local Codex logs and account endpoints to show token usage, live output speed, cache hit rates, Codex quota, and reset-credit details.

<p align="center">
  <img src="Assets/DashboardPreview.png" alt="Codex Token Bar dashboard screenshot" width="100%">
</p>

<p align="center">
  <img src="Assets/FloatingPanelPreview.png" alt="Floating live token-rate panel" width="420">
</p>

## Highlights

- Live all-session token speed with a compact floating panel, opacity, scaling, and session drill-down.
- Yearly token heatmap, 5-minute recent activity chart, cache hit-rate curve, and cache hit ranking.
- Codex 5h / 7d quota display with lightweight local history and compact pace hints.
- Reset credit details: see available reset credits, status, source, grant time, expiry time, and redemption history for each credit.
- Session disappearance repair wizard with scan, backup, repair, verify, and rollback list.
- Local-first: reads local `~/.codex` data and does not upload prompts, outputs, logs, or quota data.
- Sparkle update checking from `Codex Token Bar -> Check for Updates...`.

## Why

Codex already writes useful local usage data, but it is hard to see the current speed, daily burn, cache behavior, and quota pace at a glance. Codex Token Bar turns those local files into a small dashboard and an unobtrusive floating meter.

## Feature: Reset Credit Details

Codex Token Bar reads the same local account endpoint used by Codex and turns reset credits into a readable detail view. You can see how many reset credits are available, whether each credit is usable, when it was granted, when it expires, whether redemption has started or completed, and the human-readable source note.

This feature is read-only: the app displays the information but never calls the endpoint that consumes a reset credit, and it does not upload quota data or conversation content.

## Installation

Download the latest `.dmg` from [GitHub Releases](https://github.com/hututuo/codex-token-bar/releases/latest):

1. Download `CodexTokenBar-v0.5.1-macos-arm64.dmg` and `SHA256SUMS-v0.5.1.txt`.
2. Optionally verify:

```bash
shasum -a 256 CodexTokenBar-v0.5.1-macos-arm64.dmg
cat SHA256SUMS-v0.5.1.txt
```

3. Open the DMG and drag `Codex Token Bar.app` to Applications.

This build is ad-hoc signed and is not Apple notarized. macOS may show an "unidentified developer" warning on first launch. Download only from the official release page and verify the SHA256 checksum before opening.

Backup install:

```bash
curl -fsSL https://raw.githubusercontent.com/hututuo/codex-token-bar/main/install.sh | bash
```

The script downloads the official `CodexTokenBar.app.zip` release asset, installs to `/Applications` when writable or `~/Applications` otherwise, removes quarantine only from the installed app, and opens it.

## Update

The app includes Sparkle update checking. You can enable automatic update checks from the first-run guide or the macOS app menu. When enabled, the app periodically reads the GitHub `appcast.xml`; if a newer version is available, it asks you before installing. It does not silently replace the app in the background.

You can also use `Codex Token Bar -> Check for Updates...` from the macOS app menu at any time.

You can also re-run the backup install command to replace the app with the latest GitHub release.

## Optional Codex Desktop Sidebar Patch

Some Codex Desktop builds populate a project sidebar from only the first global recent-conversation page. Codex Token Bar includes an optional local hot patch:

```bash
curl -fsSL https://raw.githubusercontent.com/hututuo/codex-token-bar/main/scripts/patch_codex_desktop_sidebar.sh | bash -s -- install
```

Status:

```bash
curl -fsSL https://raw.githubusercontent.com/hututuo/codex-token-bar/main/scripts/patch_codex_desktop_sidebar.sh | bash -s -- status
```

Rollback:

```bash
curl -fsSL https://raw.githubusercontent.com/hututuo/codex-token-bar/main/scripts/patch_codex_desktop_sidebar.sh | bash -s -- rollback
```

The patch backs up `app.asar` and the original signature, rewrites the Codex Desktop renderer bundle locally, ad-hoc re-signs `Codex.app`, and reopens Codex. It does not modify `~/.codex` data.

## Data Sources

The app treats a folder with the following entries as Codex Home:

```text
sessions/
state_5.sqlite
```

`sessions/` powers precise token_count, cache hit-rate, and turn-level statistics. `state_5.sqlite` supplements session metadata. Account quota history stores only lightweight percentage samples in `~/Library/Application Support/CodexTokenBar/quota-history.sqlite`.

## Run From Source

```bash
brew install git-lfs
git lfs install
scripts/prepare_tiktoken_lfs.sh
swift run CodexTokenBar
```

The exact `o200k_base` tokenizer uses a binary Swift FFI package. If it cannot load, the app falls back to a calibrated lightweight estimator.

## Package Locally

Debug app:

```bash
scripts/package_app.sh debug
```

Release assets:

```bash
SPARKLE_PRIVATE_KEY_FILE="$HOME/.config/codex-token-bar/sparkle-ed25519-private.key" \
  scripts/build_release.sh v0.5.1
```

The release script produces the app bundle, DMG, Sparkle zip, compatibility zip, `SHA256SUMS`, and `appcast.xml`. Never commit the private key file.

## License

MIT
