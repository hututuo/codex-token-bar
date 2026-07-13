# Codex Token Bar v0.7.3 大优化报告

状态：**已发布**

- 日期：2026-07-13
- 分支：`release/v0.7.3`
- 上一正式版本：`v0.7.2`
- 资产源码提交：`0c4977461db54d99e0a94ee6203d5053dd4c40c3`
- 发布 tag 提交：`820a7e72cf4a5801331d07dcab43a7ab0cff917a`
- GitHub Release：`https://github.com/hututuo/codex-token-bar/releases/tag/v0.7.3`
- 当前完整证据：`release-ledger/v0.7.3.md`

## 1. 总结

v0.7.3 不是单点功能更新，而是一次覆盖 macOS Swift 原生版与 Windows Tauri 跨平台版的系统性收束。工作从 v0.7.2 全项目审查开始，最终落到五个用户可感知目标：

1. 官方额度窗口变化时，两端都能按真实窗口自适应，不再把 `primary` 固定解释成 5 小时额度。
2. 主界面、悬浮窗、状态栏/托盘使用同一批可信数据，来源切换、后台刷新和迟到异步结果不会覆盖当前状态。
3. 顶部工具区、额度条、雷达与活动图更紧凑、清楚、可点击，并补齐键盘与辅助功能语义。
4. 无可见界面时显著降低后台工作，同时保留未读任务和恢复可见界面后的即时刷新。
5. Provider Repair、Windows 单实例、自启动、更新提醒和发布脚本达到可审计、可回滚、失败关闭的边界。

从 `v0.7.2` 到当前候选共包含 259 个提交，其中包括审查材料、测试门禁、平台修复、发布工具和最终 UI/数据优化。大量提交是对同一高风险边界的逐步验证与收束，不代表 259 个独立用户功能。

## 2. 双端额度与历史数据

### 2.1 官方窗口自适应

真实本机接口已经出现：`primary.windowDurationMins = 10080`、`secondary = null`。这表示官方只返回 7 天窗口，而不是只返回 5 小时窗口。

本版在 Swift 与 Tauri 中统一按 `windowDurationMins` 识别窗口身份：

- 仅有 7d：主界面、悬浮窗、状态栏/托盘和趣味化节奏提示只显示 7d。
- 仅有 5h：只显示 5h。
- 两者都有：同时显示两条。
- 窗口不可用：保持“待读取/不可用”与真实 0% 分离，不把缺数据伪装成额度耗尽。

### 2.2 额度条布局

Swift 版：

- 账户标签压缩为稳定短标题，完整套餐名与错误信息保留在 Help/AX。
- 额度段改为紧凑两行结构，进度条获得更长的真实宽度。
- 无重置卡时回收对应布局空间，仍保持右侧节奏区对齐。
- 额度刷新菜单移动到顶部节奏提示右侧，显示完整“额度刷新 1 分钟”等名称，带明确菜单箭头和整块点击区域。

Tauri 版：

- 额度名称、进度条和重置时间重新分配空间，960px 产品宽度下按真实盒模型保持单行。
- 刷新频率进入同一顶部节奏区；无保存处理器时不保留空的 132px 控件槽。
- 额度轨道采用连续语义色：低额度偏红，中段经过琥珀与绿色，高额度回到主题蓝。

### 2.3 历史列与异常点

- 历史数据库按真实窗口身份写入，7d 不再错误落入 5h 列。
- 读取旧数据时保留兼容迁移边界，当前窗口缺失不会读取另一窗口冒充。
- 异常过滤依据本机近期 `quota-history.sqlite` 的真实序列设计，不再只凭假设写阈值。
- 对官方偶发跳到接近 100% 的孤立尖峰，两端都会在不破坏真实重置的前提下抑制异常点。
- 曲线选择与额度估算继续按累计下降计算，并保持 5h/7d/仅单窗口三种状态一致。

## 3. 用量曲线与缓存命中率

- 最近 24 小时视图继续保留 30 天、5 分钟粒度的横向历史画布。
- 7d/30d 时间轴与额度历史使用一致的桶边界。
- 缓存命中率不再用上一条实测值填充空桶。低频使用时，空桶现在是未知，连续实测点成线，孤立实测点单独显示，消除误导性的阶梯平台。
- headline 命中率按输入 token 加权，不用少量小请求扭曲整体结果。
- 图表平滑保持形状约束，不跨缺失点连接，也不在尖峰附近过冲。

## 4. 雷达、模型 IQ 与悬浮窗一致性

- Swift 与 Tauri 的 Dashboard、悬浮窗使用同一批 Radar 快照，不再各自独立刷新后比较旧数据。
- Tauri 成功或降级快照通过进程内订阅发布给所有 surface，激活与定时刷新共用 single-flight。
- 模型排序使用同一字段和同一快照时间，避免一端显示 `150 Sol`、另一端仍显示旧的 `130 Terra`。
- 紧凑模型名删除冗余版本前缀，但保留思考强度，例如 `Sol max`、`Sol medium`，不再只显示无法区分的模型名。
- 雷达动作改为中文可读状态；等待、运行、关闭分别使用克制的琥珀、绿色和红色点缀。
- 高 IQ 使用绿色强调，其他百分比指标使用连续语义色；卡片底色保持中性，避免界面变成多色拼盘。

