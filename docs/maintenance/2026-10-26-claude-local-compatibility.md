# Codex / Claude Code 本地兼容接入

2026-10-26。工作树：`codex/multi-client-tokens`。不替换正式应用、不更改 Claude 配置、不访问 Anthropic、不读取 Claude 账号凭据。

## 实现与来源

保留 Codex 原账本和额度链路，在现有模块上接本地来源，不另造一个多客户端首页。

| 开源项目 | 核对版本 | 采用方式 |
|---|---|---|
| [Agent Speed](https://github.com/zoefix/agent-speed) | 仓库已有 Vendor/AgentSpeed | 复用纯本地 LiveMonitor / ClaudeParser，显式只打开已启用的 Claude 来源；pricing=nil；没有使用其网络 Reporter |
| [Claude HUD](https://github.com/jarrodwatts/claude-hud/tree/cf95a322afd18db045175d28962650ae7392ed77) | cf95a322，MIT | 参考 statusline 的模型、上下文、rate_limits 和累计 API 耗时字段；自己实现小型字段白名单采集，不引入整个插件 |
| [ccusage](https://github.com/ccusage/ccusage/tree/b40f51149d117e7c01b5f92466bae44e39c66a10) | b40f511，MIT | 核对本地 projects JSONL 的 usage、message/session/model 归属和缓存字段；现有增量账本继续承担历史用量 |
| [Claude-Code-Usage-Monitor](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor/tree/c59a83bf943f329f0e61f1a29c760353ee1860a5) | c59a83b，MIT | 兼容其已有 statusline 本地缓存；排除 OAuth/API 查询模块 |
| [CodexBar](https://github.com/steipete/CodexBar/tree/d34fbb47afe73f81dd591bae28a60f72c39a9fe4) | d34fbb4，MIT | 仅研究；不接它的 Claude OAuth/Web/CLI 联网额度路线 |

没有复制上述社区项目的实现代码；使用已有 Agent Speed vendor 和依据公开本地数据格式编写的适配。官方 Claude Code 仓库文档仅作格式参考，没有复制其非 MIT 代码。

## 原界面的接入

- Token、输入/输出、缓存读/写、可用的思考字段、会话/模型和本地价格估算：沿用多客户端增量 SQLite 账本；主页面范围切换继续控制整页。
- Mac 速度条/环：把选中来源的模型速率组成同一条色带；模型占比和任务圈也按同一范围投影，Claude-only 不会显示 Codex 的任务数字。
- Claude 本地主任务/子 Agent：读取生成/工具执行阶段、父子归属及模型；过期活动不继续冒充运行。没有明确父任务的子 Agent 单独列出。显示层 ID 脱敏，不显示项目路径或正文。
- Mac 详细测速：有状态栏累计 API 耗时数据时，显示 API 耗时 TPS；没有时，显示请求区间估算。两者不与 Codex 完成正文 TPS 混算。
- 一/二级菜单顺序与显隐共用原设置；不适合做直条的模块可用 6pt 圆点对应，颜色/位置高亮与设置一致，未增加额外的直条高度。
- Windows：新增独立本地 helper、Tauri 读取命令、主页面/侧栏的范围适配与任务详情、资源打包入口。源码与接口已接，尚未运行 Windows 产物验收。

## 速度口径

### API 耗时 TPS（Mac 本地状态栏）

同一 session、同一 model 的两份状态栏记录：

`current_usage.output_tokens / ((total_api_duration_ms 后 - 前) / 1000)`；usage 四字段改变才视为新响应，只有耗时增加的刷新先更新基线。2026-10-27 已修正早期将输出当累计量差分的错误；旧方法样本保留但不参与新均值。

采用 Claude HUD 的同类口径。按 Claude 提供的本次响应输出统计，不假定它只包含可见正文。不会用“本地两次刷新间隔”冒充服务端生成耗时；会话/模型变化、计数回退或时间回退时重新建立基线。数据仍是 API 区间统计，并非逐 chunk 网络抓包，也不是纯服务器推理时长。没有状态栏记录就不补一个假读数。

- 大于 0.4s 且 2–500 TPS 的记录才参与均速；其他记录保留为低置信度明细。
- 5/15/30 分钟为滚动窗口，按 `SUM(output) / SUM(duration)` 加权。
- 近半小时趋势每 5 分钟一桶；空桶断开，不填一条假速度。
- SQLite 在后台做聚合；界面只取有限的最新明细，不因明细列表截断而改变平均值。

### 请求区间 TPS（Agent Speed 本地日志）

复用其完成响应的 output / duration。这个区间可能包括排队、工具、网络等待，不等于正文流式速度。公开 ResponseSummary 不带精确的会话/输出项 ID，不能伪造“某一条正文”的归属。当前请求区间样本为本次运行内存记录，最多 1,000 条/30 分钟；Windows 当前走此路线，没有把它宣称为持久化 API 耗时历史。

## Claude 额度、上下文与手动本地采集

优先读 Token Bar 自有缓存；兼容已有 `~/.claude-monitor/statusline/latest.json`。额度值是 Claude 自己交给 statusline 的 `rate_limits`，不是由 Token 推出来的官方余额。

新增 `TokenBarClaudeLocal`（Mac）与 `ClaudeLocalReader --capture-statusline`（Windows），只从 stdin 接收至多 64KiB JSON，保存以下字段：模型、session ID、额度窗口、累计 API 耗时、上下文 Token 计数及 capture 时间。丢弃提示词、正文、工具参数/结果、路径、凭据和未知字段。

- Mac：`~/Library/Application Support/CodexTokenBar/claude-local-statusline/`。
- Windows：`%LOCALAPPDATA%/CodexTokenBar/claude-local-statusline/`。
- 原子写入 `latest.json` 和 SHA-256 命名的 session 文件，最多 64 个 session；Mac 私有权限、目录/文件不跟随符号链接；Windows 拒绝 reparse point。
- 超过 10 分钟、窗口已到期、记录无效就显示不可用，不从旧账户缓存悄悄回退。
- 用户自行配置 Claude Code 的 statusLine.command。设置页只提供本地命令的复制入口，不自动修改 `~/.claude/settings.json`。直接替换 statusLine 会替换用户已有的状态栏，界面有说明。
- 缓存没有账号绑定信息，只能说明“最近本地 Claude 进程”的额度。切换账户后需要新的本地状态栏记录；不能声称已验证账户余额。

Mac API 测速细节独立保存在 `claude-local-speed.sqlite`，保留 7 天。该数据库不打开或迁移 Codex 的原始费用账本。已有 `multi-client-usage.sqlite` 的备份/升级逻辑不变，也不删除已经入账的历史会话。

## 网络隔离

Claude 本地适配没有 HTTP/WebSocket/代理、Claude 子进程、账号凭据或配置写入路径。不会请求 Anthropic。

另外在 Agent Speed 上报入口显式禁止 Claude Code / Desktop：监视来源、聚合输入、队列前、签名前、发送前都检查来源；未知来源和混合 Claude 的包拒绝发送。Windows helper 启动协议也固定同一 deny list。即使用户开启全局速蹬上报，Claude 数据仍不发送。Codex 等原有明确授权的网络功能不受此本地适配触发。

这属于源码调用边界和测试保障，不是把整个 Token Bar 进程断网；Codex 额度、雷达等原有网络功能仍按各自开关工作。

## 验证与尚未完成的验收

- PASS：Swift 定向 137 项 + 本地采集核心 8 项；覆盖来源过滤、禁用与配置复用、主/子 Agent 归属、7 天保留、加权窗口、过短异常时间、隐私字段、权限、链接保护、64-session 轮转等。
- PASS：前端 TypeScript/Vite 构建；36 项 Node/SSR 定向回归，包含原 LiveRateCard 默认行为、Claude-only 作用域和圆点尺寸。
- PASS：Rust 多客户端 28 项、上报 6 项；Windows 本地读取协议与生命周期 10 项（在 Mac 上执行）。
- NOT_RUN：Windows .NET helper 构建、自测和实际 EXE；本机没有 dotnet，且本分支不替换 Windows 正式版本。
- NEEDS_LIVE_VALIDATION：本机只有旧 Claude 历史日志，没有正在运行的 Claude / subagent 日志，也没有已接入的新 statusline 缓存；没有用真实活跃 Claude 会话完成逐项可视化验收。
- NOT_RUN：这轮没有正式安装、发布或全软件功耗基准；也没有把定向回归写成全量测试通过。

“所有功能兼容”仍需要遵守事实边界：Claude 官方额度只在本地有数据时可用；未落地的云端历史、未提供的思考明细、精确逐 chunk 正文 TPS、Claude 联网模型指纹检测/重置卡，都不会伪造或为了补齐界面去请求 Anthropic。


## Agent Speed 维护要求（后续同步必须保留）

见 [复用清单与同步流程](agent-speed-upstream-sync.md)。2026-10-26 核对上游与内置版本同为 `a94a67fcc78e5d8eea5f82d8d5e737bccf994e2c`。已补来源锁、六项本地适配清单、普通 CI 离线校验及发版前上游 HEAD 检查。

新增复用上游的来源级 estimated 分类和 ResponseCost 整数计价；不扩大历史价格猜测，不增加网络或历史扫描器。显示的估算占比属于上游请求时间线分类，不等于正文逐 chunk 实测。更新时双端核心、spec 和测试一起同步，Claude 只读本地与禁上报的保护不能被覆盖。

2026-10-27 更正及读取/Windows 边界见 [速率与价表核对](2026-10-27-speed-reading-and-price-unification.md)。最新快照轮询仍可能跳过响应；不宣称是精确逐字流式测速。
