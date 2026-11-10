# 按客户端排列模型费用，每行四项

2026-11-10。基线 `c295a3e59dbcbeea26be3d908634c12b60308e76`；本批是在前一批离线额度改动之上继续修改工作树。用户已批准“按客户端、每组四个、有用量自动补位、其他也按客户端分组”的方案。下文的 NOT_RUN 记录首次离线源码阶段；用户随后要求“替换”，最新云端门禁及安装证据见 [build 1010 安装记录](2026-11-10-build1010-installation.md)。

## 定位与扫描

旧 `model-cost-order.json` 按全局“最新主力 / Gemini · Antigravity / GPT 其他 / Claude 其他”分组，来源覆盖规则会把 Antigravity 历史模型推到前排；没有按客户端的四项上限。Swift `DashboardModelCostOrder` 和 TS `modelCostOrder` 的消费者是三周期/单日主页费用、原有 Codex 周期费用与三级费用列表。上游费用已经保留 `client|canonicalModel` 和逐请求已计算金额。

Swift `DashboardModelCostGrid` 和 React `StatsStrip` 旧网格用 204pt/px 自适应列数，窄窗口可能落成三列；短周期还填充零用量占位卡。两端现在明确四列，不再用占位卡凑真实模型数量。

## 最终规则

共同规则保存在 `Sources/CodexTokenBar/Resources/model-cost-order.json` schema 2，两端生产投影直接读取。

| 客户端 | 首选第 1 项 | 第 2 项 | 第 3 项 | 第 4 项 |
| --- | --- | --- | --- | --- |
| Codex | Astra6 | Sol6.1 | Terra6.1 | Luna6 |
| Claude Desktop | Fable5.2 | Opus5.5 | Sonnet5.5 | Haiku5.5 |
| Claude CLI | Fable5.2 | Opus5.5 | Sonnet5.5 | Haiku5.5 |
| Antigravity | Argon4 | Flash3.8 | Opus5.5 | Sonnet5.5 |

表中是优先顺序，不是无用量时也要展示的假卡。其他客户端保留自身标题，有真实记录才起行。

- 当前所选周期 `tokens > 0` 才进入排序；今日、近 7 天/本期、累计和单日各用自己的输入。主力缺席时只从同客户端、同周期的合格模型补位。
- 有用量的首选模型先占位；补位模型按该周期 Token 量排序，同量时较新代际优先，再按稳定原始 key 排序。不额外扫描账本取得另一套“最近使用”数据。
- GPT 5.6 及之后（含 Sol6）可补位；GPT 5.5 及之前、o 系列等下沉。Claude 主力候选限定 5.x 及之后，4.x（含 4.7/4.8）下沉。Gemini 3.7 及之后可补位，旧 Flash3 等下沉。来源不改变代际判断。
- 每客户端前排最多四项，第五项及旧模型进入该客户端的“其他”。不把不同客户端的同名模型合并。
- 页面只显示一个“其他”区标题，其内部继续按客户端分组。每组默认最多四项，超过四项用“另 N 项”展开/收起，避免第五项默认独占新行。
- 客户端名位于组标题，不追加在每张卡名称后；原始模型和来源仍在 tooltip/无障碍描述中。未知模型沿用原来的跨来源参考卡，不能凭空拆归属。
- 折叠只影响可见行数：所有费用、Token、占比与三级详情仍来自完整数组，未显示的项目继续计入合计。
- 保持 30pt/px 卡片高度和配色编辑。四列较窄时收紧次要数值展示，完整指标留在 tooltip/AX，优先保证模型名与金额可辨。

Swift 的主生产入口为 `DashboardModelCostOrder.groups`；TS 为 `orderedCostGroups`。主页负责展开状态，投影不丢溢出项；三级详情复用完整投影的扁平列表，不另写排序。

## Fable 5.2 目录与价格

依据本线程此前已经核验并保存的官方资料，新增 `claude-fable-5-2`、短名 `Fable5.2`、Bedrock alias `anthropic.claude-fable-5-2`，发布日 2026-11-09；显式 `-fast` 使用独立 fast 价格。此次未再次联网。

| USD / 百万 Token | 输入 | 缓存读取 | 5m 缓存写入 | 1h 缓存写入 | 输出 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 标准 | 8 | 0.20 | 10 | 16 | 40 |
| Fast | 16 | 0.40 | 20 | 32 | 80 |

来源：[官方价格表](https://platform.claude.com/docs/en/about-claude/pricing)、[Fable 5.2 概览](https://platform.claude.com/docs/en/models/fable-5-2/overview)、[Fast mode](https://platform.claude.com/docs/en/build-with-claude/fast-mode)。Fast 缓存费按官方的缓存倍率叠加规则计算，不能由 high/max effort 推定 fast 模式。

共享 PriceBook JSON 从 v4/199 项变为 v5/200 项，Swift 内嵌资产逐字同步；Rust/C# 继续使用同一 JSON。`UPSTREAM.json` 只更新已审查本地价格补丁的 hash/reason，原 SDK pin 和上游原始 hash 保持不变。已比较全部原 199 项：价格、tiers、periods、aliases 均未改动，Fable5.1 保留 $10/$50 原价。

`standard-api-price-history.json` 是 Codex/OpenAI 额度反推的专属表，不向它加入无法被 Claude 计价消费的孤立条目。Claude Fable 的标准、Fast 与写缓存 TTL 由 PriceBook 和既有多客户端逐请求计价入口处理。

## 首次源码阶段检查结果与边界

- PASS：直接用 Node 内置 TypeScript 支持加载实际 `orderedCostGroups` 及其生产依赖，跑共享全集与 7 个专项场景，三种输入排列共 24 次；验证主力优先、同周期补位、旧模型下沉、第五项保留、来源隔离、空周期与 Token/金额守恒。
- PASS：Fable5.2 的 canonical/name/Bedrock alias 三种短名映射与最新 Fable 目录选择。
- PASS：离线价格参考工具验证标准、Bedrock alias、Fast 和 Fable5.1 的混合缓存请求，分别为 $12.24、$12.24、$24.48、$15.30；覆盖 5m/1h 写缓存。
- PASS：价格表 v5 schema、103 个解析例、价格/货币 fixtures；Swift 内嵌 JSON 与共享 JSON 完全一致；vendor 全部 hash/provenance 检查。
- PASS：修改 Swift 文件和测试的语法解析、Rust 计价测试所在文件语法解析、JS 测试语法检查、`git diff --check`。
- NOT_RUN：完整 Swift/Rust 类型检查、原生编译与测试；React/TSX 类型检查、组件 DOM 测试、云端三大门禁、打包和 GUI。没有本地前端依赖，因此不下载依赖或绕过云端构建约定。新增共享回归与“另 1 项”展开交互测试已落盘，等待云端执行。
- 保护文件 hash 与接手基线一致；前一批离线额度补丁和原有 dirty/untracked 材料保留。首次离线检查时未替换安装应用；后续安装结果见上方链接。

完整 GUI 验收仍应比较四列布局的常用/最窄窗口、各客户端实际模型、今日/7d/累计切换、Other 展开前后合计一致，以及 Fable 首次真实用量出现后的自动补位。用户的“替换”授权涵盖本次安装与重新启动；完整交互式 GUI 测试继续遵守用户在场规则。
