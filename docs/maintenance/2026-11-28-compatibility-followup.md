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
- `6add` 的整 App run `46046493268` 已完成两份精确 release App 构建，2026-11-28 02:53:56 +0800 开始整 App 配对采样，尚无本次测量结果。其旧 CI 的 Windows updater 因 Chocolatey NSIS 下载返回 504 失败；新 `0007569e` 的 Windows updater 已实际通过安装器故障回归。
- 精确 `0007569eaaa483d1790a2448be50dc591378aeff` 的公开升级 `46052256646` 已双平台成功，产物原始输入哈希和精确来源复核通过：macOS 8 项升级及 126 项支持回归；Windows 3 项 importer、非 `cfg(test)` 生产 probe、19 类 manifest 恢复情景。该证据不替代全量 native 与资源验收。
- 同 SHA 的 CI `46052256690` 中，frontend、Windows updater 通过；双端 native 已完整退出：macOS 1,915 passed / 1 failed / 14 ignored（198.01 秒），Windows 1,857 passed / 1 failed / 15 ignored（568.06 秒）。20k 压力及旧库备份、Gemini 分页、quota 四项、activity 迁移与 standalone 保全均实际通过。唯一失败为 `claude_jsonl_incomplete_append_waits_through_reopen_until_line_feed` 的返回值预期，见下文；后续 backup/physical-A 负控以及 Windows helper IPC/packaging 因前步失败未执行，不能记作通过。Swift 结果仍待收。

真实 2,008 次请求、263,914,258 个含 cache 输入 token 的恢复验收仍归属 build1061/`05e059ba…`，参见同目录 `2026-11-27-claude-account-usage-discovery.md`。不把该历史安装结果改写为本次源码的真实批次验收；54.1% 的分母仍未核实。

## 续查修正与待验范围

- Claude 未闭合长记录测试：CLI fixture 没有已提交首条记录，分类器正确返回 `Incomplete(PartialRecord)`；原 `unwrap()` 与现有分类合同冲突。现在严格核对完整诊断及实际读取字节数；Desktop 有已提交 header 时仍要求成功等待。两段 partial/无 LF 循环的完整账本相等、重开连接，以及补 LF 后的两个事件、精确 checkpoint 和重放断言均保留。未放松生产分类器。
- Swift 会话加载测试的 mock 原先仅轮询 1,000 次 `Task.yield()`，不能保证 MainActor 创建的工作已获调度。catalog/context 两类等待改为 actor 内注册事件，再通过带 10 秒超时的 `XCTWaiter.fulfillment` 等待；到达阈值时先移除 waiter 再 fulfill，超时后清理。
- 自动发现多个 Claude 根已改为先物理去重并固定首个逻辑路径，再为各根分配全局剩余预算的公平份额，扣除实际消费并继续后根。Swift 只对 Claude 分配 entry 份额，分类预算与 importer 游标独立保留；Rust 同时分配 entry/file 份额，各根局部截断合并到总量，精确 E/F 项不再提前丢失。没有提高总上限。新增 Swift 4 项、Rust 5 项小 fixture，覆盖前根噪声、递归截断、未用预算回流、missing/alias、零预算及精确边界；跨平台用例加入 CI 必执行清单。原 incomplete 提示保留，目前仍无证据证明真实漏采批次触及此上限。

以上续查修改已推送为 `f858ae03cbcbeec51d385b76921e0dc547af321c`，其公开升级 `46054347696` 与 CI `46054347941` 尚待完成，不能继承 `0007569e` 的通过结论。

## 可见 Dashboard 的后台工作优化

- 纯图标状态栏停止每秒 timer，并直接生成与旧空指标配置等价的空文字、固定辅助说明和恢复图标，省去 `TokenDisplaySnapshot`、radar 和指标计算。重新启用指标时立即刷新并恢复唯一 timer；同 owner 切换、owner 更换、重复 bind 和关闭的生命周期断言均覆盖，popover 的 lazy attach 和运行需求租约保持原路径。
- Dashboard 按主页、热力图、最近图三个解析后的客户端范围决定是否申请外部 usage charts；只看 Codex 时释放原 consumer UUID 的图表需求。独立图表选择外部客户端、all、失效选择回退及 available 变化均按子视图同一个解析函数处理；其它窗口的 consumer 不受影响，消失后不会因设置变化重新申请。既有最后一个 consumer 关闭后清空、重新从 ledger 加载的回归加入必执行清单。

新增两项范围策略测试和一项状态栏生命周期测试，均待新 SHA 云端编译/执行。当前只有源码审阅与轻量脚本证据，两项收益均未量化，不宣称资源已经减半；整 App 验收仍使用原固定可见 Dashboard、相同合成来源及采样时长。
