# 本地 main 收拢记录（2026-09-07）

本轮按用户授权审查未提交代码与全部本地分支，分组提交、合入本地 main，并清理多余分支。未授权远端推送或发布。

## 工作区代码

起点 `393048f0` 位于 `codex/token-accounting-standard-api-20260906`。25 个已跟踪文件的改动完整保留，按三个维护单元提交；共享 CSS 按 hunk 分组。

| 提交 | 内容 |
|---|---|
| `9aaa9680` | Swift/Tauri 会话深链、元数据搜索及测试 |
| `84c456c9` | Swift/Tauri 悬浮窗紧凑行高、间距和窗口几何及测试 |
| `0bbf6056` | Radar 额度范围说明、跳转图表、两步选点引导，以及 Swift 曲线开关即时刷新和汇总值展示 |

这些提交整合既有未提交实现；本轮没有额外改变额度回溯算法、安装或切换运行中的应用。

## 分支判定

盘点时共有 29 个本地分支、1 个 worktree。当前工作线已包含已获取的 `origin/main@29b77776`，本地旧 main 为 `924dcf14`。

- 6 条分支（包含当前工作线和旧 main）已在当前提交的祖先链上。
- 13 条历史分支经 `git cherry` 核对，没有独有补丁。
- 10 条仍有独有提交哈希的分支已逐项比对集成提交或当前实现，判定为已移植或已被后续实现替代。

| 旧提交 | 当前实现或处理依据 |
|---|---|
| `79f7e479` | exact index 保留 dashboard 数值版本；refresh/startup 缓存使用该版本 |
| `866f143a` | Swift 使用 contentView 发起拖拽；旧 model 行高已被当前紧凑布局替代 |
| `ba8117d2` | `347cc148` 引入共享 floatingPresentation，当前 live/preview 均使用该模块 |
| `1ce2070a` | 集成提交 `d884596f`；不恢复旧 attribution-generation 回退 |
| `c5933a2c` | 集成提交 `1883b5d7`；当前仍有 Kathmandu 日边界测试 |
| `a781c4e9` | 集成提交 `f93d1e47`；当前保留最终迁移提交条件 guard |
| `db703f5b` | 集成提交 `b8c40cdf` 及后续 `e58c4b4c`；不恢复旧快照覆盖路径 |
| `e4b9e743` | `941a081c`、`9d108f15` 保留推理字段及迁移；当前拒绝未来 catalog 版本 |
| `9acad753` | 混合 WIP 的 WAL 重试、错误传播、刷新参数、numeric attribution、拖拽/预览已保留；旧估算 UI 已替代 |
| `6bfa19b6` | v0.9.1 草稿由最终双平台发布记录覆盖，不恢复旧“待上传”状态 |

不使用伪造的 ours merge 标记这些分支已合并。保留历史后删除分支引用，实际 main 采用快进合入。

## 本地证据与恢复

目录：`runs/20260907-main-consolidation/`（Git 忽略）。

- `branch-inventory.json`：清理前所有分支的完整 tip。
- `branch-decisions.json`：每条分支判定与依据。
- `ported-range-diffs.txt`：主要移植提交对比。
- `branches-before-consolidation.bundle`：23 条非祖先历史分支及其独有提交，已执行 `git bundle verify`。这是增量 bundle，依赖本仓库保留的 main 祖先，不可当作独立仓库备份。
- `bundle-heads.txt`、`bundle-verify.log`：备份引用和校验记录。
- `initial-working-tree.patch`：分组提交前的完整已跟踪改动。
- `local-materials/`：14 份本地研究、审计、交接材料，按原相对路径保存；共 628,217 字节，未删除内容。
- `local-materials-manifest.json`：每份材料原路径、归档路径、长度及 SHA-256；移动后已逐文件验证。

恢复非祖先分支时，在本仓库运行（替换 BRANCH 为清单中的完整分支名）：

```sh
git fetch runs/20260907-main-consolidation/branches-before-consolidation.bundle refs/heads/BRANCH:refs/heads/BRANCH
```

已在 main 祖先链中的分支可直接用清单的 tip 重建。材料可依据 manifest 从归档路径移回原路径。本轮只整理分支引用与本地材料位置，不执行磁盘缓存清理；不将材料归档量当作释放空间。

## 验证

验证结果及最终 main 指针记录在本地 `verification.json`。Swift 专项 330 项、前端专项 117 项通过；前端 TypeScript/Vite 构建通过（仍有既有分块大小和静态/动态导入警告）。Swift 全套执行 1,434 项，0 失败、4 项跳过：两个 live auto-resume、一个 live Crowd Radar API、一个本机完整历史扫描，均因显式启用环境变量未设置而跳过。

运行界面、安装、Windows 构建、远端推送、tag 和发布均不作为本轮通过项。


## 下午：悬浮窗与统计进度分支收束

用户授权提交剩余源码、合并本地分支，并替换双端进行交互测试。主工作区没有待提交源码；另一个工作区只有本地 node_modules 符号链接，已在本地 exclude 中排除，不进入版本控制。

main 先快进到 `7371332791e6893861bdcbc77bb4c8e1b44ca2a6`，再合并 `fix/dock-dashboard-reopen-20260907`，合并提交为 `bd297513`，没有冲突。此次保留了 Swift 上下约 5 点留白，以及精确统计标签和后台进度所有权修复。以下分支 tip 全部已进入 main 祖先链，使用安全的 `git branch -d` 收束引用：

| 分支 | 原 tip |
|---|---|
| `codex/continuous-dock-paint-20260907` | `090fc5575e6dc308658d83b253666c8abaf4280d` |
| `codex/floating-edge-dock-20260907` | `de113d11f99fe22143700496386b83f623c1b708` |
| `codex/vertical-details-drawer-20260907` | `7371332791e6893861bdcbc77bb4c8e1b44ca2a6` |
| `fix/dock-dashboard-reopen-20260907` | `edc04fdf3daf78e7f8ccd173cc04fdc1154cf20e` |

仅移除了已合入的分支引用；原有工作区文件保留，另一工作区切到原提交的 detached HEAD。恢复分支可用表中 tip 重新创建。详细清单在 `runs/20260907-floating-edge-dock/consolidated-main-branches.json`。

全量验证：Swift 执行 1,462 项，0 失败、4 项环境依赖测试跳过；前端最终 1,024 项全部通过。Rust 初次全量 1,046 通过、3 失败、5 忽略；三项失败均为 live-rate 缓存测试使用仅含 total_tokens 的旧样例，补齐输入/输出明细后，该模块 49 项全部通过。未修改生产记账策略。前端另修正独立雷达拖动测试的显式布局样例，并将 Happy DOM 不支持的 calc 除法高度断言交给生产 CSS 的离屏 WebKit 几何核验；上下展开、卡片宽度和留白实测通过。

双端构建成功。本地替换的最终 main、源文件哈希、二进制哈希、PID、签名与回退位置见 `runs/20260907-floating-edge-dock/consolidated-main-activation.json`。真实交互交给用户测试；Windows 未运行，本轮不推送、打 tag 或发布。
