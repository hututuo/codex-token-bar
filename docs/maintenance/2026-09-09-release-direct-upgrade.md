# v0.9.1 正式升级验收

后续已完成164个真实旧会话的正式版建库 → 13 验证，见 [真实历史数据结果](2026-09-09-real-history-upgrade.md)。其中8659677 Token的旧total-only差额已回查原文，不能只报告累计一致。本文件下面保留较早小数据集和七月库尝试的记录。

2026-09-09。本轮遵循最新要求：保留下午已经实现的本机开发库处理，先验收正式用户升级；不新增开发版本兼容器、不安装或迁移本机活动库。

## 主证据

基线为 `v0.9.1` / `6e2889f8ecef771719eb58cab0366f505500c2c5`。从 git tag 导出代码，仅追加测试调用入口，272 个生产源文件与 tag 逐文件比较一致。没有修改数据库版本号或删改当前库来模拟正式版。

| 链路 | 本轮结果 |
| --- | --- |
| v0.9.1 Swift 解析旧格式 JSONL，实际生成 schema6 | PASS |
| 该 schema6 → 当前 schema13，原组件和旧 total 保全、重复打开 | PASS |
| Swift 转写只剩部分旧记录并新增：100 → 105；正常追加到112；来源缺失保留112 | PASS；追加走 incremental |
| v0.9.1 Rust 解析旧格式 JSONL，实际生成 schema9 | PASS |
| 该 schema9 → 当前 schema13，原组件保留 | PASS；结构升级 JSONL 读取计数不增长 |
| Rust 转写100 → 105、重开稳定、追加112、来源缺失仍112 | PASS；正常追加不触发 full parse |

这些是由正式版实际代码生成的隔离小数据集（每端起始两笔消费），不是用户大库，也不是实际安装包/Windows 验收。此前广泛回归继续作为其他场景证据，不用本轮小数据集代替规模和全部异常验证。

证据目录：`runs/20260909-release-direct-upgrade/`。成功日志：`swift-release-generated.log`、`swift-current-upgrade-v2.log`、`rust-release-export.log`、`rust-current-upgrade-v3.log`；来源 commit、输入库版本及 SHA256 见 `manifest.json`。

## 七月旧库的实际限制

后续按用户提示重新查找，确认仍有真实旧原文：`/Users/huyiyang/AI agent/Codex/_keep/projects/system-tools/backups/20260607-094426_codex-provider-session-meta-unify/session-jsonl.before.tar`，743816704字节，164个JSONL，161个包含token_count，共16811条token_count事件；文件名日期2026-02-11至2026-06-07，164个header均未标记paginated。本次流式检查所有成员的session_meta/token_count相关行未发现JSON解码错误，不表示已验证所有正文行。与七月库1093个来源有160个session ID相交，不能补齐整个七月库。它可以用于真实旧格式原文 → v0.9.1建库 → 13的补充验收；目前只完成盘点，未解包或运行该数据集。详情见 `historical-jsonl-backup-inventory.json`。此前“缺旧原文”应限于缺少完整对应集合，不是本机完全没有旧原文。

`protected-2.sqlite` 确认为 schema2、146000条事件。先在独立副本上关闭 WAL 后交给 v0.9.1；正式版增加字段并保留行，但因旧模型信息仍需原文同步，不会仅靠打开数据库就提交 schema6。代码在 `eventEnrichmentRequiresSync` 分支明确等待原文补全。故 **2 → 6 → 13 的真实七月大库链路未通过**，不能强改标记来报告成功，也不为此新增生产适配器。

四十多万行 schema12 副本只证明开发库保全，不能充当正式升级主证据。本轮不继续处理该开发库。

## 兼容代码范围

| 类别 | 本轮处理 |
| --- | --- |
| 正式版 Swift6 / Rust9 入口 | 主验收路径，使用实际旧代码生成输入 |
| 结构转换、组件计费转换、候选发布恢复 | 共用同一次升级流程；其中11/12是已有转换或恢复状态，不新增两两版本转换 |
| Legacy / paginated 原文解析 | 长期输入格式，输出统一事件；不是数据库版本兼容矩阵 |
| 旧账保留、原文关联、追加检查点 | 共用运行逻辑，两种格式不复制一套账本 |
| 已完成的开发版本处理 | 按用户最新指示原样保留，本轮不删、不扩展；后续再处理本机 |

本轮生产实现未增加兼容分支，新增的是正式版生成器及当前升级回归。仍然不能宣称已经删完现有开发兼容代码；本轮授权是先留着。

## 复现

从项目根目录选择全新的隔离路径，勿复用已有证据或真实 Codex Home：

```sh
TASK_RUN="$PWD/runs/release-direct-recheck"
python3 scripts/prepare_release_upgrade_validation.py "$TASK_RUN/release"
mkdir -p "$TASK_RUN/inputs"

RELEASE_HOME="$TASK_RUN/inputs/swift-home" RELEASE_OUTPUT="$TASK_RUN/inputs/swift6.sqlite" \
  swift test --package-path "$TASK_RUN/release" --filter testExportActualReleaseSixFromLegacyJSONL
CODEX_RELEASE_SWIFT_DATABASE="$TASK_RUN/inputs/swift6.sqlite" CODEX_RELEASE_SWIFT_HOME="$TASK_RUN/inputs/swift-home" \
  swift test --filter ReleaseDatabaseUpgradeTests

RELEASE_HOME="$TASK_RUN/inputs/tauri-home" \
  cargo test --manifest-path "$TASK_RUN/release/tauri-app/src-tauri/Cargo.toml" --lib export_actual_release_database
CODEX_RELEASE_TAURI_HOME="$TASK_RUN/inputs/tauri-home" \
  cargo test --manifest-path tauri-app/src-tauri/Cargo.toml --lib actual_release_nine_upgrades_rewrites_and_appends -- --ignored --nocapture
```

Rust 当前测试会升级上述隔离 home，重复执行应重新生成隔离环境。必须沿用正式版生成时的同一 home 路径；把数据库直接复制到另一个 home 会正确触发来源身份不匹配。保留原版库可在当前升级前用 SQLite backup 单独导出，不能改身份绕过检查。

## 剩余边界

- 实际安装包、运行中的双端应用、Windows 实机：NOT_RUN。
- 本机 schema12、历史补差、开发兼容清理：按用户要求后续处理。
- 未替换应用，未迁移活动数据库，未提交、推送或发布。
