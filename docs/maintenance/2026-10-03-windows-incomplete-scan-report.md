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
- 本机只读抽查：active rollout 引用3206条，3205条存在，1条失效；sessions/archived_sessions 未发现 .zst。失效项没有对应压缩文件，不能将其归因于该功能。
- Windows 用户现场还未取得底层路径或压缩文件证据。可以确认潜在兼容冲突，不能确认截图的实际根因。需诊断版日志区分“失效路径+压缩副本”“直接引用非JSONL”“权限/占用”等原因。
- legacy-to-paginated 历史迁移与本地磁盘压缩也不同；本轮不操作迁移、解压、删除或重建用户数据。

## 验证

- PASS：Node诊断回归13项；标准库Rust诊断测试4项；Swift诊断独立编译/运行；diff检查。
- 待云端：完整Swift/Rust/前端构建及缺失/压缩rollout保留旧账的集成回归。
- NOT_RUN：该Windows用户机器复现/恢复；新安装包实机升级。
- 未发布新版本；本轮是诊断补齐，不把测试通过作为客户故障已恢复的证据。
