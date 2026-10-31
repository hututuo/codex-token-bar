# Agent Speed 发版前差异审查（2026-10-31）

审查基线：内置 `a94a67fcc78e5d8eea5f82d8d5e737bccf994e2c`；公开上游 `384ce020cc655133e95aaad5cc085f3985f0ed99`（1.6.1）。只读取 GitHub 与独立 checkout；没有启动上游应用、读取用户凭据、请求 Anthropic 或运行联网诊断。

## 本次选择性回补

|修复|来源|本地处理|
|---|---|---|
|分页子 Agent 继承前缀|[Swift 004bc9b](https://github.com/zoefix/agent-speed/commit/004bc9bb859145561fcacf1d9e98ac735d94ef91)、[C# e44df87](https://github.com/zoefix/agent-speed/commit/e44df871546226430c6fde9bd9853d3422dae4e4)|严格解析非负 Int64 ordinal；只跳过边界前记录，保留边界及之后的新增输出；过滤在本地错误停速判断之前，继承错误不会停止子会话。|
|Claude 工具结束任务|[b89d983](https://github.com/zoefix/agent-speed/commit/b89d9834a76f8e00efdc88938a4c96736ec889e5)|只接受 user 记录的布尔 toolEndsTurn，进入 idle 并清除待计时状态；不生成虚构用量。|
|安静文件跨夜恢复|[c668286](https://github.com/zoefix/agent-speed/commit/c6682868f5e749972b276c800c9a2535e01decf4)|Mac 每轮重新检查24小时内文件，较老文件每轮检查六分之一；保持增量读取、共享IO和原始观察时间。Windows 已按轮检查全部文件，不增加第二套扫描。|
|WebSocket 未知消息|[上游 METRICS 11.5](https://github.com/zoefix/agent-speed/blob/384ce020cc655133e95aaad5cc085f3985f0ed99/spec/METRICS.md)|双端忽略未知但有合法 type 的消息；已知 ACK/error 保持结构检查；未知消息不算成功、不解除待确认报告，也不延长 ACK 超时。Mac 明确分离畸形消息与合法但不匹配的 ACK。|

基础 pin 不变，逐文件本地补丁和原因记录在 `Vendor/AgentSpeed/UPSTREAM.json`。分析修订由本地4提升为5，标记已改变的分页归属语义；不冒充上游完整历史版本，不升级业务数据库 schema，也不启动另一份 HistoryService。

## 暂不引入

上游新增的性能评分、工具信号、配置强度、新客户端和新的默认传输策略不属于这次兼容修复。上报协议仍为 v1；perfScore、executionModes v2 等是可选扩展。保留默认 HTTP、用户主动选择 WebSocket、默认关闭上报和 Claude 禁止上报的边界。

当前 vendored 价表已含 GPT-6.1 Terra，OpenAI/Anthropic/DeepSeek 既有模型的数值与上游对应项一致，无需用新价格重算历史。保留原冻结历史价格。发现接口已使用完整读取，不需要回补取消 ETag 的改动。

## 验证门槛

- 双端执行同一份25例纯合成 parser fixture；覆盖边界前/边界/边界后、错误继承、未知/非法/溢出 ordinal、Claude 结束工具与正常继续工具。
- Windows 额外覆盖 Reset 后不遗留子 Agent 边界；不需要用户数据或凭据。
- Mac 采用上游的跨夜恢复与六轮有界检查测试。
- 双端覆盖未知消息、畸形已知消息、重复JSON键、合法不匹配ACK；继续检查默认关闭、Claude来源保护和重试。
- 完整Swift/Rust/TS、Windows构建及真实 v0.9.7 升级验证，待冻结 SHA 云端回执。此前 build986 的结果不能替代本次新增源码的结果。

本次不重复用户交互验收，不自动替换本机或 Windows 应用。发版包、更新签名与发布说明先准备在当前分支；不创建公开 tag、不发布更新源。
