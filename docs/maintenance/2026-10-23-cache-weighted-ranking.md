# 整轮加权缓存排行与请求明细

用户授权：macOS 原生与 Windows/Tauri 一起将单轮排行从“最后一次请求快照”改为整轮加权，标出低命中/零命中次数，点击查看各次请求时间及用量。继续遵守先解决问题、暂不打包/替换的要求。

## 统计口径

- 一轮以现有用户消息关联为边界；工具往返及续答仍属于同一轮。
- 加权命中率 = SUM(min(cached_input, input)) / SUM(input)，分母为零时不显示请求命中率。
- 请求记录数统计规范化、去重后的有效用量事件；沿用 canonical/published ledger 与 fork 重放排除规则。
- 低命中次数：每条请求 input >= 20,000 且 hit < 30%。不套用提醒的首请求抑制、时效限制；历史事实保持可见。
- 零命中次数：input > 0 且 cached = 0。零命中与低命中可以重叠；输入不足 20,000 的零命中不算低命中。
- `breakdown.calls` 和 `session_calls` 保持既有逻辑轮数语义，防止破坏“排除单轮会话”。请求数使用独立字段。
- 整轮显示两位小数。会话排行使用整轮累计输入/缓存，因此同样得到加权结果。
- 缓存提醒仍按单次请求；图表仍按时间桶。此次不修改计费、不增加缓存写入推断。

## 数据与读取路径

- Swift 可重建 dashboard aggregate 版本 5 -> 6；Rust 6 -> 7。主索引/历史账本版本不变。
- 在已有派生表安全补充请求数/低命中/零命中列，全量与增量聚合同时维护；升级仅重建可重建投影，不删除 events、retained 或 ledger。
- 主快照只带计数，不携带全部请求明细；开面板才读现有 SQLite，100 行一页、最多读取 101 行判定下一页，无 JSONL 扫描、无新持久副本、无新增轮询定时器。
- 请求明细含时间（秒）、模型、输入、缓存命中、未命中、输出、总量、命中率。输出已包含思考，不能再次相加。
- Swift 只读入口绕开 index construction/migration；旧聚合版本要求精确索引正常刷新。文件删除后仍从 canonical ledger 查询。
- Tauri invoke `read_cache_turn_requests` 校验来源 token，限制主页调用；UI 拒绝旧请求返回后覆盖新数据源。打开前不发明细请求。

## 本机真实数据核验

2026-10-23 当前 TokenBar 对话第 10 轮（本机 source_id 3818）：

- 30 条有效请求；input 9,356,604、cached 8,683,648、output 44,810、total 9,401,414。
- 整轮加权 92.8076896%，显示 92.81%；低命中 2 次、零命中 2 次。
- 10:44:38：input 318,414、cached 0、output 3,648。
- 10:53:12：input 322,636、cached 0、output 3,573。
- 新 SQL 对实际生产库只读回放已匹配上述结果；未对本机生产库执行迁移或发布新投影。
- 请求页同等 SQL 只读查询该 30 条：首次约 8.7ms，后续五次中位数约 0.04ms，仅代表这份本机样本，不是全场景功耗或性能保证。

证据位于外层 `runs/20261023-cache-ranking-consistency/weighted-projection-replay.json`、`weighted-request-detail.png`。截图为当前组件加载真实数据的开发回放，不是已安装原生版或 Windows 实机验收。

## 验证与交付边界

- 前端缓存排行、分页/搜索、请求明细、跨源旧响应拦截和主线程 surfaceState 回归通过；类型检查通过。
- 请求明细额外覆盖点击后才 invoke、sourceToken/turnId/offset/limit 传递正确。
- Swift 聚焦回归覆盖加权/计数、105 条分页、删除源文件后保留、旧 aggregate 拒读/安全升级、映射及 hydration 不丢计数字段；10 项通过。
- 最终 Swift 13 项回归通过（含 fork 新增轮次、归档与删除保留）；最后 UI/source-binding 修改后的 7 项回归再次通过（重叠不累加）。
- 前端缓存相关 16 项、surfaceState 38 项通过，TS 类型检查通过。
- Rust cache_turn 3 项、cache_usage 3 项、fork_replay 6 项通过，另 commands::window_auth::tests 通过。Rust 测试在本机 macOS 公共代码上运行，未构建/安装 Windows EXE。
- 本次未打包、未安装、未发布；已安装软件仍是原版本，原生菜单/Windows 实机效果须等统一测试替换。
