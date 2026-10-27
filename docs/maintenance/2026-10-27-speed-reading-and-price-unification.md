# 速率读取核对与价表合并

2026-10-27；仅 `codex/multi-client-tokens` 工作树；不安装、不重启正式应用，不请求 Anthropic。

## Codex 曲线不是同一算法

| 项目 | Token Bar 原曲线 | Agent Speed 内置核心 |
|---|---|---|
| 输入 | logs SQLite 的正文/工具 delta，加 rollout reasoning/usage/完成/故障信号 | 本地 sessions transcript 的请求/usage/完成记录 |
| 活动显示 | 暂估 budget，默认 reasoning 40 TPS 后按模型历史校准；EMA + 五项 FIR | 3 秒 live window；完成量按响应区间摊入；未完成请求参考历史响应速率 |
| 故障 | abort/failure 清零；网络错误 pause，后续新输出恢复 | Codex 结束与 abort 映射 idle，未复用 Token Bar 的独立网络 pause 策略 |
| 正常结束 | 最多 5 秒收尾 | 不具备同一套 5 秒尾迹策略 |

结论：不能称为同一公式，也不直接替换已确认的 Token Bar 曲线。以后可共用 transcript 读取/事件解析，向账本与不同目的的消费者分发；保留正文 TPS、活动展示、榜单口径标签及故障停止。独立榜单统计不回写主账本。

原 Codex 已分开读速度和用量：`LiveRateLogDatabaseReader` 读 logs SQLite，`LiveRateMonitor+Rollout` 增量读 rollout；`CodexUsageAnalyzer` 优先统计 JSONL token_count，必要时回退 state SQLite。不是这次 Claude 接入才引入两类读取。Claude 当前类似：`MultiClientUsageScanner` 的断点历史解析与 Agent Speed 实时监视器可能分别解析同一新增 JSONL；未把实时统计重复加进费用账本。本次未统一读取器。

## Claude 本地速度口径纠正

来源：[Claude HUD speed.ts](https://github.com/jarrodwatts/claude-hud/blob/cf95a322afd18db045175d28962650ae7392ed77/src/speed.ts)，本次重新核对同一提交。它使用 `context_window.current_usage.output_tokens / Δcost.total_api_duration_ms`，通过 usage 四字段判断响应是否变化；只有时间增加而 usage 未变时更新基线，不给下一条主响应加上已观察到的子 Agent 时间。

之前本分支将 total_output_tokens 当累计计数差分，可能低估或漏掉更短的下一条响应；已改用 current_usage 响应输出和 usage identity。仅耗时差分，不对输出做差。默认不为第一份快照测速，会话/模型切换、时间回退、重复 usage 不产生样本。采样 ID 带 v2 方法版本。原 SQLite 中错误口径行保留，添加 method 列并标为 legacy，不纳入新均值/趋势；不删原账本。不改大于 0.4s 及 2–500 TPS 的已有资格规则。

这不是向 API 发请求。“API 耗时”是 Claude 自己写给本地 statusline 的计时字段；界面改称“响应均速 TPS”。它包含请求等待，不能保证排除网络/重试/思考；不是逐字正文 TPS。还存在最新快照覆盖与轮询跳过响应的问题，跨多响应的快照不能保证同一输出与同一请求耗时一一对应；未解决前不能宣称精确逐响应测速。它也不能用于判断服务器纯推理速度。

[cc-speed](https://github.com/bryant24hao/cc-speed) 用 output_tokens / (assistant timestamp - preceding user timestamp)，包含等待，不能因此获得比 Codex 正文起止采样更精确的速度。没有仅靠这些完成日志就能恢复真实流式首字/末字时刻的结论。不使用代理、凭据或额外 Anthropic 请求。

## 价表合并

已核对原标准卡的全部 12 个 canonical ID，输入/缓存读取/输出当前基础价格与 pinned Agent Speed 一致。本次只合并标准短上下文价格数据，不扩大计价类别、别名或 Fast 识别。

- Swift `StandardAPIPriceSchedule.currentQuote` 和原 `OfficialAPIPriceModel.currentPriceRates` 直接共用 `PriceBook.bundled`。
- Tauri/Windows 的 `standardAPIPriceSchedule.ts`、`quotaPriceModel.ts` 直接共用同一个 `Vendor/AgentSpeed/spec/assets/prices.json`，不再单独硬编码当前价格。
- 双端事件历史共用 `Sources/CodexTokenBar/Resources/standard-api-price-history.json`，从原有历史规则冻结，保留各模型上市边界、2026-07-30/08-21 调价与原 revision。
- 旧历史绝不跟随最新价表改写；上游价格改变时追加生效时间与新快照，不能覆盖旧行。雷达 2026-07-30 固定基准、Spark 暂定价、auto-review 路由独立保留。
- 原多客户端账本对 periods/offPeak/不明缓存写入 TTL 的保守拒绝未改变。上游价表更新不等于已经把所有价格条件都接入历史计费。
- 不启动 PriceSync，不新增下载；vendor 本地来源锁检查通过。

## Windows 对齐状态

Windows 的实时核心是同一 pin 的 AgentSpeed C#，本地额度/statusline 采集与读取有源码。另发现 `--capture-statusline` 曾按归一化缓存格式验证原始 stdin，会因缺 schema_version/captured_at_epoch 拒绝；现改为采集入口赋本机时间并归一化，磁盘读取入口仍严格验证，补 self-test，修正固定在未来的 self-test 时间。

尚未完成：Windows API 响应速度 SQLite 七天保存/聚合及界面选择；Windows 当前仍是 latestResponse 轮询的请求区间路线，可能漏短时多响应。Swift 与 Rust 历史账本计价函数也仍分别实现，数据已共用。本次不宣称完成全部 Windows 同步；.NET 编译与真实 Windows 运行 NOT_RUN。

Claude 父子任务沿用上游状态与关系，本地过期状态过滤；源码核对和既有单元测试不等于新鲜活跃会话实测。本次不以没有活跃 Claude 为由阻止源码改动。

## 本轮验证

- PASS：119 项 Swift 定向测试，覆盖历史价边界、原费用估算、多客户端账本、Claude 响应输出/子 Agent-only 时间基线、旧测速记录保留与排除、原 Codex 停止/收尾。
- PASS：186 项 Node/SSR 回归，包含双端共用历史数据、当前价格、图表估算、共享账户归属、侧栏价格与 Claude 范围；TypeScript/Vite 构建通过。
- PASS：Agent Speed 离线来源锁校验、git diff --check。vendor 核心未改。
- NOT_RUN：新增 C# capture 自测及 .NET/Windows 产物构建；当前机器无 dotnet。没有正式安装、替换、重启或全软件性能验收。
