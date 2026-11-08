# 顶部客户端提示、模型短名与价格表核查

状态：源码已完成，云端验证与候选安装待执行。起点为 build 994 的产品 `ee1746bf` / 文档 `9e5fd5b1`。本轮不修改存储拆分、数据库、扫描、回填、账本模型身份或历史价格表。

## 界面调整

- macOS 和前端都把发现 DeepSeek / DSH、Antigravity 等提示放在顶部客户端切换（包括「汇总」）下面、Codex 工具和额度区域之前。提示使用完整页头宽度，不挤入左侧窄列；删除页面中部的重复入口。原有全量展示、独立启用/忽略、980pt 上限和窄屏换行保持。导出页头不挂载交互式发现提示。
- 共享 `model-display-names.json` 为价表全部 199 个模型提供 199 个不同的短名。例如 `Argon4`、`Sol6.1`、`Sol6`、`Sol5.6`、`Opus5.5`、`DS4.1 Flash`。保留版本、Pro/Mini、Fast、不同日期/托管来源等必要差异。
- 费用卡片、速率/趋势、请求详情、任务详情、模型指纹选择和价模设置复用显示规则。原始 ID 继续作为选择值、分组键、账本键和价格输入；主要详情的悬停保留原 ID。未知模型保留原名，裸 `gpt-5.6` 仍不冒认为 Sol。模型指纹的选择项显式设置原始 `value`，防止短名被送进请求。
- 独立的参考价文字保留至少两位、最多六位小数；MiMo 的 `$0.435` 不再被显示为 `$0.43` 或 `$0.44`。费用计算没有改变。

## 价格核查范围与结论

采用 Agent Speed 上游 `f32bc2945bce5dcfc94d6befb28dcb2e0abc9532` 的完整 version 4 价表及对应 Swift 嵌入资产，SDK 代码仍固定在原 `a94a67fc`。在 `UPSTREAM.json` 记录两份资产的确切 hash 和差异原因。

| 核查项 | 结果 |
| --- | --- |
| 原有 / 当前模型 | 194 → 199；供应商 12 → 13 |
| 新增 | Kimi K3.1 Pro、K3.1 Pro HighSpeed；MiMo 2.6 Pro、Flash、Pro UltraSpeed |
| 补充旧项别名 | Kimi 的 `k3`、`k3-256k`、`kimi-for-coding-highspeed` |
| 原有 194 项 | 按 ID 对比价格、缓存价、tiers、periods、offPeak、fast、free、status，全部相同 |
| 历史 Codex 价表 | `standard-api-price-history.json` 未改动 |
| 两端资产 | JSON 与上游字节相同；Swift 内嵌 JSON 与该文件一致 |

本次读取了 [OpenAI 官方价表](https://developers.openai.com/api/docs/pricing)、[Google 官方价表](https://ai.google.dev/gemini-api/docs/pricing)、[Kimi K3.1 官方价表](https://www.kimi.ai/zh-hans/resources/kimi-k3-1-pro-pricing) 以及 DeepSeek 官方文档。核实通用 GPT 当前标准价、Argon 在 2026-12-01 的已公告变价、Kimi 两款的标准/高速/缓存价。MiMo 官方页面直取仅返回前端壳，本次补项依据上述固定上游已记录的美元价格、来源与核查日期，不能写成已独立读到其官方价目正文。

不能宣称覆盖全球所有模型/计费方式：官方页另列 `gpt-6-cyber`、`gpt-5.5-cyber`、`gpt-6-rosalind`、`gpt-rosalind-research`、`gpt-rosalind-discovery`、`gpt-6-astra-law` 等专用/受限模型，当前上游目录尚未包含。Ultrafast、Batch、地区加价、音视频、工具调用及部分缓存 TTL 也超出此通用文本参考表的表达/日志证据边界。本轮没有伪造这些档位的普通价，也没有扩展计费引擎。路由器 `auto`、Kimi 通用 `kimi-for-coding` 等无法证明型号的值继续未计价。

静态核查材料位于 `scratch/model-labels-discovery-20261108/`。完整云端结果、构建 SHA、安装包及本机实测将在完成后补录。

## 验证计划

使用项目完整 CI：Swift 与 AgentSpeed 测试、双平台 Rust、前端全量、两端生产场景和负控。新增检查覆盖全部价表型号/别名、短名唯一性、未知与未来型号、Fast/版本区分、原始 ID/金额不变、五个新价目及 Argon 变价日。页头 DOM 校验发现栏紧随客户端区、位于 Codex 额度之前；既有原生窄/宽发现栏渲染继续执行。

构建和测试全部走 GitHub Actions；通过后使用云端候选替换本机 App，保留独立 build 994 回滚副本。本轮不发布 main、tag、Release 或 appcast。
