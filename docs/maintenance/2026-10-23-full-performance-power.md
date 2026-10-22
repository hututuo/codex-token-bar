# 全软件性能与功耗复查 · 2026-10-23

## 范围与交付

在 `codex/full-performance-power-20261023` 上继续 build945 的侧栏/滚动修复。初次原生验收 build946；按需布局补充后的最终候选为 0.9.7 build947；Windows 共用前端同步模型色与进度通知去重。安装、真实运行和 Windows 执行结果记录在项目外层 `runs/20261023-full-performance-audit/`，不把源码测试等同于已安装。

模型色统一为 Astra `#36ad77` 绿、GPT-6.1 Sol `#ed932b` 橙、GPT-6 Luna `#4299f5` 蓝。沿用双端共享的模型注册表，覆盖模型用量、速率叠条、正文 TPS、趋势及模型标签。

## 审计与处理

| 路径 | 结果与动作 | 数据/显示保证 |
| --- | --- | --- |
| 主界面趋势、明细、侧栏伸缩 | 保留 build945 的趋势缓存与侧栏帧时钟；用 864 点、10Hz 数据通知的生产视图复测；装机采样后将主页 eager VStack 改为 LazyVStack，避免速率变动时布局视野外图表 | 不降低采集频率；复核图表开关、滚动与稳定 ID 跳转 |
| 图表演示、翻页引导、雷达边框、未读动效 | 新增事件驱动的可见性门控：滚出视野、遮挡、最小化后暂停；低电量/减少动态效果时静态显示 | 不依赖 App 是否前台；未读状态保留静态边框；真实雷达倒计时继续 |
| 速率条渐变 | 缓存配色/比例/显示模式；宽度变化复用渐变，配置使用禁用隐式动画的事务 | 比例或外观变化仍立即重设；隐藏/低功耗时几何值更新但不播放宽度动画 |
| 正文测速读取 | 从每秒重送保留历史改为逐文件 revision/ack 增量 | 通过源和 generation 校验后才确认；解析失败、过期批次、失败重试不会误确认；旧历史完整快照保留 |
| 正文保留缓存 | 保留集过期清理最多每分钟一次；新记录批内用 Set 去重 | 保留现有 30 天/每文件 2000 条上限；不删除用量历史和费用索引 |
| 5/15/30 分钟及 7 天模型均速 | 新记录/模型归属变更时重算，无变化时只在样本跨窗口边界时重算 | 处理包含边界、未来样本及时间回拨；不让滑动窗口冻结 |
| Windows 精确扫描进度 | 完整字段比较，相同载荷不重复 setState | 所有时间与阶段字段仍参与比较，真实进度更新不被吞掉 |
| Windows 图表引导字体 | 旧的直接字重声明改用已有 medium token | 视觉权重不变，恢复统一样式检查 |
| 数据库/主扫描/额度网络路径 | 检查现有调度和后台所有者门控，保持信任校验/断点/历史账本行为 | 本次无 schema、网络接口或权限变更 |

## 验证

- Swift 相关综合回归：171 项，169 通过、2 个需显式环境变量的测试跳过、0 失败。
- 最终新配色/正文增量/窗口边界/可见性回归：22 项，21 通过、1 个真实日志审计入口未启用跳过、0 失败。
- 单独启用真实本地 JSONL 审计：20 个最近未压缩文件，只输出数字与时长，写入独立测试 SQLite；不修改生产数据库。无新增读取约 0.9ms，待交付增量 0；起始重放约 1.70s（171 条），保留快照 182 条；SQLite 写入约 7.2ms、24h 趋势读取约 0.8ms。活跃文件可能继续增长，不能把两次数量差当成丢失。
- 原生 864 点测试：趋势页可见时刷新 p50 0.85ms、p95 2.47ms；主线程运行循环间隔 p95 6.58ms；侧栏窗口 resize 间隔 p95 16.13ms。负载含当前真实 Codex 会话和测试任务，不是独占机器的帧率保证。
- 前端完整测试、生产构建、Windows 实机执行以及原生安装签名/运行证据，见运行目录最终记录。

补充原生回归包含真实 SwiftUI ScrollView 中屏外内容的可见性测试，确认屏外暂停并非只在 AppKit 手工夹具成立。最终按需布局相关 85 项回归：83 通过、2 项 opt-in 跳过、0 失败。补充了生产缩放容器 100% 下仍只装载可见 section 的测试。扩大回归还发现两个旧测试问题：费用行已采用固定四列网格，测试仍要求已经不用的 layoutPriority；异步覆盖测试把 Task.yield 次数当成超时，改为真实 5 秒截止。均已修正并复测。最终 build947 的安装与 UI 验证以运行目录为准。

## 测量边界

build945 的运行采样显示当前活跃成本主要还包括 RunningThreadScanner 与 JSONL 解析。正在运行的会话不能拿来当待机功耗基线；本次不宣称实测瓦数或整体 CPU 下降百分比。

另外检查了流式批次主线程解码/分词、Windows 长区间选区计算、数据源目录身份读取。没有在当前实机样本中确认它们为新的阻塞根因；贸然暂停承担侧栏供数的后台计时器会改变产品语义，未作这种优化。真实数据采集继续运行，装饰动效单独暂停。各类硬件/多显示器/网络负载并未被一次审计穷尽。

## 本机替换与回滚

安装过程需严格校验现有 build945、候选 build946、稳定的 bundle ID/designated requirement、Sparkle feed/public key 与模型库 SHA256；先正常退出，原 app 保存到唯一备份目录后原子替换，再核对进程路径和实机界面。界面/性能补丁不恢复旧数据库。实际签名、校验值、备份路径与运行状态写入安装收据。

## English

This pass standardizes Astra green, GPT-6.1 Sol orange and GPT-6 Luna blue across both model registries. It stops invisible decorative animation, avoids rebuilding unchanged rate gradients and speed summaries, delivers completed-body samples incrementally with acceptance acknowledgements, and suppresses identical Windows scan-progress updates. Existing history, accounting, source validation and sampling cadence remain intact. Tests, synthetic UI timings, local log timings and installed-runtime acceptance are recorded separately; no idle-power or universal frame-rate claim is made.
