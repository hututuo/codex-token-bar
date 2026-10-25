# 多客户端 Token 账本与 Claude 额度调研

日期：2026-10-25。独立分支 `codex/multi-client-tokens`，基线 `c63b8b3e4a18135b8effacccfd7eb0b3414cb995`。
工作目录：`/Users/huyiyang/.codex/worktrees/multi-client-tokens/codex-token-dashboard`。
本分支不部署、不重启正式应用，不构建或替换 Windows EXE。原线程目录及其测速/上报文件没有修改。

## Claude 订阅额度：读数来源必须分开

| 工具（锁定审阅版本） | 本地用量 | 真正订阅额度 / 认证 / 请求频率 |
| --- | --- | --- |
| [ccusage b40f511](https://github.com/ccusage/ccusage/tree/b40f51149d117e7c01b5f92466bae44e39c66a10) | 读本地 Claude JSONL，计算输入、输出、缓存和 API 等价成本；按本地时间构造 5h blocks | 本地 block 和 burn rate 是推算，不是服务端剩余百分比；不需要 Claude 凭据。按执行或 Claude statusline 调用触发；可选在线定价数据与额度接口无关。 |
| [Claude-Code-Usage-Monitor c59a83b](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor/tree/c59a83bf943f329f0e61f1a29c760353ee1860a5) | 普通模式读 JSONL 推算；另有 `--statusline` 从 Claude Code 提供的 stdin 保存 `rate_limits` | statusline 缓存是纯本地的提供方额度读数。实验性 `--api` 另读环境 OAuth token / `.credentials.json`，GET `api.anthropic.com/api/oauth/usage`，Bearer + `anthropic-beta: oauth-2025-04-20`，180s 缓存，默认关闭。源码明确属于非公开端点。 |
| [CodexBar d34fbb4](https://github.com/steipete/CodexBar/tree/d34fbb47afe73f81dd591bae28a60f72c39a9fe4) | JSONL 本地费用和 Token 单独扫描 | 支持 OAuth、Web Cookie 和 Claude CLI `/usage`。OAuth GET `/api/oauth/usage?cedar_ember=1`，指定错误会重试不带 query；另可请求 profile。Web 先取 organizations，再取组织 usage，还可能读 spend/account。认证可能来自环境、本地凭据、Keychain、浏览器 Cookie。默认 Adaptive 2–30m，可手动/固定1、2、5、15、30m。 |

精确源码链接：
- [ccusage block 构造](https://github.com/ccusage/ccusage/blob/b40f51149d117e7c01b5f92466bae44e39c66a10/rust/crates/ccusage/src/blocks.rs#L53-L103)、[本地目录](https://github.com/ccusage/ccusage/blob/b40f51149d117e7c01b5f92466bae44e39c66a10/docs/guide/claude/index.md)。
- [Monitor statusline 缓存、TTL 与过期处理](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor/blob/c59a83bf943f329f0e61f1a29c760353ee1860a5/src/claude_monitor/output/official.py#L39-L144)、[独立 API 请求和认证](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor/blob/c59a83bf943f329f0e61f1a29c760353ee1860a5/src/claude_monitor/output/api_usage.py#L168-L284)。
- [CodexBar OAuth fetcher](https://github.com/steipete/CodexBar/blob/d34fbb47afe73f81dd591bae28a60f72c39a9fe4/Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthUsageFetcher.swift#L60-L109)、[Claude 来源与接口](https://github.com/steipete/CodexBar/blob/d34fbb47afe73f81dd591bae28a60f72c39a9fe4/docs/claude.md#L185-L228)、[刷新策略](https://github.com/steipete/CodexBar/blob/d34fbb47afe73f81dd591bae28a60f72c39a9fe4/docs/refresh-loop.md#L10-L53)。

## 本分支采用的本地额度方案

只读现有 `~/.claude-monitor/statusline/latest.json`，不安装任何 `statusLine` 钩子，不改 Claude 配置，不读取凭据、不发 Anthropic 请求。该文件只有用户原先配置了 `claude-monitor --statusline` 才可能存在。

```json
{"captured_at_epoch":1800000000,"rate_limits":{"five_hour":{"used_percentage":25,"resets_at":1800003600}}}
```

- 64KiB 上限，10 分钟新鲜度，未来偏移超过60秒拒绝；窗口到期后不继续显示百分比。
- 缺失、空 tombstone、损坏、过期分别降级为空/不可用，不拿本地 Token 推算“剩余百分比”。
- 缓存不带账户 ID，因此明确显示“最近 Claude 进程，未绑定账号”。多账户场景不能据此声称是当前账户精确额度。
- 云端 Claude Desktop 聊天没有本地 Token 记录时无法统计；本分支仅支持其本地 Code/Agent 会话。

## 待确认的联网部分（未实现）

优先保持上述纯本地方式。若需要无需 statusline 的额度获取，先由用户确认是否接受以下方案，再实施：
1. 默认关闭，独立手动按钮；不和 Token 扫描绑在一起，不在开机或后台自动探测凭据。
2. 用户明确选择已有 Claude CLI 登录来源；不扫描浏览器 Cookie，不同时尝试多个身份，不自动刷新或重写 OAuth token。
3. 按锁定开源实现复现单一 OAuth usage 请求；遵循 Claude CLI 当前网络代理链路，不能因 Token Bar 直连而改变出口 IP。
4. 起步手动刷新且最短间隔15分钟；429/401/403停止并展示状态，不轮换来源、不密集重试；用户可随时关闭。
5. 该端点不是公开稳定的配额 API。已有开源使用不保证不会触发风控，也不能证明对账户/IP无风险。CLI `/usage` 同样可能联网，不能把启动 CLI 当作纯本地无风险方案。

本次调研仅访问公开项目源码，没有对上述 Anthropic/claude.ai 端点执行验证请求。

## Token 口径与持久化

- 新增独立 `multi-client-usage.sqlite`，不修改 Codex 原始索引、原始额度记录、费用账本或计价。
- schema v1：`client_usage_events` 是按客户端+稳定请求ID去重的投影；`client_usage_revisions` 追加保存变化记录；`client_file_checkpoints` 保存原子提交的增量断点。原文、提示词、工具内容及凭据不写入这个账本。
- 同一请求多次 streaming 记录取字段最大值，不累加；输入包含来源单独报告的缓存读/写；思考是输出的子集，不加两遍。没有报告的缓存/思考字段保持空值，显示 `—`。
- 原会话删除、移动、归档或客户端关闭不会清空已记录用量。重新扫描相同请求不重复累计。
- 新文件首次创建，不需要迁移 Codex 表；已有本账本升级前用 SQLite 一致性快照备份（覆盖已提交 WAL），高版本账本拒绝降级写入。Mac设置提供手动备份入口。
- 默认其他客户端读取与显示均关闭；用户分别启用，现有 Codex 显示保持原样。
- DeepSeek/DSH 同时支持 `session.v<N>.jsonl` 和 `.jsonl.zstd`；压缩文件只在内存里读取完整帧和完整行，不解压落盘、不重新压缩，未完成的尾帧保留断点。
- JSONL增量读取，不重复加载整个历史；单次4MiB，未完成尾行不推进断点；普通JSON16MiB上限；每轮有界文件批次，60秒本地刷新，可手动刷新。
- DSH会话身份来自 `session.id` 或 `snapshot.header.id`，在追加及重启后继续沿用；无文件头时用会话目录区分同名版本文件。首段上下文解析有4MiB压缩/原始读取与16MiB解码上限，内存缓存有界，不随每条Token扫描重复解压整份历史。
- OpenCode数据库采用只读分页；旧版 message JSON 也可读取。历史导入中的进度/异常必须与最终累计值一起说明。
- 无稳定ID时的元数据回退身份带 `fallback_identity`。这种来源无法严格证明不同文本版本/复制会话完全去重，不能当作提供方账单凭证。不要用 Token 值推断订阅收费。

## 与原测速分支的合并

本分支没有引用或修改 `AgentSpeedReporting*`、Vendor/AgentSpeed、上报 helper、网络注册和签名代码，也没有改 Package.swift。解析实现参考锁定的 Agent Speed 1.4.1 (`a94a67fcc78e5d8eea5f82d8d5e737bccf994e2c`) 本地格式，保持独立类型 `UsageClient` / `ClientUsageEvent`。

合并时保留两条路：
- 本分支：用户本地历史 Token 账本、可回扫、长期保留，不发送数据。
- 原分支：独立实时测速/上报、首窗baseline、默认关闭，不从本分支历史账本补报。

预计小范围冲突：`CodexTokenBarApp.swift` 启动注册、`AppSettingsView.swift`/`AppSettingsDialog.tsx` 两个新增设置类别、`DashboardPage.tsx` 插入卡片、Rust `mod.rs/lib.rs` command列表。两边新增项都保留，不把某一侧文件整体覆盖另一侧。数据库名称、偏好key、命令和类型都有不同前缀。

## 支持范围与显示设置

Mac：每个客户端独立的读取、侧栏、菜单栏开关，颜色、排序、紧凑/详细样式及可选目录；设置持久化。Claude本地额度可独立显示在侧栏或菜单栏，支持颜色、前后位置、紧凑/详细侧栏。Codex现有状态栏设置保留，新增侧栏额度开关和颜色，默认样式保持原样。

Tauri/Windows：Token读取、存储结构、客户端显示设置、侧栏、Claude本地额度面板同步；客户端菜单栏选项映射到Windows托盘提示文字（Windows托盘提示不支持分段颜色）。Claude额度独立菜单栏数字暂为Mac能力，Windows没有提供无效开关。Windows原生显示和安装验收未进行。

这不是所有软件的云端账单聚合：Claude Desktop仅本地Code/Agent日志；DeepSeek仅DSH支持格式及OpenCode等已有harness中的模型用量；没有本地使用记录的软件不会被推算或冒充有记录。供应商改变日志字段或缺少稳定请求ID会影响覆盖/去重，界面保留未知字段。

扫描是有界增量投影：首次大历史需多轮完成；超出自动发现文件/深度上限会提示，用户可指定较小目录补读。普通追加、原子替换、缩短、同大小改写且mtime改变均会重读；固定前4KiB指纹无法证明大文件中段的任意覆写，尤其覆写同时增长且保留前缀时可能需重新扫描。OpenCode若更新同时伪装为完全相同的size/mtime，也不能仅凭文件元数据发现。没有把此类未验证边界宣称为无损备份。

## 验证回执

见 [验证回执](2026-10-25-multi-client-tokens-validation.md)。此处的编译/单元/UI测试不等于安装验收；Mac正式应用和Windows EXE均未改动。浏览器预览使用明确标注的合成测试样例。
