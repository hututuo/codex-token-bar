# PR #8 与当前恢复分支的增补

核查基线：本分支产品 `02c493fae3ccbf76df21524771cee4802a330d0e`，文档 HEAD `2e64e187dc7ea65ea565e58f4a82f960f5bd19b5`。外部 PR [shawway #8](https://github.com/hututuo/codex-token-bar/pull/8) 冻结在 `3cbd383f3daf3f37ab6b5ac52676895c18a5440a`，本地只抓取审计 ref。整合提交 `f6582f3d` 的父提交为 #6 的 `41058ffe` 和 #7 的 `faa06a5b`。不再整份合并。

## 已确认的增补范围

1. Swift 重试替换的旧历史覆盖。当前实际存储模块、一次性 SQLite 探针中：A 原有两条事实，新候选删除其中一条，原代码接受替换并只剩一条。此前的“目标仍是冻结导入镜像”检查只保护目标未被改写，不能证明候选完整。新增反向覆盖校验；从 durable import receipt 找回同目录 UUID 绑定的 normalized 镜像，以全结构、类型、隐藏 rowid、重复数和序列证明旧历史，再在原子写事务中复核目标和源。相同候选的 no-op 仍保留 A 后来产生的独立事实。正常追加、受限额度维护时钟推进、Exact 模型/轮次补全和派生投影重算分别用窄口径证明，不能一律当成历史丢失拒绝。只读 Exact 证明算法及相关测试改编自 #8；保留本分支 admission、池化暂存和指标。
2. Swift 活着的旧库路径别名。实际存储模块探针：physical support 完成导入后，改用指向同目录的 alias，旧库仍存在，重启报 unmigratedInput。现有测试只覆盖 alias 后旧叶子已删除。新增按真实父目录、叶子、设备/inode、catalog 和 journal 所有权核对的别名复用；不能凭内容相等、同名或其他路径硬链接改归属。保留已知 receipt/source key，不建立第二份账本。
3. Rust 已导入但未发布的历史。正常发布前校验与历史补全两入口，在原始日志确实消失时，验证 pending 的完整数值、代次、引用后继续发布并撤销原文可读标记；不能用 tombstone 清掉待发布事实。重导入前后在同一事务中核对旧数值及已知关联，仅允许 NULL 补全；发布补齐 canonical 的四个 prompt/assistant 边界。采用 #8 的相关保全实现，保留本分支固定 stage pool。另补 #8 未覆盖的 pending_fingerprints 未知列防护，避免可空未知字段在删除/重建时丢失。
4. Rust Exact 路径身份。静态代码及隔离文件系统/hash/catalog 探针确认：符号链接根下多级父目录从不存在到存在时，旧 fallback 身份会变，A-only 旧 owner 查不到。该探针尚不是 Rust 产品入口执行。计划采用 #8 有界路径候选及实际 catalog owner 复用；多份不同事实不能任选、覆盖或合并。只读 miss 不能注册/创建。

## 不采用的部分与边界

- 不整份搬入 #8 的启动/UI/更新控制和额外诊断系统；未证明它们是这次数据保全修复的必要依赖。
- 不倒退本分支已实现的只读 admission、空闲连接 quiescence、固定 stage pool、有限重试和诊断。#8 的 Windows park 路径曾删除 quiescence，不能照搬。
- 不改 A/B 原始事实、费用规则、永久库数量；不重构性能架构、不新建清理系统、不操作用户数据库。
- 上一轮 `02c493fa` 的云端成功不覆盖本次新增代码。当前为增补实现/验证中；完整 Exact 和 Rust 双端验证完成后另记录实际 SHA、run 和结果。
- 未合并 main、未安装/替换/启动正式应用、未打包/签名/发布，未请求 Anthropic。
