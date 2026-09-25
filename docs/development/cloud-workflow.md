# GitHub 托管开发与发布

本文件描述当前项目的托管入口。代码和工作流存在，不代表每一个平台、签名环节或公开发布已经执行成功；实际状态以对应运行和制品清单为准。

## 默认入口

在 GitHub Actions 打开 **Cloud project console**。入口工作流位于默认分支 `main`，但不会因此合并未发布的应用代码。选择操作和 `source_ref` 后，入口先解析为固定的完整提交 SHA。

| 操作 | 执行内容 | 私钥／公开写入 |
|---|---|---|
| `checks` | 前端、Swift、Mac/Windows Rust、发布辅助测试；保存检查证据和可用的视图截图 | 无发布私钥；不发布 |
| `build` | 构建 Mac DMG/ZIP 与 Windows x64/ARM64 NSIS；生成固定 SHA 候选清单 | 无更新签名私钥；不改线上更新 |
| `sign` | 从指定成功运行下载同 SHA 候选和 CI 证据；使用已有更新密钥签名并独立验签 | `release-signing` 环境审批后才使用私钥；不公开发布 |
| `publish` | 下载指定已签名制品，核对摘要、版本与来源，公开既有文件并更新分发清单 | `production-release` 审批＋准确的 `publish-vVERSION` 确认 |

`main` 的控制入口固定引用经过审阅的流水线提交，不动态加载任意分支中的工作流。升级流水线实现时，单独更新入口的固定引用。`source_ref` 可以是开发分支或完整 SHA，但真正执行与制品记录必须使用解析后的完整 SHA。

## 不依赖本地终端的代理入口

拥有仓库写权限的代理可以通过 GitHub 连接，在 `main` 创建一个新的请求文件，例如：

```text
.github/cloud-requests/check-20260925-example.json
```

```json
{
  "operation": "checks",
  "source_ref": "cloud/github-hosted-20260925"
}
```

每次请求必须单独提交，且提交中只新增一个请求文件。`operation` 仅接受 `checks` 或 `build`。这个文件入口不能请求签名、发布、读取密钥或执行任意命令；签名和发布使用网页手动入口并经过环境审批。

普通源代码提交仍可自动触发通用 CI，不必为每次提交增加请求文件。请求文件主要用于代理没有 workflow-dispatch 动作时的显式重跑／候选构建。它们是请求记录，不是长期任务队列。

## 构建环境与缓存

- 前端：Ubuntu 24.04、Node 24、锁文件和官方 npm registry。
- Swift 与打包：托管 macOS 15，明确指定 Xcode 26.1.1；先准备 Git LFS 二进制依赖再运行测试。
- Windows：Windows 2025、Rust 1.93.1、MSVC x64/ARM64 和 NSIS。两个架构始终以真实目标分别构建。
- Rust 测试同时覆盖托管 Mac 和 Windows。原规模 20,001 文件回归不缩小、不额外跳过。

npm、Cargo registry/git、Swift 依赖目录分别缓存。Rust 编译缓存按操作系统、处理器架构、工具链、锁文件和源码 SHA 隔离，允许使用兼容前缀恢复后交给 Cargo 指纹重新判断需要重编译的输入。

Windows 候选流程明确启用 `-ReuseCargoTestCache`。该选项只复用 Cargo 测试输出目录，仍执行全部发布测试；默认本地脚本仍使用独立临时目录。不要将缓存命中写成测试通过，也不要把旧安装器混入新候选目录。

缓存用于加速，不是备份。构建目录、运行日志、候选安装包和永久源码分别管理。日志默认保存 7 天，未签名候选与视图截图 14 天，检查证据和已签名候选 30 天；正式公开版本另由 GitHub Release 保存。仓库缓存额度有限，旧缓存可被淘汰，云端必须能在无缓存时重新构建。

## 视觉验证

Swift CI 复用现有生产视图测试，通过 `CODEX_CYCLE_LAYOUT_OUTPUT` 导出当前／历史周期标题的 PNG，保存在 `swift-visual-previews-<SHA>`。这是具体生产视图的布局预览，不是整个应用、Windows WebView2 或真实桌面生命周期的完整截图认证。缺失截图会在制品上传步骤报告，不能把空目录当成视觉通过。

需要真实交互时，从成功的候选构建运行下载同一 SHA 的 `candidate-macos-<SHA>` 或 `candidate-windows-<SHA>`。Mac ZIP 中包含 DMG 和更新用 ZIP，Windows ZIP 中包含两个架构的安装器与清单。核对 `candidate-manifest.json` 后再安装；不需要在个人电脑上安装 Xcode、Cargo 或 npm，也不需要重新编译。

最初候选可能没有更新签名；它们不能放入正式自动更新通道。Mac ad-hoc 签名与 Sparkle 更新签名、Windows Tauri 更新签名与 Authenticode 是不同机制。当前策略不自动新增 Apple 公证或商业 Windows 代码签名。

## 签名环境的前置条件

`release-signing` 与 `production-release` 均限制为 `main` 并要求所有者审核。签名环境需要配置：

```text
SPARKLE_PRIVATE_KEY
TAURI_UPDATER_PRIVATE_KEY
TAURI_SIGNING_PRIVATE_KEY_PASSWORD  （仅按已有密钥是否加密配置）
```

必须使用已分发版本对应的原密钥；不生成替代密钥来绕过缺失配置。密钥不能进入 Git、制品、日志、聊天内容或普通 PR 任务。签名器将密钥临时写入权限受限的 runner 临时目录，并用当前公开版本的公钥独立验签；不匹配则停止。

私钥尚未安全配置并通过真实签名演练时，这一环节只能标记为“已部署定义，未完成验证”。公开发布还要求中文在前、英文在后的正式说明。保留候选说明，不为了打通流程而误标正式发行。

## 发布顺序与恢复

签名操作绑定 `source_sha`、`build_run_id`、`ci_run_id`；发布绑定同一来源的 `signed_run_id`，不重新编译。公开包包含现有九项资产，不能悄悄删掉 ARM64 或复用另一版本的签名。

发布器先创建或续用草稿，拒绝重定位既有版本标签、覆盖不同内容的资产或把较旧版本标为 latest。上传后回下载全部公开文件核对 SHA256，再公开 Release；确认资产已经可用后才修改 `main/appcast.xml`。签名时记录的旧 feed 已变化时，不覆盖并发更新。

若在 Release 已公开、feed 尚未更新时中断，同一个已签名包可以在检查既有资产相同后续做；这不授权修改已公开的安装器。成功后在 `docs/releases/` 写入云端发布定位记录，包含源码 SHA、构建／检查／签名／发布运行号和资产摘要。

## 本地目录清理边界

不要把“GitHub 上有同名仓库”当成可以删除本地目录的依据。先核对全部分支、标签、stash、各 worktree、未提交及未跟踪文件；本地和远端分叉时分别保留，不强推覆盖。对私有归档做一次独立克隆和 `git fsck --full`。

编译缓存可在云端重建已验证后单独删除，但源代码、未归档资料、密钥备份、用户会话数据库和正在运行的应用不属于可重建缓存。尤其本项目的 `dist` 可能包含正在运行的本地预览包，不能整体删除项目目录。
