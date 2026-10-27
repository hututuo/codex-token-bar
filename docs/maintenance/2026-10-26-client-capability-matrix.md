# 当前客户端能力核对

2026-10-26 更新。工作树 `codex/multi-client-tokens`。完整来源、口径与验收边界见 [Claude 本地兼容接入](2026-10-26-claude-local-compatibility.md)。

| 客户端 | Token / 缓存 / 模型 / 价格 | 速度条 / TPS | 订阅额度 | 主任务 / 子 Agent | 速蹬上报 |
|---|---|---|---|---|---|
| Codex | 原账本与模型/价格链路保留 | 原活动曲线与完成正文采样 | 原有通道保留 | 原有扫描保留 | 原默认关闭选项 |
| Claude Code | 本地 usage 增量账本；输入/输出、cache-read/write；思考字段缺失时保留未知；已知完整价格才估算 | Mac 本地活动曲线和请求区间；可选状态栏 API 耗时 TPS、5/15/30 均值、5 分钟趋势，独立 SQLite 保留 7 天；Windows 本地请求区间源码已接，待实机验收 | 只读 Claude 自己输出的本地 statusline 缓存；无记录显示未接入；不联网 | 复用本地阶段、模型、父子关系；过期活动不算运行；真实活跃 Claude 待验收 | **硬性禁止**，全局开关也不放行 |
| Claude Desktop | 仅本地 Code / Agent 记录，不是云端聊天全量 | 本地请求区间，不冒充 Desktop 云端流式输出 | 无独立 Desktop 云端额度提供者 | 本地 Code / Agent 记录具备字段才支持 | **硬性禁止** |
| DeepSeek Harness / DSH | 本地日志；cache-read/write，思考暂无独立字段 | 未并入主速条 / 正文 TPS | 未接 | 未接 | 独立来源适配，按原 opt-in |
| Gemini CLI | 本地日志；cached/thoughts，未知字段不补零 | 未并入主速条 / 正文 TPS | 未接 | 未接 | 独立来源适配，按原 opt-in |
| OpenCode | 本地日志 / 只读 SQLite；cache/reasoning | 未并入主速条 / 正文 TPS | 未接 | 未接 | 独立来源适配，按原 opt-in |
| omp、Antigravity、WorkBuddy、WorkBuddy AI、ZCode、Kimi、Grok Build | 未并入主账本 | 独立路线来源适配 | 未接 | 未接 | 独立来源适配，按原 opt-in |

“字段支持”以实际本地记录提供该字段为前提；没有记录不等于用量为 0。费用是 API 等值估算，不是订阅实际扣费。外部客户端读取仍默认关闭，由用户启用。

## 口径与限制

- 活动曲线是活动估算；正文 TPS 是 Codex 完成正文采样。
- Claude 请求区间包含等待/工具等，不和正文 TPS 混算。
- Claude 状态栏 API 耗时 TPS 使用同 session/model 的输出 Token 增量 / API 累计耗时增量；不是逐 chunk 抓包或纯服务器推理时间。
- Claude 状态栏缓存没有账号身份；最近进程缓存不能冒充跨账号余额验证。
- ModelTrace、Codex 重置卡等不是 Claude 的本地通用能力；不为补齐界面而向 Claude 发网络请求。

Mac 本地解析、范围投影、持久化与禁上报的定向测试已通过。Windows 已同步本地 helper、协议、Tauri 读取和前端源码；尚未运行 .NET/Windows 产物验证。现有 Claude 文件较旧，没有活跃 Claude 子 Agent 或新状态栏数据，因此不声称已完成 Claude 全功能实机验收。

隔离预览中的模拟额度不能作为真实订阅额度接入证据。正式版没有被安装、替换或重启。
