# 开发与维护 / Development and maintenance

用户功能与安装说明见 [中文](../README.md) / [English](../README.en.md)。本页将构建、签名和补丁操作与产品介绍分开。

## 从源码运行 / Run from source

macOS Swift / SwiftUI：

```bash
brew install git-lfs
git lfs install
scripts/prepare_tiktoken_lfs.sh
swift run CodexTokenBar
```

Windows / Tauri：

```powershell
cd tauri-app
npm ci
npm run tauri -- dev
```

## 本地打包 / Package locally

以下为 v0.9.7 示例。开始前核对所有版本文件；macOS 打包会重新创建对应的 `dist/release/v<version>` 目录，请先保留需要的旧产物。Windows 构建目录和签名输出目录必须尚不存在。

These examples target v0.9.7. Check version files first. The macOS packager recreates its versioned output directory; preserve needed artifacts beforehand. Windows build and signing output directories must be new.

```bash
SPARKLE_PRIVATE_KEY_FILE="$HOME/.config/codex-token-bar/sparkle-ed25519-private.key" \
  scripts/build_release.sh v0.9.7
```

发布时另行选择递增的 `APP_BUILD`；不要照抄旧版本的 build 值。Select an increasing `APP_BUILD` when preparing a release.

```powershell
.\scripts\build_tauri_windows_release.ps1 -Version 0.9.7 -Arch both
```

Windows 脚本生成 x64 / ARM64 NSIS 安装器及 `windows-build/build-manifest.json`，不需要 updater 私钥。将完整目录带回签名机器后：

The Windows build requires no updater private key. Transfer the complete build directory to the signing machine:

```bash
TAURI_SIGNING_PRIVATE_KEY_PASSWORD='' \
scripts/sign_tauri_windows_release.sh --version 0.9.7 --repo hututuo/codex-token-bar \
  --build-dir dist/release/v0.9.7/windows-build \
  --release-dir dist/release/v0.9.7/windows \
  --key-path "$HOME/.config/codex-token-bar/tauri-updater.key"
```

如私钥有密码，仅通过 `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` 环境变量提供；显式空密码与未设置有区别。不要在命令参数或日志中写密码。`.sig` 用于 Tauri 更新验证，不等于 Windows 商业代码签名。

Supply any key password through `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`, not command arguments or logs. An explicit empty password differs from an unset variable. Updater signatures are not Windows commercial code signing.

将最终 Windows 资产和平台中间 checksum 清单归入同一版本发布目录，按脚本支持的布局合并最终清单：

Place platform assets and intermediate checksum manifests into the versioned release directory, then merge the final manifest:

```bash
node scripts/merge_release_checksums.mjs --version 0.9.7 --release-dir dist/release/v0.9.7
```

发布资产、更新元数据和 manifest 必须互相核对。平台构建、签名、安装与发布验证是不同步骤。Check assets, update metadata, and manifests separately; build success alone does not establish installation or release success.

## 可选 Codex Desktop 侧栏补丁 / Optional sidebar patch

部分 Codex Desktop 版本只从全局最近会话第一页生成项目侧栏，导致本地存在的会话没有全部显示。可选脚本提供 `install`、`status`、`rollback`。

Some Desktop versions build the project sidebar from the first global recent-session page. The optional patch supports install, status, and rollback:

```bash
curl -fsSL https://raw.githubusercontent.com/hututuo/codex-token-bar/main/scripts/patch_codex_desktop_sidebar.sh | bash -s -- status
# 将 status 改成 install 安装，或 rollback 回滚。Use install or rollback as needed.
```

脚本按 bundle ID 查找 Codex，可用 `CODEX_APP_PATH` 或 `--app PATH` 指定。它备份 `app.asar` 和原签名，修改 renderer 后重新 ad-hoc 签名并打开应用；不修改 Codex Home。官方更新可能覆盖补丁。

The script discovers Codex by bundle ID, accepts an explicit path, backs up the ASAR and signature, patches the renderer, re-signs ad-hoc, and opens the app. It does not edit Codex Home. Official updates can replace the patch.

## 展示页 / Showcase

[制作说明与来源](showcase/README.md)。展示构建与应用构建独立，使用模拟数据，不读取账号或日志。
