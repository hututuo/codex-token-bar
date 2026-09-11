# 真实旧会话备份：v0.9.1 → schema13 验证

2026-09-09。本轮仅使用隔离目录，未替换运行应用、未迁移用户活动库；下午开发环境兼容实现保留，没有增加生产兼容器。

## 数据与生成方式

原始备份为系统工具项目 `backups/20260607-094426_codex-provider-session-meta-unify/session-jsonl.before.tar`，743816704字节。164个旧格式JSONL，文件名日期为2026-02-11至2026-06-07，包含16811条token_count事件。不是手工生成的消费数据，也没有用修改版本号的方式伪造旧索引。

逐成员按原字节复制到两端独立 home，保留 sessions / archived_sessions 目录。通过实际 `v0.9.1`（`6e2889f8ecef771719eb58cab0366f505500c2c5`）的生产解析、同步、建库代码分别生成 Swift schema6 和 Rust schema9。新增调用入口只在测试中。两端正式版都生成 **13112条入账记录**，累计 **1529529287 Token**；token_count原始事件数不等于最终入账次数。

## 当前代码升级结果

| 验证 | Swift 6 → 13 | Rust 9 → 13 |
| --- | --- | --- |
| 13112条旧事件、时间、组件、模型逐字段核对 | PASS | PASS |
| 原版总值保留到legacy_tokens | PASS | PASS |
| 重开无重复入账 | PASS | PASS |
| 升级后首次刷新不重解析历史原文 | PASS，changedFiles=0 | PASS，JSONL full/append读取均0 |
| 再次刷新不重解析 | PASS，changedFiles=0 | PASS，新增读取0 |
| 新增+5探针，再追加+7 | PASS，仅后缀增量 | PASS，full读取不增长 |
| 来源全部消失，已有数值继续保留 | PASS | PASS，实际移走隔离raw目录后再恢复 |

追加行为使用明确可核对的测试探针，历史建库和保全使用全部真实备份。Swift missing场景给同步入口传空文件清单；Rust实际移走隔离sessions目录。两种均不操作真实Codex Home。原始164个文件逐文件SHA256复验保持一致，见verification-manifest。

## 累计差额：明确记录，不能只报告“数据一致”

升级后双端正常用量均为 **1520869610 Token**，比旧版少 **8659677 Token**。涉及143条旧记录，全部仍在库中，旧total也保留；它们由现有组件计费规则归类为异常total-only，不计入正常用量。

本轮对143条记录逐一回到原JSONL对应字节位置，并检查同文件前一条累计：

- 143条的last输入、缓存、输出、推理组件全部为0，只有last.total_tokens非零。
- 138条的完整累计字段与前一条完全相同，累计没有增长。
- 另外5条是首个可比观察，累计所有字段均为0，last.total合计57962。
- 没有任何一条在可比较的累计字段中出现正增长。

这支持现有规则不将它们作为新的已确认消费。没有因此删除旧证据，也没有为保持旧总数把这类数值再加回去。该差额是旧total-only处理与新版组件计费的区别，不是原文截短后清空旧行。完整无正文审计见 `excluded-total-only-audit.json`。

## 容量

仅供这批164个会话的测试对照。对独立测量副本去掉测试对账表并VACUUM后测量，不是用户活动库的升级后容量，也不是升级过程峰值占用。

| 测量副本 | 字节 | 约MB（十进制） |
| --- | ---: | ---: |
| Swift6 | 3661824 | 3.66 |
| Swift13 | 4997120 | 5.00 |
| Rust9 | 23769088 | 23.77 |
| Rust13 | 10293248 | 10.29 |

Rust13测量发生在探针和missing验证后，包含额外两笔、共12 Token。不能按此比例推算本机开发库。未对活动库执行VACUUM。

## 证据与复现入口

证据均在 `runs/20260909-real-history-upgrade/`：

- `input-manifest.json`：备份成员路径、大小、逐文件SHA256。
- `swift-release.log` / `rust-release.log`：v0.9.1建库。
- `swift-current-final.log` / `rust-current.log`：当前升级与增量回归。
- `verification-manifest.json`：版本、原文不变复核、库哈希。
- `excluded-total-only-audit.json` / `storage-measurements.json`：差额与容量证据。
- `swift6.sqlite` / `tauri9.sqlite`：正式版真实生成输入保留。

`scripts/prepare_release_upgrade_validation.py` 包含两种数据的正式版测试生产器。真实备份模式先解包到全新的隔离home，再调用：

```sh
# RELEASE_SOURCE 指向脚本导出的 v0.9.1 源码；所有路径必须为隔离测试目录。
RELEASE_HOME="$SWIFT_TEST_HOME" RELEASE_OUTPUT="$SWIFT_SIX_DATABASE" \
  swift test --package-path "$RELEASE_SOURCE" --filter testExportActualReleaseSixFromHistoricalBackup
CODEX_RELEASE_SWIFT_DATABASE="$SWIFT_SIX_DATABASE" CODEX_RELEASE_SWIFT_HISTORICAL_HOME="$SWIFT_TEST_HOME" \
  swift test --filter ReleaseDatabaseUpgradeTests

RELEASE_HOME="$RUST_TEST_HOME" \
  cargo test --manifest-path "$RELEASE_SOURCE/tauri-app/src-tauri/Cargo.toml" --lib export_actual_release_historical_database -- --nocapture
CODEX_RELEASE_TAURI_HISTORICAL_HOME="$RUST_TEST_HOME" \
  cargo test --manifest-path tauri-app/src-tauri/Cargo.toml --lib actual_release_historical_database_upgrades_and_keeps_incremental_scan -- --ignored --nocapture
```

Rust保持生成旧库时的同一隔离home身份；当前测试会升级该隔离库，重跑应重新生成输入。使用SQLite backup保留旧版副本，不能修改来源身份绕过检查。

## 验收边界

本次证明真实旧原文经正式版建库后能够升级并继续增量，不代表已恢复七月全部历史，也不是安装包/窗口UI/Windows实机验收。之前构造场景的paginated转写去重验证继续保留。本轮没有新增生产兼容逻辑、没有安装、发布或更改本机schema12。
