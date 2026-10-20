# 活动曲线与独立接收测速 / Activity curve and observed throughput

## 数据流程

复用现有 Codex 数据源、增量 JSONL 游标与日志读取器。生命周期、思考条目完成时间和 response 用量结算进入活动曲线；有正文的 SSE/WebSocket 文本与工具输入 delta 单独进入测速采样。工具 stdout、搜索结果、完成后的整段文本和隐藏思考不进入真实接收测速。用量账本、历史索引、fork 去重规则不变。

活动曲线采用已审阅的 C 方案：40 tok/s 起步，以同会话同模型最近五次合格思考结算比值的中位数校准。思考预估量为基线乘条目时长；时长不足一秒只把分配窗口下限设为一秒，不放大预估 token。后续用完整 output_tokens 作有符号校准，reasoning 是 output 的子集，不重复相加。有限分配队列使用 [1,2,3,2,1]/9，明确中断清空；正常结束最多五秒；二十秒无新数量事件归零。动画不是账本，也不是模型引擎的实测速度。

中间说明（commentary）和最终回答都属于文本输出；只要存在可关联的正文 delta，就使用相同的接收采样流程。只有完整段落落盘、没有分块时间时不生成测速样本。

测速按输出项记录会话 ID、轮次 ID、输出项 ID、模型、首末包时间、输出长度、包数和采样质量。token 是本地估算，不能当作服务端精确分词。Swift 可使用现有本地分词器，Rust 使用现有文本启发式；工具输入的跨平台估算可能不同。首包没有可观测生成区间，计时从首包到末包，分子减去首包。模型均速按所选最近15或30分钟的有效样本 Σtoken / Σ时长加权，避免少量短输出拉偏。build 912 起，完整无警告的短样本合并为带质量提示的参考均速；接收停顿、中断或覆盖不完整仅展示明细。汇总保留单段达标数，接收中每秒更新、结束后校准。置信度是启发式样本质量评级，不是统计置信区间，也不能证明网络正常。

接收计时只取首末正文增量；晚到的完成标记不会拉长采样时长。完成事件必须匹配轮次或输出项，避免关闭同会话的新轮次。Windows 对追加文本使用增量估算，结束时再核算完整采样文本；不逐包重算整段长输出。

记录不包含输出正文，独立持久化并按源隔离，最多保留 10,000 段。采样期间只保留有上限的内存文本用于整段分词，结束时写入数值记录。不会高频重扫完整历史，不发额外模型请求，不改变 Codex 的代理、模型、认证或日志配置。

## 数据可用性

2026-10-20 在接入 Desktop IPC 之前，检查的本机日志有模型连接目标记录，但没有可解析的流式正文 delta。CC Switch 本地 74,989 条记录的 data_source 均为 codex_session，不能作为代理实收测速。该旧版界面当时没有真实采样。后续已接入 Desktop 正文追加事件，build 912 已实测恢复采样、补齐模型并显示参考均速，详见 [Desktop 观察器记录](../desktop-stream-observer-20261020.md)。

参考 CC Switch 的独立实收/估算口径、短输出门槛和加权汇总思路，未复制其源代码：
https://github.com/farion1231/cc-switch/blob/f92ff0b03964188f1cd011d9302ab8869d7a8219/src/components/usage/format.ts

## Verification

- Swift full suite before final sidebar/attribution changes: 1,792 tests, 10 skipped, zero failures. Final focused sidebar, monitor, attribution and telemetry regression: 121 passed.
- Focused frontend/sidebar tests: 46 passed; TypeScript and Vite production build passed. macOS Rust sidebar geometry: 22 passed.
- Actual Windows x86_64 regression: 85 live-rate tests and 22 sidebar geometry tests passed. Native build/install status is recorded in the local deployment receipt; tests alone are not desktop UI acceptance.
- Local macOS candidate: 0.9.5 build 908; retain build 906 for rollback. No public release, tag or update feed publication is part of this change.

## English

The existing incremental readers feed two independent outputs: a bounded estimated activity curve and timestamped visible-output throughput samples. Exact usage accounting remains unchanged. The curve starts at a provisional 40 tokens/s, calibrates from eligible same-session/model reasoning settlements, reconciles against full output usage without adding reasoning twice, stops on interruption and expires within five seconds of normal completion.

Measured samples use visible text and generated tool-input deltas only. Their receipt timing is observed locally; tokenization is estimated. Model summaries weight eligible samples by total sampled tokens divided by total observed duration over the selected 15- or 30-minute window. Short, incomplete or disrupted samples remain traceable in the detail list and are excluded from model averages when unsuitable. No payload content is persisted. Current desktop logs do not expose structured delta payloads, so historical session-imported records are not represented as measurements.

侧栏展开高度增加为有5小时额度680pt、仅7天额度590pt；固定画布、原生裁剪与内容视口同步更新。短屏允许滚动，较短内容按可见高度居中，15/30分钟切换默认30分钟。

## CC Switch 公式复核与本地数值（build 912）

复核官方 CC Switch 提交 `f92ff0b03964188f1cd011d9302ab8869d7a8219`，不是照抄实现：

- 代理实收：`outputTokens / ((latencyMs - firstTokenMs) / 1000)`，首字等待单列；需输出 ≥100 token、生成窗口 ≥100 ms。
- 日志导入近似：`outputTokens / (latencyMs / 1000)`，需输出 ≥200 token、估算耗时 ≥1 秒；即使有估算首字时间，也不将其从该近似分母扣除。
- 两种口径分开汇总，均为 Σtoken / Σ时长，而非单条速度算术平均。见 [format.ts](https://github.com/farion1231/cc-switch/blob/f92ff0b03964188f1cd011d9302ab8869d7a8219/src/components/usage/format.ts#L181-L298)、[statsColumns.tsx](https://github.com/farion1231/cc-switch/blob/f92ff0b03964188f1cd011d9302ab8869d7a8219/src/components/usage/statsColumns.tsx#L11-L38)。

本机 CC Switch 数据库仍为 74,989 条 `codex_session`，0 条代理实收。最近四条合格导入记录来自 10 月 18 日 10:47–10:49，均为 GPT-6.1 Sol：267/7.155=37.32、1300/27.444=47.37、347/11.695=29.67、759/15.370=49.38 tok/s；合并为 2673/61.664=43.3478 tok/s。Bar 15:52 快照为 633/21.0674=30.0464 tok/s。两者既非同一天，也非同一批输出，不能用差值判断测速误差或模型变慢。

Bar 的分母来自 Desktop 转发后的正文增量接收时间，分子为本地分词估计且扣除首块；CC Switch 的分子来自请求/会话用量记录，导入耗时来自日志估计。Bar 没有该请求的代理入口时间和服务端完整 usage，因此不能将现有正文片段伪装成 CC Switch 代理口径，也不能还原可靠 TTFT。
