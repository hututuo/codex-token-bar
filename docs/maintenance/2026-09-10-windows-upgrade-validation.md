# Windows 实机升级验收

2026-09-10。主机 `HTTWIN`，Windows x64，用户 `htt`。通过既有 SSH 连接执行。测试根目录 `C:\Users\HTT\CodexTokenBarUpgradeReview20260910`。源码基线 `50251cb7c7b75108267862e3352d95927e11cccf` 加工作树；首次完整传输的 927 个源码文件逐一 SHA256 校验，后续仅同步下述修复。

## 实机发现并修复的生产缺陷

`prepare_schema11_candidate_if_needed` 读取旧库对账信息的 `source_connection`，在调用候选恢复/切换时仍存活。SQLite 的 Windows 文件句柄不共享删除权限，导致程序自己持有的旧库句柄阻止重命名：

> 无法为 schema 11 活动库建立受管回滚副本：另一个程序正在使用此文件，进程无法访问。 (os error 32)

首次 Windows 整库回归结果为 1047 PASS、15 FAIL、10 IGNORE；15 个失败集中在该迁移路径，包含实际结构 schema9 升级、中断恢复和旧索引 enrichment。根代理在持有应用操作锁的原作用域内，读出独立的对账事实后立即 `drop(source_connection)`，再进入候选切换。未改变对账规则、旧库保全、互斥或计费策略。

修复文件 `tauri-app/src-tauri/src/core/usage/token_count_jsonl/exact_usage_index.rs`；该次修复后 SHA256 `d43ffd10795f5989ef9a2df5f4d9aca268c47b2375e3e67d9b5ef007f7a4cbdc`。

## 已完成门禁

| 项目 | 结果 | 证据（本项目 runs/20260910-windows-upgrade） |
| --- | --- | --- |
| Windows native 目录句柄与 FlushFileBuffers | PASS，打开/刷盘均成功、错误码 0 | `flush-probe.log` |
| Windows 候选刷盘与容量预检 | PASS 2 | Windows `logs/candidate-durability.log` |
| 修复后 Windows Rust lib 回归 | PASS 1062、FAIL 0、IGNORE 10，另过滤 20001 文件规模用例 | `windows-lib-regression-final.log` |
| macOS 迁移/中断恢复交叉回归 | PASS 6 | `macos-migration-after-handle-fix.log` |
| Windows 前端生产构建 | PASS | Windows `logs/frontend-build.log` |
| Windows 本机实际 v0.9.1 生成旧库 | PASS，schema9、13112 行 | `actual-release9-export.log` |
| 真实旧库 9→13、首次/再次刷新、增量、缺失保全 | PASS，首次 full/append 原文读取 (0,0)，warm 0 | `actual-release9-to13.log` |
| 实际旧库指定路径搬迁、目的旧库不覆盖 | PASS，13112 行、原文读取 0 | `actual-release9-relocation.log` |
| x64 优化构建、旧版与候选 NSIS 安装包 | PASS，两份生成成功 | `release-installer-build.log`、`candidate-installer-build.log` |

164 个历史 JSONL 由上一轮隔离原文按字节打包到 Windows，全部 SHA256 核对。正式版生产代码由本地 `git archive v0.9.1` 导出，只有测试导出入口追加；没有给当前库修改版本号。旧 total-only 差额沿用前一轮逐原文审计：1529529287 → 1520869610，旧行和旧 total 保留，不意味着账目丢失。详见 [真实历史审计](2026-09-09-real-history-upgrade.md)。

整库回归中 IGNORE 的实际旧库升级和目录搬迁随后已显式执行通过。需要真实账号、执行 Codex 自动续跑、指定其他真实样本的手动测试未执行；没有对真实账号触发任何任务续跑。

## 安装与界面验收范围

使用同一生产源码构建两份隔离 NSIS 安装包，包名 `Codex Token Bar Upgrade Review`、identifier `local.codex.token-bar.tauri.upgradereview`；旧版配置 0.9.1，候选仅在测试包配置中使用 0.9.2。关闭 updater 制品签名生成，没有更改仓库版本、签名密钥或正式发布文件。

独立安装目录 `InstalledApp`；仅子进程的 APPDATA / LOCALAPPDATA 指向测试根目录下 `ui-data`，设置指向 `historical-home`，没有覆盖用户原有 0.9.0 兼容测试安装或真实数据目录。

旧版静默安装成功；通过一次性命名计划任务在用户 Session 12 启动，进程持续存活并响应，旧库保持 schema9 / 13112 行。第一次截图实际是 Windows 锁屏，**不能把窗口句柄和 Responding=true 写成视觉验收通过**；已请求用户解锁。之后仅结束本次记录的旧版测试 PID，并保存其已关闭数据库文件族，再执行候选覆盖安装。

候选运行、数据目录搬迁与实际窗口显示状态将在本轮结束前补充。本报告不代表 Windows ARM64 实机、正式 updater 签名/分发或多显示器验收。测试源码和数据副本不混入正式运行环境。


## 2026-09-11 后续状态补记

候选安装包覆盖安装 exit 0，Session 12 进程响应正常。安装后旧缓存和持久目录均为 schema13，13,112 条记录、1,520,869,610 Token。

**安装后追加增量验收 FAIL（待调查）**：`runs/20260910-windows-upgrade/installed-incremental.log` 显示新文件 +5 的轮询结束仍为 1,520,869,610，预期 1,520,869,615。不能用此前 core 增量测试代替安装后运行验收；未完成后续 +7 和重启验证。旧版窗口截图是锁屏，实际窗口视觉验收仍 NOT_RUN。

用户转入 9 月 11 日均一化金额功能。Windows 测试安装包不包含该新功能；独立测试目录及计划任务保留，后续继续时须检查并收束。未触碰原 0.9.0 用户安装。
