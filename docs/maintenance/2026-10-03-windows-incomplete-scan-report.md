# Windows 0.9.2 → 0.9.3 扫描失败反馈

## 已确认

- 用户反馈平台为 Windows，未获悉目录迁移；截图来自 Tauri 完整日志。
- `read_precise_dashboard_snapshot` 与 `read_usage_summary_snapshot` 返回“会话源扫描不完整”。这里“停止发布”指停止发布新一轮统计 generation，不是软件更新或 GitHub Release。
- `live_rate_summary` 的缓存未就绪提示由缺少可用汇总快照触发，不是独立的重复计数故障证据。
- v0.9.2 发布源码 `21df80f56ed76b68756dc616d9728c46474acca1` 与 v0.9.3 `ba4c59060c240af703e42d288c303a56cb0259e3` 的 `exact_usage_index.rs` 字节一致，SHA256 为 `231e382c8ad8820ddd51d5f10a3ecef25ccc8e8b31079e291dd22a86401180cd`；schema13 未变。
- 该范围 Rust usage 模块的源码差异仅为两处 quota 占位值增加 `reserve_windows`，没有修改会话扫描规则。
- 代码允许多种故障触发：目录/文件权限或占用、物理身份读取失败、state_5.sqlite 读取失败、active rollout 路径不能解析。现有回归测试覆盖不存在 active rollout 时拒绝发布、保留旧账及断点。
- 精确刷新 owner 错误分支丢弃本轮 warnings；底层具体路径和 OS error 没有进入 GUI 错误。performance trace 也只保存错误类别。因此截图不能证明具体是哪种故障。

## 诊断补齐（直接 main）

- 精确刷新各失败阶段将本轮具体 warning、阶段、Codex Home、软件版本、OS/架构一起返回 GUI，并写入有容量限制的 performance trace。保留最早和最近各4条 warning，每条最多768字符；基础错误最多8192字符。
- 预扫描回退不再吞掉原因；线程启动失败保留 OS error，执行异常保留阶段和有限文本原因。
- active rollout 预扫描的 canonicalize 失败保留底层 OS error；失效普通 JSONL 路径若存在 Home 内对应 .jsonl.zst，附加明确压缩格式提示。目录中发现压缩格式也产生一条诊断。
- 跨平台错误格式保留结构化 code、message、cause；有循环/长度限制，并屏蔽凭据字段和 Bearer token。平台桥接不再把结构化错误替换成 Unknown。
- 日志窗口与复制报告同时包含版本、运行环境、当前数据源。历史条目保存发生时的数据源，避免换 Home 后把旧错误归属到新目录。
- Swift 记录 NSError domain/code、文件路径和底层错误；不整体打印 userInfo。报告包含 build、架构和数据源。
- 额度 HTTP 诊断保留超时/连接的底层原因链、HTTP状态及Content-Type、JSON解析行列/类别/响应大小，不记录认证请求头、凭据或响应正文。
- 索引扫描边界、统计 generation 发布规则、旧账/断点保护均未放宽。未添加压缩解码支持，也不修改 Codex 的文件或数据库。

## Codex 本地聊天历史压缩调查

