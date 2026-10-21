# 正文计时测速接入 / Completed-body speed

## 口径

不做代理、不修改 Codex 网络路径。主显示采用本地正文计时：

`o200k_base(同一输出项的完整正文) / ((completed_at_ms - started_at_ms) / 1000)`

包括中间 commentary 和最终正文；不包含隐藏思考、工具执行结果、工具调用输入、请求首包等待。分词是本地文本的 o200k 计数，不宣称等于所有模型的服务端计费 token。

- 实时增量（原 A）：按本机收到正文更新的时间测速，扣除首段 token；仍保留作补充明细。
- 正文计时（B，现主来源）：以 JSONL 的 AgentMessage 起止时间与完整正文精确配对，输出完成后更新。
- CC Switch 非代理导入（C）：结算 output（包括 reasoning）除以重建的整次请求区间。与 B 都是数量除以时间，但分子、分母都不同。
- CC Switch 代理的 `output / (latency - TTFT)` 属于另一条路径，本项目不接入。

旧实时 IPC 能连接但当前 Codex 未发布所关注会话的 snapshot/patch，不能把“接口已连接”当成已测到正文。此前“owner”指内部负责发布这些更新的组件；停止发布的具体触发未查实。本次不靠重试该组件来保证主测速可用，也不要求重启 Codex。

## 实现边界

Swift `CompletedBodySpeedReader` 在实时监控同一次 rollout poll 的 utility actor 内读取；Rust `completed_body` 在后台 reader 读取。独立游标只用于测速，不把历史回放到动画或用量索引。首轮最多读取每文件尾部 8 MiB、每批总计 64 MiB、最近最多 64 个线程、最近 30 分钟；后续每秒检查完整追加行。

配对键为会话、轮次、输出 ID；允许先看到正文或先看到结束事件，以及跨批次到达。正文字数/分词只在完整配对后计算，不为每个小增量重复分词。正文最多 1 MiB；待配对项最多 32 个/4 MiB；轮次模型上下文有固定上限。解析模型只使用对应轮次，不借用当前轮次模型。未知模型不混入已知模型均值。

fork 继承内容依据现有 paginated 边界与子线程/轮次 UUIDv7 创建时间证明排除；fork 后新增轮次保留。文件丢失不删除既有测速记录；同 inode 变长重写也验证游标前边界，不匹配则重读有界尾部。稳定输出 ID 去重，重读不重复累计。

旧测速文件及原有记录继续读取；新增 `measurementKind` / `tokenizer` 可选字段。仅持久化数字与定位 ID，不保存正文。每个来源分区保持既有 hash/scope，不迁移或清空用量索引。近期同模型均速采用 token 总量除以时长总和，主汇总只含 completed_body，避免与同一输出的实时样本重复累计。

macOS 随包附带 SHA256 校验的 o200k 词表；正文测速与精确分词开关互相独立。启用精确分词时也复用本地词表，不需首次联网下载。正常用户无需安装 Python/Node/tokenizer 服务。

## 置信度与误差

单段 ≥500 token 且≥5秒为较高，≥100 token 且≥2秒为中等，其余较低；短段仍保留在明细与参考汇总中。等级表示样本长度，不是置信区间，更不证明网络正常。

两条边界无法判断中间发生了网络缓冲、服务器暂停还是持续输出。UI 明确标注“正文计时”，网络情况标为无法判断。历史 IPC 明细保留原来的更新次数、停顿警告与原分词口径，不追改成 o200k。

## 验证

- Swift 定向与实时监控回归：122 项，121 PASS，1 项 opt-in 真数据审计默认跳过；真数据审计单独运行 PASS。
- 覆盖乱序/分批配对、相邻轮次模型归属、非法时长/boolean、工具输出排除、待配对容量、fork 继承和新轮、Unicode/超过 16K 正文分词、旧记录读回、重复回填、半行追加、同 inode 变长重写、源文件删除后保留历史。
- 生产 reader 在本机真实数据上已补出样本并得到按模型汇总。本轮一次回测：Luna 6 段，1570 token / 12.665 秒 = 123.96 tok/s；Sol 6 段，579 token / 16.192 秒 = 35.76 tok/s。这是当时的小样本，不能当成模型排名。
- 该次 debug 初始化、回填与后续检查约 1.14 秒；稳定增量检查约 2.5 毫秒。macOS 发布包内词表 SHA256 与源码声明一致，ad-hoc strict 签名校验 PASS。
- 914 已安装验证：266 条原测速记录全部保留且原字段逐项不变，新增正文样本实时写入；Codex 主进程及主 CLI 未重启。915 增加同 inode 重写边界检查与简洁来源状态。
- 真实数据、安装回执与回滚包保存在外层 `runs/20261021-completed-body-speed/`，不提交私人样本。
- Rust 最终测速相关回归：103/103 PASS；TypeScript/Vite 构建 PASS。完整库一次运行 1295 PASS / 10 ignored；为保存日志的重复全库运行是 1294 PASS / 1 FAIL / 10 ignored，唯一失败为未改动的 `cache_lifecycle` 重复保存测试目录项断言（期望 1，实际 2），隔离复跑 PASS。并行/环境偶发原因尚未证明，不把这次全库运行记成全绿。
- 新 Rust 生产 reader 模块及其分词依赖通过 Windows x64 MSVC 目标 `cargo check`。使用相同本机文件的两次跨端审计中，12 段共同输出的模型、token、时长一致；较早读取额外的 3 段在稍后读取时已超出 30 分钟，稍后另有 2 段新输出。
- 最终 macOS 安装版为 0.9.5 (916)：主界面正文计时均速可用、实时增量另示“暂无”。按整个 poll 批次一次去重，空批次不构造索引；原 266 条测速记录逐项保留。913/914/915 回滚包与最终安装回执在外层审计目录。
- Windows 源码已同步；局域网 SSH `192.168.123.50` 本轮连接超时，Windows 完整可执行包和实机安装均为 NOT_RUN。交叉模块编译及 macOS 上的 Rust 测试不能替代 Windows 实机验收。

## English

The primary rate now uses complete visible assistant-body token counts from the bundled offline o200k vocabulary divided by the explicit local body start/end interval. This requires no proxy and no Codex restart. Forwarded live deltas remain supplementary records; they are not double-counted in the model average. Existing numeric history is preserved. Short samples remain visible, and the UI explicitly states that two boundary timestamps cannot diagnose network or server stalls. Bounded background backfill and incremental reads do not replay old usage into the live curve or alter accounting indexes.