## 5. 主界面与交互整理

### 5.1 Swift

- Header 将来源信息与操作按钮拆成两行，删除冗余产品名，自动发现路径获得固定可读空间。
- Token 活动五种模式由真实原生辅助功能按钮承载，名称、选中值、Help、AX action 与鼠标命中均已验证。
- 额度刷新菜单不再显示省略号，最长“额度刷新 10 分钟”有明确字体与几何预算。
- 可见文字不依赖省略号解决布局；动态长值使用明确短标题，同时在 Help/AX 中保留完整原文。

### 5.2 Tauri

- 顶部主命令固定为：立即刷新、检查/安装更新、开机自启、目录、会话修复、更多操作。
- 删除左侧冗余 `Codex Token Bar` 字样；检查更新与开机自启保持一级可见，不藏入二级菜单。
- 更多菜单只保留 CSV/PNG，并实现完整的 Enter/Space、方向键、Home/End、Escape、Tab、失焦与动作后焦点恢复。
- 活动模式、图表范围和曲线开关补齐 `aria-pressed`；额度窗口继续使用 tab/selected 语义。
- 通知插件仅授予初始化所需的只读授权状态权限，WebView 不取得展示通知、请求权限或更新安装所有权。

## 6. 后台性能与生命周期

Swift 在主界面隐藏、悬浮窗关闭、状态栏关闭时：

- 暂停用量、实时速率、额度和 Radar 的高成本定时刷新。
- 保留可信快照，不在恢复前清零。
- 任一界面恢复后立即启动当前 generation 的新刷新。
- 旧 poll/旧 quota 请求完成后会被 activity/source generation 拒绝，不能推进游标、历史或 UI。
- Task Completion 继续保留，但官方 unread 可用时跳过昂贵 session JSONL 扫描；只有仍被本地已读基线抑制的官方 unread thread 才做条件增量扫描。

真实 all-off 采样从高活动背景下约 41.54% CPU 降到约 0.09% 平均值；恢复主界面或悬浮窗后，live/usage/quota/Radar owner 会重新出现。该数字来自特定机器和工作负载，只用于说明优化方向，不作为所有设备的固定承诺。

## 7. 来源、缓存与异步正确性

- Swift 与 Tauri 都使用物理来源身份、绑定代次和 generation 拒绝旧来源迟到结果。
- 同一 Codex Home 路径被替换或重新绑定时，会推进 binding/identity，而不是继续接受旧 reader。
- Swift 旧 v5 用量迁移死代码和无效 constructor 参数已删除；当前版本、namespace、digest-only 持久化和旧缓存删除路径保持明确。
- Tauri token-event shard、dashboard aggregate 与 compact summary 的作用域按 Codex Home 隔离。
- 本次最终集成额外修复 Rust 测试的共享环境变量、全局计数器和后台 refresh 跨测试污染；生产调度行为未改变。

## 8. Provider Repair 数据安全

- create-backup、sync、rollback 通过同一 canonical-home operation registry 串行化。
- 运行中的 Codex、错误 home、manifest 不匹配、成员越界、损坏备份和 TOCTOU 变化均失败关闭。
- SQLite WAL 使用真实 Backup API 生成一致快照；恢复后执行完整性检查并清理 sidecar。
- session JSONL 复制记录打开 descriptor 的物理身份与 digest，复制后复读同 descriptor，并重新打开 live path 比对身份与 digest。
- 并发 append、原子 path replacement、同 inode 同长度覆写并恢复 mtime 均有执行测试。
- Windows 测试使用生产 `ReplaceFileW` helper，fixture I/O 错误与 production replace 错误分阶段报告，避免假绿与 Barrier 永久等待。

## 9. Windows 桌面行为

- `--autostart` 不创建或显示 Dashboard；仅按设置创建必要的 floating/tray surface。
- manual primary 正常创建 Dashboard；manual secondary 通过当前用户会话的 named auto-reset event 唤醒现有实例。
- autostart secondary 静默退出，不抢焦点。
- activation listener 由唯一常驻 supervisor 持有，Wait 失败后 100ms 到 2s 有界退避并继续等待。
- destroyed main 先创建隐藏 WebView，等待 PageLoad finished 后再显示与聚焦，避免灰白空窗。
- CreateEvent/CreateMutex/SetEvent 的关键失败不会回退成第二个 primary，而是可见地失败关闭。

上述单实例、自启动、destroyed-main 与重复唤醒行为已在 Windows x64 安装态通过。最终源码重新生成的 x64/ARM64 安装器也已通过版本、PE machine、manifest 与签名门禁；最终 x64 release exe 另在真实交互用户会话完成主窗口和 manual secondary 单实例 smoke，且没有替换用户现有安装。

## 10. 更新系统

macOS：

- Sparkle owner 在 App 生命周期常驻。
- 默认 4 小时检查一次，用户可关闭自动检查，也可随时手动检查。
- 自动检查只提示，不自动下载或安装。

Windows：

