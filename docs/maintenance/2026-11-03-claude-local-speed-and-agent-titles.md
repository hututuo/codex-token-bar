# Claude 本地速度平滑与 Agent 标题

## 范围

- 原生 Mac 与 Windows/Tauri 同步。Claude 仍仅使用已有本地日志读取器，不启动 Claude、不调用 Anthropic、不读取凭据。
- 不改数据库、迁移、Token/费用账本、正文 TPS、采样单价或排行榜上报算法。
- Agent Speed 固定版本不升级；局部适配记录在 Vendor/AgentSpeed/UPSTREAM.json 与 VENDOR.md。

## 速度

原来两个客户端已使用相同的三分钟连线组件，但 Claude 直接使用 Agent Speed 的活动估计，缺少 Codex Bar 的升降平滑，因此收到响应时会突升、窗口过后突降。

- 提取 Codex 已有的上升 0.28、下降 0.18 的响应函数，Codex 每秒调用的算式和结果保持原样。
- Claude 的 Bar 模式按模型使用同一响应函数，按时间差调整权重，避免轮询频率改变滤波强度；没有新增定时器。
- 明确停止、读取器不可用时立即清空；超过 3.5 秒的采样中断重置滤波器，正常完成/零输入以三次曲线收尾，尾迹最长 5 秒。
- 两级菜单的色条、色环、近三分钟曲线与相关活动速度读数使用同一显示投影。
- Agent Speed 模式仍显示原始估计。其采样、实际用量和网络上报都不读取平滑结果。
- 曲线仅保留有上限的三分钟内存数据，不新增数据库写入。

## Agent 名称

原读取器只保留模型、状态、父子关系等信息，没有传递 Claude 日志中的名称；原生详情还写死了 Claude session/subagent。

- 本地标题优先采用该会话文件里的 agentName，其次 title/customTitle/summary，缺少明确元数据时采用首条有效用户文本的一行摘要。
- 不从父会话的工具参数猜测子 Agent 名称；子 Agent 只使用自身文件的证据。
- 工具结果、系统提示块、取消标记不能充当标题；标题清除控制字符并限制长度。
- Swift 读取器将标题传给现有 RunningThreadSummary，并保留没有子 Agent 的独立主任务行；Windows 读取器经匿名管道传给 Rust，再传给现有任务列表。
- Windows IPC 增加可选 title/displayStopped 字段，旧 helper 缺少字段时仍可读取；保留字段白名单与长度检查。
- 标题仅用于本地任务界面，不进入报告正文或签名数据。没有证据时仍显示通用名称，不编造名称。

## 验证

- 本地 TypeScript 类型检查通过。
- 前端完整测试 1,408 项通过（后续增加的正常完成/取消区分用例另跑），包含名称转义、父子归组、缺失名称回退、平滑系数、时间一致性、重复帧、停止与断档。
- 原始 Swift 平滑源文件的独立最小包测试 3 项通过；该结果不替代完整应用测试。
- 补充原生任务名称、运行时原值/平滑隔离、停止清空、双模式历史隔离测试。
- 补充 Rust 旧 helper 默认字段兼容、标题边界和停止状态测试。
- Windows 标准 CI 增加 ClaudeLocalReader 的编译与本地隐私自检。
- vendored Swift ParserBehaviorTests 独立包 17 项通过；全量云端任务随后按用户要求取消，相关已完成记录与定向检查结果见下。

尚未打包、安装或重启本机正式版，未发布更新。

## 本轮追加反馈与定向验证

用户要求停止全量检查，后续只跑改动相关检查。已取消排队及运行中的全量任务；后续源码提交跳过自动全量 CI。手动 `claude_reader_only` 只运行 Windows 本地读取器和共享解析器自检，不运行账本升级、全量回归或打包。

- 二级速度曲线图例改为与对应曲线同色的短标签：Claude C / Claude D；三级详细标签保留完整名称。
- 本机费用未知的直接原因：价表包含 `claude-opus-5-5`，但现有多客户端事件模型只保留缓存写入总量。`apiCostMicroUSD` 遇到缓存写入大于零且 5 分钟/1 小时单价不同，会拒绝给出完整金额。本地六份近期 JSONL 的抽样 264 条 usage 均含 `cache_creation.ephemeral_5m_input_tokens` 和 `ephemeral_1h_input_tokens`，也均有非零 1 小时写入；当前账本 payload 丢掉了该拆分。不能默认按 5 分钟单价估填。此轮尚未改动该计账链路。
- 本机 Desktop 未显示额度的原因：当前额度提供者仅读取 Code statusLine 产出的两种本地缓存，两份均不存在；Code 设置也未启用 statusLine 生产者。Desktop 正在运行/有会话用量，不代表当前提供者已取得 Desktop 额度。未发出 Anthropic 请求，未修改 Claude 配置。
- Swift/TS 原始平滑源代码同样 11 帧输入对照，最大绝对差为 0。
- 先前已完成的云端记录中，完整 Swift 模块成功编译，相关 ClaudeLocalRuntimeTests 8 项、ActivityRateSmoothingTests 3 项通过；Windows Rust 的 `claude_local_runtime::tests` 22 项通过。这些是已取消全量任务中的相关通过记录，不能记作整轮全量成功。
- Windows 初轮 C# 编译的 CS0136 已修正；新加的 helper CI 命令补齐与发布脚本一致的 Nullable/ImplicitUsings 编译选项。其专用定向自检结果另记。

### 定向收尾结果

- 二级图例、Claude 本地任务和平滑相关前端测试 15/15 通过；TypeScript 类型检查通过。
- 当前彩色图例函数的 SwiftUI 独立类型检查通过；完整界面未安装验证。
- 定向 Windows 检查：[41659937410](https://github.com/hututuo/codex-token-bar/actions/runs/41659937410)，对应源码 `eac8abd834e4e1bcffbcc0627d00d4f4ce7a7b76`。`claude-reader` job 126000250452 成功，其他全量/升级/打包相关 job 全部 skipped；包含共享解析器（名称、重命名、长文本、顺序兼容等）与 ClaudeLocalReader IPC/缓存/隐私自检。
- 第二次 Desktop 日志调查仅抽样六个近期文件（每份最多 512 KiB）：两个项目 JSONL、两个 Claude Logs 文件、两个 Application Support 的日志文件。未找到可供当前提供者使用的结构化额度百分比/窗口/重置字段；此结果不证明其他未调查缓存中绝对不存在额度数据。
- 尚未补存缓存写入时效拆分或重算 Claude 金额；该问题已定位，尚非价格修复完成。
- 本机仍是此前 build 992。没有安装本轮源码、没有发布或更改 Claude 配置。
