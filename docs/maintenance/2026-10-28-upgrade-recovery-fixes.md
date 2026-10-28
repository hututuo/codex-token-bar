# 升级重试恢复修复

分支：`codex/upgrade-recovery-fixes`，基于 `codex/startup-and-local-quota` 的 `3a945511`。本分支修复 [此前审计](2026-10-28-upgrade-compatibility-audit.md) 发现的两个问题。未合入 main、未打包、未替换本机或 Windows 正式应用。

## 已实现

- Mac 在现有 A 的 `tb_container_meta` 中持久化本批待导入来源与目标分区，先记批次再导入。重试重新核对并替换该未激活批次；已激活分区及其中后续写入的记录不参与替换。源文件消失会停止激活，恢复文件后可重试。完成状态与清除待处理批次在同一事务提交。
- Windows/Tauri 按分区记录待导入来源、是否属于首次 bootstrap、以及是否允许重建未激活分区。每份来源复制、核对完成后，首次启动仍保留批次，直到全局 initialized marker 发布；后续模块失败不会提前冻结前面来源。全局发布前检查全部待处理来源，包括本次扫描已找不到的来源。给已激活分区补相同来源时只校验，不获得覆盖新账的权限。
- Windows 备份先写唯一短名临时文件，完成在线复制、校验、转为单文件 DELETE journal 模式、同步落盘，再同目录原子发布。不完整备份和 WAL/SHM/journal 按同一文件组隔离保留，不会污染新快照。有效同内容备份直接复用。
- 新增状态使用现有 metadata，不增加业务库、不改历史行、主键或价格，不更改容器 schema v1 的结构。
- 源码中更老版本留下的“未完成且没有批次记录”的情况，无法安全判断哪些分区已经承接新账。遇到不明批次或来源已变化时保留全部数据并明确报错，不能猜测覆盖或静默发布缺失结果。正常已经升级完成的用户不受影响；这类既有损坏状态需要依据保留来源/备份单独恢复。

## 验证内容

原来“期望两条、实际一条”的 Mac 隔离复现已转成正式回归测试，并检查其他已激活分区的新记录仍保留。覆盖未变化重试、源文件缺失再恢复、旧版本不明批次拒绝激活、成功后冻结旧来源。

Rust 覆盖首次导入期间来源变化再重试、已有 A 新增模块导入失败、其他分区新账保留、首次全局初始化前来源消失、不带批次的旧导入不得静默发布、损坏备份与附属文件保留/恢复、有效备份复用、失败快照不发布。实际生产备份的长文件名也经过路由测试。

最终测试结果见本文件下方补记。测试日志在 `scratch/upgrade-repair-*`；这些日志不作为发布包内容。

## 最终验证

- Swift 应用：2,070 项、20 项条件跳过、0 失败；本地采集 8 项、Agent Speed 649 项均通过。日志 `scratch/upgrade-repair-swift-final.log`。
- Rust 全量：1,493 通过、11 ignored、0 失败。日志 `scratch/upgrade-repair-rust-final.log`。
- UI 全量：1,298 通过、0 失败；TypeScript `--noEmit` 通过。日志 `scratch/upgrade-repair-ui-full.log`、`scratch/upgrade-repair-tsc.log`。
- Windows：`cargo xwin check --target x86_64-pc-windows-msvc --lib --offline --locked` 通过；日志 `scratch/upgrade-repair-windows-check.log`。本次没有 Windows EXE 运行/覆盖安装验收。
- `git diff --check` 通过。此次没有打包、安装或重启正式应用。

首次全量发现一个旧颜色常量断言和备份继承 WAL 模式的问题，已分别更新颜色预期、将备份转换为完整单文件后重跑通过。Swift 测试 helper 的 Sparkle 加载路径已在测试命令环境中明确指定，没有修改产品依赖或安装路径。

## 合并范围

迁移修复涉及 Swift migration + tests、Rust route/container + tests，未改共享容器 DDL。请保留“待导入批次、完成提交、备份原子发布”三部分一起合并。

本分支同时有独立的模型配色提交，文档在 `docs/design/2026-10-28-model-palette/说明.md`。两项可分别 cherry-pick；修复依赖原基础分支的后台启动门禁，不能只合 UI 而放行尚未完成迁移的业务 owner。
