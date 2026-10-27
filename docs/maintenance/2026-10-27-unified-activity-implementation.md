# 多客户端统一活动速度：实施进度

2026-10-27；独立 `codex/multi-client-tokens` worktree。本文是本批次状态，不是完整方案交付或安装验收。

## 已接入源码

- 全局速度显示选择：Bar 默认 / Agent Speed，双端持久化。Codex 每次只选一个计算来源，避免双算；Claude 本地活动速度加入同一模型色段。切换显示不启动排行榜上报。
- Mac 显示与上报的非 Claude Agent Speed monitor 通过进程内池复用。Claude 继续独立的本地约束路径，不读凭据、不请求 Anthropic、不启动 Claude、不自动改配置、不进入上报。
- Windows 本地长期 helper 支持所选 CodexHome 的 Agent Speed 显示模式，以及现有 Claude 源。仅用本地白名单快照通信；新增单独的速度模式读写命令，三级菜单无需获得全局设置写权限。
- 活动速度数值写入现有 B `multi-client-usage.sqlite` 的模块表；Swift/Rust 共用 SQL v2。来源根以摘要隔离，模式、算法版本、指标、客户端和模型分别保留；7 天明细、30 天聚合/重放标识，5 分钟桶、5/15/30 分钟时间加权查询。
- 速度写入采用有限队列、批事务，不保存正文或凭据；历史查询先按来源/模式过滤，再读近期有限点。未知模型保留；缺少分段的旧格式快照保留总速度为未知段。
- Claude 独立 API/正文 TPS 页面与持续采样停用，statusline 仅保留额度与上下文。旧 `claude-local-speed.sqlite` 只读迁入 B legacy 表，保留方法和原始 payload，不混入新均速；迁移前一致备份、事务对账、重复导入幂等，失败也保留已完成备份。
- Auto Review 按用户追加决定单列：Token 继续计入总量，主页面本期/今日/累计及其他费用列表展示独立参考价，不计入总费用、累计节省、额度价值或反推归因。原始别名与历史价格分期不改写；紧凑的 Token 占比仍可按对应 Luna/5.4 合色，但不得把免费检查变为付费模型。

## Auto Review 核对边界

- 本机 2026-10-27 模型目录和本地线程模型字段仍暴露 `codex-auto-review`，不能从别名推断服务端部署版本。
- 官方帮助中心搜索索引保留“Auto review uses GPT-5.6 Luna”，但当日打开的最新正文已不再给底层型号；未找到升级到 6 Luna 的官方证据。因此沿用最后已知的 5.6 Luna 路由，不凭猜测追加新历史生效日。
- [官方模型目录](https://github.com/openai/codex/blob/main/codex-rs/models-manager/models.json)
- [官方费用说明](https://help.openai.com/en/articles/11481834-chatgpt-rate-card-business-enterpriseedu-credit-based-pricing)：ChatGPT 登录的 Auto Review 安全检查免费、不计入套餐限额。Token Bar 的 API 等价费用不能当作这笔实际扣费证明。

## 容量测量

本地临时 SQLite 使用生产 SQL 的合成数值 fixture，20,000 个一秒活动区间（两个模型轮换），主文件 19,800,064 字节，约 990 字节/区间。批量插入约 0.13 秒。线性估算单一同时活跃维度每天 8 小时、明细 7 天约 190 MiB；全天活跃约 571 MiB。并发维度会增加容量；不含原用量账本、WAL 和额外 30 天聚合，不是用户实测或容量上限承诺。原始测量见 scratch/activity-speed-capacity.json。

## 明确未完成

1. A 旧 Codex 分库归并：exact 按 CodexHome 的隔离、staging/candidate 恢复和 safety 整库替换必须先改成安全的来源/模块隔离，尚未切换任何旧 writer。当前不能声称只剩两个业务库。
2. 唯一物理日志读取 owner：Mac 只收敛了上游显示/上报 monitor；历史账本与 Bar 读取仍可能重读，Windows 报告 helper 与本地显示 helper 也尚未完成共用 IO。
3. 上游切模尾部按事件模型精确分配、更多客户端实时显示和对应跨端 fixture，仍待补齐；当前总量守恒不等于事件归属问题已全部解决。
4. 真 Windows 目标构建和 C# helper 自测未运行（当前环境无 dotnet，交叉目标缺少 C 头文件）；不等于 Windows EXE 已完成。
5. 未安装、未启动候选版进行本轮视觉/长期功耗验收，未重启或替换正式 Mac/Windows 应用，未迁移真实用户数据库。

## 验证

测试日志在本 worktree scratch/unified-activity-*；本批最后一次结果见后续追加，不能以源码编译通过代替运行安装验收。

### 本批验证回执

- Swift 全量：2021 项 XCTest（20 项条件跳过）、8 项本地 capture XCTest、647 项上游 Swift Testing，0 失败；最后查询/来源隔离改动后追加定向 32 项通过。
- UI 全量：1283/1283；TypeScript/Vite 构建通过。
- Rust 全量串行：1429 通过、1 失败、11 ignored；失败是旧的 V22 启动缓存匹配测试，隔离复跑 1/1 通过。之前并行运行也出现过另一项缓存目录计数失败，串行时通过；仍保留全量失败回执，不宣称一次全绿。活动数据库 8/8、本地 runtime 14/14 通过。
- 上游同步脚本单测 7/7。
- Windows .NET 编译/真机运行 NOT_RUN；正式应用安装与真实数据迁移 NOT_RUN。
- Auto Review 修复单独提交 `9c832fe5`；本页其余内容是活动速度接入第一批，不代表第 9 节完整验收结束。

### Auto Review 免费参考价口径追加

用户明确要求覆盖上一轮主页面合并决定。共享定价 helper 对 raw alias 和旧 synthetic display key 均排除实际金额投影；单列参考价复用已有日期价格卡，不能用当前 Luna 价覆盖旧 5.4 分期。Swift/TS 共用调用入口覆盖本期 API 值、累计节省、选区额度反推、共享账户归因与热力图金额。模型明细不完整时保留已识别的免费项以从回退金额中扣除；完全缺失模型身份的旧汇总仍属于原有回退估计，不能凭空判断其内部模型。既有用量索引和原始事实不改、不删。Rust Codex 侧没有另一条独立金额计算；Tauri 的这些投影在共享 TS 层同步修复。

`9c832fe5` 的主页面合并显示已被本次追加要求覆盖。新规则回归包括免费项与付费 Luna 混合、旧分期参考价、部分模型覆盖、总 Token 保留、模型卡单列与金额合计隔离。

追加口径最终验证：Swift 全量 XCTest 2025 项（20 项条件跳过）+ capture 8 项 + 上游 Swift Testing 647 项，0 失败；最后旧分期 parent 兼容补丁追加费用/归因定向 196/196 通过。前端全量 1288/1288，TypeScript/Vite 构建通过。只读复核未发现已识别 Auto Review 绕过费用排除的路径。未安装、未重启正式应用，未修改实际账本数据。