- 用户说的设置不是普通模型上下文 compaction。本机桌面 bundle 的中文文案为“压缩较早的本地聊天历史记录，以节省磁盘空间”，配置项为 features.local_thread_store_compression；连接建立时通过 rollout/compress 发起压缩。
- 本机随桌面版提供的 Codex 可执行文件包含 .jsonl.zst、rollout-compression.lock、compressed rollout reader 和 materialization 等格式/处理标记。Token Bar 两端当前的统计目录发现均仅接受普通 JSONL，因此存在压缩存储兼容性缺口。
- 普通上下文 compaction 标记属于另一条路径；实时缓存提醒已有 compacted / context_compacted 重置处理。Codex 官方 [App Server 文档](https://learn.chatgpt.com/docs/app-server) 将 thread/compact/start 描述为上下文压缩操作，不能用它推断磁盘压缩行为。
- 开启前本机只读抽查：active rollout 引用3206条，3205条存在，1条失效；sessions/archived_sessions 未发现 .zst。失效项没有对应压缩文件，不能将其归因于该功能。
- Windows 用户现场还未取得底层路径或压缩文件证据。可以确认潜在兼容冲突，不能确认截图的实际根因。需诊断版日志区分“失效路径+压缩副本”“直接引用非JSONL”“权限/占用”等原因。
- legacy-to-paginated 历史迁移与本地磁盘压缩也不同；本轮不操作迁移、解压、删除或重建用户数据。

### 设置身份与版本边界（2026-10-03 补查）

- 本机桌面版本26.930.31730、build12947。中文设置标题为“压缩本地保存的聊天历史记录”，描述为“压缩较早的本地聊天历史记录，以节省磁盘空间。重启 {appName} 后更改生效。”general-settings bundle按 `local_thread_store_compression` 选择该项；主进程读取同名features配置并请求 `rollout/compress`，确认是同一个功能。
- 桌面bundle的 `rolloutCompression` 后端能力最低版本门槛为 `0.155.0-alpha.13`。这是客户端的能力判断门槛，不足以证明桌面设置首发版本或压缩引擎首次加入版本。
- [官方更新日志](https://learn.chatgpt.com/docs/changelog)在2026-09-22的Codex CLI 0.156.0完整变更中列出#46020“Add an experimental rollout compression endpoint”。这是可核实的稳定版接口发布记录；公开页面没有给出此桌面开关首次上线的具体build，不能拿CLI版本替代桌面版本。

### 建议兼容方案（尚未实现）

- 索引升级、已压缩/已报错用户恢复、旧账保留、性能复用及降级策略的完整设计见：[压缩历史索引 v14 方案](2026-10-03-compressed-history-index-v14-plan.md)。v14 为建议版本，尚未执行数据库迁移。
- 先用真实Codex压缩样本核实容器、解码后的JSONL结构及状态库路径转换；不能仅凭扩展名假定所有文件都能直接解码。
- Rust和Swift统一增加只读会话源抽象：发现普通JSONL及压缩副本，流式解码后复用现有事件解析器。保留Home边界校验，不写入、批量展开或改变Codex自己的存储设置。
- 将同一会话的普通/压缩表示关联到相同逻辑来源，格式切换不算新会话或删除；两种表示同时存在也只计一次。解码内容与已有账本事件一致时保持原统计不变。
- 优先复用完整、可信的已有索引。固定核查CLI 0.160.0源码a956835d后确认：原生压缩写入原始长度并保留mtime，且普通文件优先、追加时重新展开。正常单帧转换可设计元数据快速路径，按同一Home、会话及逻辑来源关联，只登记新物理表示和指纹，保留原source及账本事件。首帧长度不是整个文件长度，不能对未知或多帧格式盲目采用；元数据匹配也不等于全文内容证明，必须分别记录历史账本可信性与当前来源验证状态。异常来源再做流式内容/分块核对。后续压缩文件指纹稳定时只做轻量元数据检查。完整依据见本地runs/20261003-compression-experiment/source-review.md；真实开启后的实测见下节。
- 物理文件大小/指纹和解码后的进度分开管理。只有未索引、已有索引不完整、内容确实变化或需修复的来源才进入解码解析及账本核对；不能拿压缩字节偏移套用现有JSONL增量断点。普通JSONL继续走现有增量路径。来源迁移、双副本选择与事件去重须在同一事务中维护，不能把压缩副本当新增来源直接累加。
- 压缩/重新展开期间出现文件替换或消失，做有限重试并复核文件身份；仍不稳定、解码失败或内容不完整时保留可信旧账，输出阶段、路径及底层原因，不发布部分统计。
- 验收覆盖普通→压缩→重新展开统计一致、双副本去重、状态库路径过渡、并发替换、损坏/截断文件、大文件有界内存、重启断点及macOS/Windows同结果。当前诊断改动与云端测试不等于以上压缩读取兼容已经实现。

## 验证

### 本机开启压缩后的实测（2026-10-03）

- 用户开启并重启后，3284份历史转为压缩格式；两次检查集合稳定，无压缩临时文件。全部单帧边界/原始长度/mtime与备份一致，6份流式解码SHA256抽样也一致；并非全量内容哈希核验。
- state_5.sqlite仍保留普通JSONL路径，其中3213条对应文件已转为压缩副本。这证实现有路径扫描确有兼容缺口；仍不能代替客户Windows机器的现场原因确认。
- Swift备份索引可复用3281份，3份未索引；本机较旧Rust索引可复用2619份，其余385份长度变化、279份未索引、1份mtime不匹配。不能跨平台套用索引覆盖结果。
- 当前Swift将3281份已索引压缩来源误标失踪。3124份有历史事件的压缩来源，其396718条事件数量与token合计开启前后均不变；旧账仍在，未观察到这批历史重复入账。
- 详细证据保存在本地runs/20261003-compression-experiment/README.md；备份在Home之外的私有目录。尚未实现或发布压缩读取/索引关联兼容代码。

### 已发布到main的诊断改动检查

- PASS：Node诊断回归13项；标准库Rust诊断测试4项；Swift诊断独立编译/运行；diff检查。
- PASS：[完整云端检查37114236505](https://github.com/hututuo/codex-token-bar/actions/runs/37114236505)，源码d3e92160595dbf7c2fc9e0efe804766095404532。
- 前端1166项测试、11项云端流程测试和生产构建通过。
- macOS Rust1168通过/10忽略；Windows Rust1118通过/10忽略；两端均通过缺失active rollout、对应压缩副本诊断及两万文件回归。Windows打包脚本self-test通过。
- Swift执行1629项，7跳过、0失败；新增错误原因和历史数据源回归通过。
- 第一轮因新增错误格式器的TypeScript类型收窄失败；修正后以上同SHA全套检查和CI证据封存通过。
- NOT_RUN：该Windows用户机器复现/恢复；新安装包实机升级。
- 未发布新版本；本轮是诊断补齐，不把测试通过作为客户故障已恢复的证据。
