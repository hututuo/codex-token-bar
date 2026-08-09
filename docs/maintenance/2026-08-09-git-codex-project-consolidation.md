# Git 仓库与 Codex 项目收束

2026-08-09，本项目在不改动产品源码、不推送远端和不发布的前提下，收束为一个正式 Git 仓库、一个 Codex 项目，以及按任务建立的临时 worktree。

## 正式入口

- 仓库：`/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard`
- 主分支：`main`
- 远端：`https://github.com/hututuo/codex-token-bar.git`
- 源码整合点：`8366de8aa93ebfa5fae92cf6508f1c8ace97212d`
- 整合前安全分支：`archive/pre-consolidation-20260809-154939@bd3dd5cd345853af57b7d43f8b4cfa94dd2a1d10`
- Codex 项目：`codex-token-dashboard`，ID `f7e683a4-6ce1-4b2c-96d7-44f201cb870b`
- 已迁入任务：`019f91ad-afbf-73d0-bfbe-45e4234e823b`

正式仓库原本已存在，因此没有再次 `git init`，也没有复制源码重建历史。独立的 Windows 迁移研究仓库拥有不同 Git 历史，继续保持分离。

## 分支与历史处理

- `fix/precise-history-stability-20260808@6ed4bcf2` 是完整最新源码线，以正常 merge `600751d6` 合入旧 `main`。
- crowd radar、floating widget 和 startup statistics 分支已经是该源码线的祖先，随正常 merge 一并进入 `main`。
- quota cycle 两项独有提交由 `git cherry` 证明 patch-equivalent，以零树差异 merge `1f2273a4` 连接历史。
- unread sidebar 分支由 range-diff 证明已被当前主线同等实现并补有更新测试，以零树差异 merge `761107d7` 连接历史。
- 旧 Swift peer WAL 分支被更窄、更安全的 `d31f3da` 替代，以零树差异 merge `8366de8a` 连接历史，未倒灌会全局改写普通 SQLite sidecar 路径的旧实现。
- 三个历史连接提交均通过 `git diff-tree --exit-code HEAD^1 HEAD`，确认相对第一父提交没有产品树变化。

## 清理与保留

六个 inactive clean worktree 通过 `git worktree remove` 删除；七条已安全可达的本地分支只用 `git branch -d` 删除。约释放 12 GiB 可重建 worktree 与构建缓存。

只保留 `feature/model-share-visualization@b147c994` 及其 linked worktree，因为固定构建/发布前任务仍有进程以该目录为 cwd。它已经是 `main` 祖先，但只能在所属任务结束、worktree clean、无进程占用后再按相同门禁收束。

后续任务从正式 `main` 创建 `codex/<task-name>`，worktree 放在 `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/<task-name>`。完成后先合入 `main`，再安全删除临时 worktree 和分支。

本次没有 push、tag、远端分支删除、发布、部署、生产重启、强制重置或未提交数据清除。
