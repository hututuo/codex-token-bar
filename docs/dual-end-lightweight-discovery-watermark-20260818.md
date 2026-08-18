# 双端轻量前置扫描与正式增量水位实现记录（2026-08-18）

## 已落地

- 前置 discovery 只枚举 `sessions`、`archived_sessions`、`active-rollouts`，记录候选的 canonical path、字节大小、时间和文件身份；不打开精确索引，不读 `files`/`events`，不保存 checkpoint，也不推进 generation。
- 正式 Tauri 扫描可以消费过期 discovery。每个候选仍会重新打开文件并读取当前签名，再由持久化 checkpoint、身份、尺寸和前缀校验决定 unchanged、append 或单文件重建。
- discovery 之后新建的文件不会强行触发同一轮目录 walker；下一个正常 cadence 或手动刷新重新 discovery 后处理。
- 前置扫描发现的越界 symlink/active rollout 不丢安全告警：拒绝原因只作为内存 discovery 诊断带入本轮发布，不进入索引表。
- 扫描期间 source revision 改变不再把本轮标记为 incomplete，也不再因此重新遍历目录。正式扫描只发布本轮观察到的水位，尾部留给下一次 cadence。
- Swift 和 Tauri 的跨 Chunk 未完成行均从 checkpoint 所在 Chunk 起点重算 hash，从 `resume_offset` 继续解析；跨 Chunk append 不再默认退回单文件 full rebuild。若 `resume_offset` 恰在 Chunk 边界，会额外包含前一 Chunk 以完成旧尾块校验。
- watcher 事件现在只作为刷新提示：成功 owner 发布后的 cadence 窗口内不再每次追加都启动第二个 owner；失败仍按既有有限重试间隔重试；手动刷新仍可立即执行。

## 不变的安全边界

- 不修改原始 JSONL、`files`/`events` 表结构、generation 格式或 checkpoint 字段。
- 文件缩小、身份变化、前缀/中部重写、读取失败、Home 替换和 watcher overflow 仍进入定向安全恢复；不会把这些变化误判为 append。
- unchanged 文件正文读取保持为零；新文件最多延迟到下一次 discovery。

## 定向验证

- Tauri：跨 Chunk append、Chunk 边界 append、discovery 后新文件延迟、discovery 签名漂移、扫描期间 append、越界 symlink 和绝对 active rollout 边界测试通过。
- Tauri 定向 exact-index 回归：相关匹配测试在修复越界 discovery 诊断后全部通过（另有 1 个显式跳过的 live Home 测试）。
- Swift：`swift build` 通过；跨 Chunk append 测试契约已改为 incremental、`rewrittenFiles == 0`，并增加 Chunk 边界验证测试。完整 `swift test` 当前仍被工作树已有的 `CodexUsageStoreTests.swift` Swift 6 XCTest autoclosure/actor-isolation 编译错误阻断，非本次索引源文件错误。

## 后续现场验证

发布前仍需在隔离 fixture 上记录 discovery、append/full 读取字节数、SQLite 提交和发布耗时；不使用真实 Home 做破坏性重建，也不删除旧索引。
