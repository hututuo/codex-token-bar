# 2026-11-28 兼容性续查

所有编译、原生测试和打包仍通过云端执行。本次未替换安装包或发布。

## 全量原生回归失败与修正

前序 `7959996e7a7606bca4eb747711cf57fa31b280ea` 的 CI `46045084012` 在 macOS/Windows 均因 35 分钟 job 上限取消。两端最后完成的测试相同：`schema_admission_rejects_complete_tables_with_incompatible_keys`；没有完整 native summary 或 execution report，不能记作全量通过。压力测试尚无完成证据。

已确定的生产缺陷：

- `ensure_schema` 在 `BEGIN IMMEDIATE` 中从同一连接执行在线备份。锁定的 SQLite 3.50.2 会持续返回 `SQLITE_BUSY`，rusqlite 0.37.0 的 `run_to_completion` 持续重试。修正保留迁移写锁和事务内 admission，在任何 DDL 前通过独立只读连接生成已提交快照。已有升级测试增加 DELETE/WAL 两种模式，核对活跃 WAL、旧数据、备份版本、迁移前表集合及 integrity；未来 schema 拒写保持原断言。
- JSONL 的未完成 checkpoint 在文件大小不变时无条件回到 offset 0，导致正常 Gemini/Claude 分块无法继续。现在只有同尺寸且完整 fingerprint 改变时重扫；完整 fingerprint 相同的分块继续旧 offset，追加与同尺寸改写检测保留。

两端另有相同的 11 个测试报告 FAILED。除上述分页缺陷，还发现四组过期 fixture：

- 四项 quota history 测试使用 schema 0 的空内存库，违反新 B2 写入围栏；改用已有完整 B2 fixture，保留百分比、去重与组织/客户端隔离断言。
- activity v1 迁移 fixture 同时声明 B marker 与未来版本 17；改为支持的 B2，保留旧行、索引和 source 隔离。独立 standalone 任意版本保全及未来 B 拒写测试继续存在。
- future-schema legacy JSON importer 测试使用不符合 `body-speed-<identity>.sqlite` 合同的文件名，尚未到达目标拒写路径；修正名称，保留无备份、零行与版本保全断言。
- 四项 Claude 大记录测试的 checkpoint helper 缺少 entrypoint v3 与物理 witness。按新合同严格比较完整指纹，offset/size/mtime/账本重放断言保留。

相关升级、分页、quota 和 activity 测试加入 CI 必执行清单。上述失败的具体 panic 未从旧日志取得：libtest 尚未输出最终失败详情即超时；fixture 原因来自确定性的源码对照，实际结果以本次修正后的完整云端回归为准。

本次本地仅运行轻量脚本：execution gate 15 项、workflow contract 9 项、CI evidence gate 5 项及 vendor provenance 全部通过。

## 已完成证据及边界

- 精确 `6add665b4efde0965a30c493d886041690c6ef4f` 的公开 v0.9.7 升级 `46046493653` 双平台成功：macOS 8 项升级和 126 项支持回归；Windows 3 项 importer、生产恢复 probe 与 19 类 manifest 情景。原始输入哈希、精确来源及保全证明已复核。
- 同 SHA 的 SpeedEngine 配对 `46046493657` 成功，35 项语义比较通过；四种 workload 的 CPU 中位数下降约 80.0%–94.6%。这是合成子系统测量，不是整 App 资源验收。
- `995a4050f74cafb9143578c3c3c85ae951737b2c` 的整 App 配对 `46039953356` 完成 12 轮/6 对，原始资源样本独立复算与 summary 一致。20k 静态负载 CPU 秒 `0.218529252→0.121336336`（下降 44.48%）、RSS `231686144→213434368` B（下降 7.88%）、physical footprint `113134656→104369088` B（下降 7.75%），均未减半。只覆盖正式 App 主进程、固定可见 Dashboard、静态合成来源、每轮 120 秒暖机和 120 秒测量。
- `6add` 的整 App run `46046493268` 在本次修正时仍构建，不能冒充已有测量结果。其 CI 的 Windows updater 因 Chocolatey NSIS 下载返回 504 失败，尚未执行安装器回归；frontend 已通过。

真实 2,008 次请求、263,914,258 个含 cache 输入 token 的恢复验收仍归属 build1061/`05e059ba…`，参见同目录 `2026-11-27-claude-account-usage-discovery.md`。不把该历史安装结果改写为本次源码的真实批次验收；54.1% 的分母仍未核实。

## 独立待办边界

自动发现多个 Claude 根共享遍历预算，超大的前置根可能让后续根没有遍历机会。现有 incomplete 提示会保留，目前没有证据证明真实漏采批次触及此上限。可在物理去重并固定首个逻辑路径后，为各根分配全局剩余预算的公平份额；Swift 分类预算与 importer 游标独立保留，Rust 同时需要文件份额。此项尚未实现，不通过提高总上限绕过有界合同。
