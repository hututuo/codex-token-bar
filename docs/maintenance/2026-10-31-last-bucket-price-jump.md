# 最后一格触发整段金额跳涨

## 实机证据（正式版 build985）

同一起点 2026-10-31 00:50，仅把终点从 01:20 那格移动至最后的 01:25 那格：

|选区覆盖至|Token|请求|本段 API 等值|
|---|---:|---:|---:|
|01:25（不含最后空格）|4984.1 万|249|$5.02|
|01:30（含最后空格）|4984.1 万|249|$26.3|

最后一格的气泡显示 0 Token、0 请求、$0，却显示 GPT-6.1 Sol 模型明细。金额增加不是实际新增用量。截图保存在本机 `scratch/last-bucket-price-investigation/same-start-penultimate.png`、`same-start-last.png`，未随公共源码上传。

## 原因

`UsageAggregationBuilder` 的图表累计以 `aggregateNow = settledThrough - 0.001` 为限，仅包含已闭合的 5 分钟桶；`attributionCoverageEnd` 刻意覆盖当前观察桶，用于实时/今日模型统计。两种数据本身各有用途。

`RecentUsageChart` 却将未截断的 attribution 用于图表模型明细及选区价格。时间轴补出的最后空桶落入未闭合桶时，模型用量总和超过图表用量。`ModelAwareAPIPriceEstimator` 发现覆盖不一致后，退回默认 GPT-5.6 Sol，把整段已识别 Sol/Luna 的用量全部重新估价。

另一个风险是异步准备的图表配上较新的父视图 attribution。仅截断当前事件仍不够，选区必须绑定实际已发布的准备快照。

## 修复

- Dashboard 将 Codex 的 `settledThrough` 传给图表及独立 Codex 费用来源；兼容读取原有 `preciseTimeSeriesGeneratedAt`，不增加持久化字段。
- 准备快照在后台按同一截止点裁剪图表 attribution。完整实时/今日 attribution 不变。
- 准备快照同时保留对应费用事件，并提供唯一的选区入口。悬停、固定、刷新和重选使用该快照的用量及事件，不再临时搭配父视图最新事件。
- 截止边界变化后，新增桶的用量和价格一起推进。没有修改原始日志、数据库、价格表、历史费用或全局兜底策略。

## 双端与回归

共享夹具 `Tests/Fixtures/last-bucket-chart-cost.json` 来自只读本机账本的逐桶/模型聚合，不含会话 ID、正文或账户信息。让最后一个真实桶保持未闭合，复现原有截止时间分叉：相同已闭合用量为 170,322,445 Token、842 次请求，正确估值 $23.51656288；旧路径混入 1 行未闭合模型明细后变为 $95.5147496。

- Swift：覆盖 Codex/汇总、悬停/固定/刷新、24h/7d/30d、截止点推进，以及旧快照不受新输入影响。
- Windows/Rust：原实现已经从同一受限 SQL 聚合同时生成桶总计和模型明细，没有 Mac 的独立 attribution 分叉。增加同一真实夹具的三种范围覆盖一致性检查，并确认未闭合用量仍在总账。
- React：同一夹具验证加入空尾桶后 Token、请求和费用均不变。

本地前端全量 1376/1376 通过；TypeScript 检查、Swift 语法检查、差异检查通过。完整 Swift/Rust 云端验证待完成。本修复尚未构建、安装；正式版仍为有此故障的 build985。
