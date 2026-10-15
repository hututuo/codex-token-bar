# 本机数值索引保留、去重与整轮发布

范围：Swift 原生端；本机构建 0.9.4/905。此前本机 Release 是 0.9.4/904（cbd273a3）。不包含远端推送、合并、公开发布或 Windows/Tauri 验收。

修复三处已复现的问题：

1. UUID 重复时，compact 按来源相加、attribution 按五分钟来源最大值的口径不一致。现在共用可逆 canonical projection，有完整相同证据才排除副本；原始 events 保留，真实新增部分保留，不跨 fork UUID 去重。
2. 分批导入曾提前改变已发布事件、整轮 generation 却尚未更新。现在一个外层 SQLite WAL 事务包含整轮，批次使用 SAVEPOINT；数值、位置、投影、generation 和覆盖证明一起提交。
3. 所有 JSONL 消失后，入口提前返回而隐藏既有账本。现在读取已有数值；归档和普通删除只影响原文可用性。

一并修复续问侧库：缺失来源不再删除 checkpoint/样本/自有轮次；同路径分页重写保存旧 generation；跨代稳定轮次去重，fork 新增轮次保留。缺乏稳定身份的旧 fallback 保守留存，可能重复，不以删除历史推断真相。侧库结构缺损/未知版本停止写入；达到原有 500MiB 预算停止新写，不自动淘汰旧数据。

统一契约与版本：[设计文档](../design/ledger-preservation-publication.md)。主 schema 仍为 14，ledger 组件 revision 2；侧库 schema 2。

升级前对主账本、建议侧库使用 SQLite backup API 保存含 WAL 的一致快照。真实冻结副本含 473463 events / 76104552878 Token；迁移及零来源模拟后保持相同，逐主键比较所有旧事件字段、来源归属均无差异。

可重复审计：

```sh
python3 scripts/audit_usage_index_preservation.py BEFORE.sqlite AFTER.sqlite --output audit.json
```

输入应为一致 SQLite 快照；不能只复制一个仍在写入的主文件而漏掉 WAL。脚本只读，报告丢失事件、逐字段变化、归属变化及 quick_check，不导出日志正文。正负合成样本验证了其能检测丢行和数值改变。

本机原项目证据目录：`runs/20261016-ledger-retention-fix/`。其中 before/ 是首次备份，before-install/ 是停止旧 Bar 后的最新快照，audit-copy/ 是隔离迁移与零来源实验，deployment.json 记录安装身份与运行核验，README.md 登记测试与状态。数据库和运行证据不提交到源码仓库。

回退入口为同目录 rollback-local.py；默认仅核验。revision 2 库禁止直接交给旧程序写入；真正回退要求停止 Bar、明确接受暂时隐藏升级后数据，并先保存升级后完整数据库。保留数据优先，不能用旧快照覆盖唯一新账。

自然低命中弹窗触发、长时间 FPS/功耗、所有雷达绑定及 Windows 运行不属于本次数值索引修复的通过结论。

## English

The native macOS fix preserves numeric history independently of raw rollout availability, uses one reversible canonical projection for duplicate evidence, and commits complete scan generations atomically. Cache-advice history also survives source removal and paginated rewrites, while stable fork-owned rounds remain distinct. Unknown identities are retained conservatively.

Local build 0.9.4/905 is a local deployment only. Consistent SQLite backups, isolated migration checks, field-by-field event preservation reports and the installation receipt are kept outside the source repository. An older application must not write the upgraded ledger; rollback preserves the newer database first. No public release or Windows runtime acceptance is implied.
