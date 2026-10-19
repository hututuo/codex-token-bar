# Codex Desktop 正文流接入 / Desktop text stream observer

2026-10-20，本地验证版 macOS 0.9.5 / build 910。

## 接入与计量

直接连接当前 Desktop 已运行的 IPC 路由，macOS 使用所选 CODEX_HOME 下的 `ipc/ipc.sock`，Windows 使用 `\\.\pipe\codex-ipc`。协议是 4 字节小端长度加 JSON，并非 app-server JSON-RPC。只发送初始化、会话跟随/取消跟随和否定的能力发现回复；不启动 app-server，不获取会话所有权，不恢复或中断用户会话。

版本 11 的会话状态广播提供历史快照及连续修订。历史快照只保留运行轮次、模型、输出项标识和 UTF-16 长度；只有 `acceptedTextChanges` 中可验证的正文追加才进入采样。正文以 Desktop 转发后的接收时间计时，可能经过短时合并。它可以测中间说明和最终回答，不是服务器原始网络包，也不能测未暴露的隐藏思考或工具执行结果。原有日志流采样路径继续支持可用的模型工具输入流。

首个更新的 token 不进入分子；分母为首次到末次正文更新的时长。token 为本地估算，延用既有精确分词开关。样本保存会话/轮次/模型、长度、更新次数、时长、速度、质量评级及停顿提示，不保存正文。15/30 分钟均速仅使用完整且质量达标的样本，并按 token 总量除以总时长加权。

重复修订丢弃；修订缺口、所有者切换、非追加替换和断线结束当前采样并重新建立基线。恢复后新片段单独采样。工具输出不会作为模型正文速度。用量账本继续以原有结算流程为准；IPC 不写入原始 Codex 数据或用量索引。

单观察器最多跟随 4 个会话，保留至多 8 个运行轮次基线。正常帧上限 64 MiB，更大的历史帧在 256 MiB 协议边界内直接排空。采样正文和持久样本继续受既有容量限制。macOS 每帧释放临时 Foundation 对象；Windows 使用有界事件队列，溢出会结束部分采样，防止跨缺口拼接。

## 验证

- macOS 全量 Swift：1801 项，10 项跳过，0 失败；每帧内存处理补丁后再跑 16 项聚焦测试通过。
- 同一生产解析代码实连：一段正文 33 次更新、132 字符，首次至末次更新 2.335 秒，带明确轮次/输出项/模型。
- 已安装的 build 910 在主界面显示 Desktop 正文流连接，实际样本文件已收到至少 3 个会话的记录。
- Windows HTTWIN：真实 named pipe 初始化握手通过；87 项 live_rate 测试、7 项 Desktop 事件测试、22 项侧栏测试和 MSVC release 构建通过。默认本地 sessions 目录没有会话，因此 Windows 正文实采仍为 NOT_RUN；不能用握手或编译替代正文采样验收。
- 两端前端/原生构建通过。macOS 安装包 ad-hoc 严格签名验证通过，安装前旧程序保留回滚。未公开发布。

数值证据位于忽略目录 `runs/20261020-rate-implementation/desktop-stream-probe/`，包含生产探测元数据、安装收据和实际样本审计；无正文内容。

## English

The observer attaches read-only to the existing Codex Desktop IPC router. It follows selected local threads without starting an app server or taking ownership. Versioned snapshots establish identity and text-length baselines; only verified accepted append edits become measurements. Revision gaps, reconnection and replacement edits end partial samples rather than joining disjoint output.

Timing measures Desktop-forwarded text receipt, including intermediate assistant messages and final answers. Token counts remain local estimates under the existing tokenizer setting. Hidden reasoning and tool execution output are not measured model throughput. Persisted samples contain numeric metadata and provenance, never message text. Eligible samples feed weighted 15/30-minute model averages; short or interrupted samples remain available in details.

macOS build 910 passed signing checks and real installed-app sampling across multiple chats. Windows passed native tests/build and actual IPC initialization, while a real Windows text sample remains NOT_RUN because its default local session directory is empty. No public release was performed.