- Rust `UpdateMonitorRegistry` 在应用启动时存在，即使 headless autostart 且未打开 Dashboard 也能检查。
- automatic/manual 共用 single-flight；attempt 在联网前持久化。
- available state、通知去重、tray presentation 和安装 lease 独立管理。
- 系统通知不可用时，持久 tray badge、菜单项和 tooltip 作为 fallback，并在重启后恢复。
- 安装前重新检查版本并验证 updater 签名，只有用户确认后才下载与安装。

## 11. 发布与供应链加固

- macOS DMG 检查同时支持旧 Finder `backgroundImageAlias` 与新版 `pBB0/pBBk` 书签，并在 RW 重挂载和最终压缩 DMG 上验证。
- Windows PowerShell 5 语法、mock 参数形态、x64/ARM64 构建和安装后 PE machine 均有平台门禁。
- NSIS 外层按 opaque bytes 处理，不再用通用 80386 stub 推断 payload 架构。
- Tauri updater 签名明确区分密码 unset/empty/nonempty；非空 secret 不进入 argv 或日志。
- 签名 envelope 严格接受当前 prehashed `ED` 链，并拒绝 `Ed`、未知 magic 和错误长度。
- 最终双架构 `.sig` 已用内嵌公钥和真实 `minisign-verify 0.2.5` 执行流式验证，x64 与 ARM64 均通过。

## 12. 本地验证结果

当前整合源码的 fresh 结果：

| 门禁 | 结果 |
|---|---:|
| Swift 全套 | 579 passed / 0 failed |
| Rust `cargo test --locked --lib` | 501 passed / 0 failed |
| Node `node --test` | 387 passed / 0 failed |
| Swift build | passed |
| Rust `cargo check --locked --lib` | passed，只有既有 dead-code warnings |
| Tauri `npm run build` | passed，152 modules |
| `git diff --check` | passed |

当前 stable Rust 工具链未安装 `rustfmt` 组件，因此 `cargo fmt -- --check` 无法执行；未为本次发布擅自修改全局工具链。Rust 改动已通过编译和完整测试。

## 13. 隐私、安全与兼容边界

- prompt、response 和本地会话原文不写入用量持久缓存；只保留摘要所需字段与 digest。
- Codex 本地用量、额度、重置卡和会话内容不作为遥测上传。
- Radar 使用公开订阅；完整私有账号接口仍只在本机调用。
- macOS 当前为 ad-hoc 签名且未 Apple notarize。
- Windows 安装器没有商业 Authenticode 证书，SmartScreen 可能显示未知发布者。
- Windows updater `.sig` 只用于应用更新真实性校验，不等价于 Authenticode。

## 14. 发布结果

- 用户在最终 DMG 已打开、双端额度窗口自适应行为重新核实后明确授权发布。
- `release/v0.7.3` 与 annotated tag `v0.7.3` 已推送；tag 解引用到 `820a7e72cf4a5801331d07dcab43a7ab0cff917a`。
- GitHub Release 已发布为 latest，九项资产先在 draft 阶段回下载逐字节核对，公开后又从稳定 `v0.7.3` URL 回下载复验。
- 公开 `SHA256SUMS-v0.7.3.txt` 通过 8/8；公开 Windows metadata 的双平台签名与 detached `.sig` 一致。
- 远端 `main` 已在 Release 资产存在后快进，公开 Sparkle appcast 与本地最终 appcast 字节一致。

精确资产字节数、SHA256、公开时间和远端验证记录见 `release-ledger/v0.7.3.md`。

## 15. 回滚与追溯

- 当前公开稳定点：tag `v0.7.3`；上一稳定点为 `v0.7.2`。
- 当前工作分支：`release/v0.7.3`。
- 源码回滚可按功能提交逐项 revert；发布资产不会进入 Git。
- 旧 v0.7.3 本地资产属于更早源码候选，不能复用于当前候选。
- GitHub Release、tag、appcast 与 Windows metadata 已按同一 reviewed candidate 发布并完成公开回读验证。

---

## English Executive Summary

Codex Token Bar v0.7.3 is a broad reliability, data-correctness, performance, accessibility, and release-hardening update across the native macOS Swift app and the Windows Tauri app.

The release adapts to the quota windows that Codex actually returns, including seven-day-only accounts; fixes quota-history mapping and isolated near-100% spikes; removes low-activity cache-hit stair steps; keeps Radar and model-IQ ranking on one shared snapshot; preserves model reasoning effort in compact surfaces; improves header, quota-strip, menu, and accessibility behavior; suspends expensive Swift owners while all surfaces are hidden; hardens source generations and cache ownership; closes Provider Repair copy and recovery races; adds reliable hidden Windows autostart and single-instance activation; and moves update checking to persistent app-level owners with user-confirmed installation.

The integrated source passes 579 Swift tests, 501 Rust tests, and 387 Node tests, plus Swift, Rust, and Tauri builds. Final macOS and Windows assets were rebuilt from commit `0c4977461db54d99e0a94ee6203d5053dd4c40c3`, published under tag `v0.7.3`, downloaded again from the public Release, and verified byte-for-byte together with both updater channels.
