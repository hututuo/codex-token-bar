# 顶部客户端提示、模型短名与价格表核查

状态：最终源码 `9671d6c9b71705367d91eef109d722c5bbdb6f02` 完整云端 CI 与双平台打包全部通过并完成原始日志复核；2026-11-08 16:25:30 已安装并启动本机 0.9.11/build 995，旧 build 994 完整备份。起点为 build 994 的产品 `ee1746bf` / 文档 `9e5fd5b1`。本轮不修改存储拆分、数据库、扫描、回填、账本模型身份或历史价格表。

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

第一轮 `7967db22` 的前端全量检查拦下了一个依赖边界错误：共享命名元数据放在 `components/`，使 Radar domain 反向依赖组件层。修正为无 UI/API 依赖的 `domain/modelDisplayNames.ts`，未放宽架构门禁。众测排名原先先删版本再生成标签，现优先按原始 ID 查共享名称；没有改排名、分数或身份。其余失败为仍断言旧文字的展示用例，逐项更新为短名，保留金额/事件/操作断言。新增的全目录、未知型号与金额/ID 不变三项前端用例第一轮已实际通过。旧候选打包已取消，不用于安装。

第一轮 Swift 完整测试进一步发现两处真实的旧职责纠缠：`ModelAwareAPIPriceEstimator.historicalQuote` 与 `AutoReviewReferencePricing` 把 `OfficialAPIPriceModel.title` 作为历史价查询输入。此次标题缩短使查询失配，原有历史费用/回顾参考价/区间归因测试正确阻断候选。修正为显式 `canonicalModelID`，从原 current-price 映射提取同一组固定 ID，供现价和历史价共同使用；`title` 只负责短名。新增遍历全部 13 个 Codex 价模的实际 dated estimator 断言，预期金额为固定独立数值，且回退/未计价必须为零。没有将短名加进价格别名，也没有放宽价格未知保护。`d0173e05` 的排队验证和打包同时取消，最终必须在此修正后的新 SHA 验证。

## 最终源码云端验收

`ef2811c5` 已确认费用/归因回归全部恢复；最终 `9671d6c9` 仅再校正四份测试中残留的旧显示文字，没有继续改产品代码。以下均为最终 SHA 的新证据，不沿用失败轮次的通过数。

[完整 CI 42460573367](https://github.com/hututuo/codex-token-bar/actions/runs/42460573367) 为 success。下载全部原始测试输出、源码封印、生产报告与负控，再运行本地只读证据解析 `validate_cloud.py --native-only` 为 PASS（不运行产品/测试、不编译）。

| 项目 | 结果 |
| --- | --- |
| Swift XCTest | 2,390 通过 / 38 原有跳过 / 0 失败 |
| AgentSpeed Swift Testing | 674 tests / 79 suites 通过 |
| macOS Rust | 1,811 通过 / 14 ignored / 0 失败 |
| Windows Rust | 1,755 通过 / 14 ignored / 0 失败 |
| 前端 | 1,441 通过 / 0 跳过 / 0 失败 |
| Cloud scripts / release scripts | 18 通过；111 通过 / 1 原有跳过 |
| 生产场景 | 两端各 16 个；报告与实际日志一致 |
| 备份负控 | 两端 0 / 101 / 0；关闭保护确实失败，恢复后通过 |
| 物理 A 替换负控 | 两端 0 / 1 / 0；六个生产入口拒绝错误实体，源码 hash 恢复 |
| 新增专项 | 全目录/别名与唯一短名、未知与档位保护、五个价目与日期边界、13 个 Codex 价模实际历史估算全部通过 |
| 原生布局 | 六张 360/872/1404pt × 1/3 行渲染；复看窄/宽三项图无截断 |

源码前后封印、运行 SHA、必跑用例和 storage 基线用例结果均已核对。此 UI/价表批次未重跑四版本历史 producer 矩阵、Public097 或性能矩阵；存储源码和 Codex 历史价表未改动，既有完整库和生产负控照常执行。

[打包 42460575637](https://github.com/hututuo/codex-token-bar/actions/runs/42460575637) 的 macOS job 已成功。App ZIP SHA-256 `f8c5696164488ce23f98bca37d18e37658a498a3377a2e8d64586afa6e7feb8e`；arm64 executable SHA-256 `5c9b98a202edb994fe520ccf1547c7fdf25a629aaca33878d185d033dcb54a5d`。版本 0.9.11/build 995，严格签名、稳定指定要求、bundle ID、Sparkle feed/key 与已安装版本一致；ad-hoc，未 Apple 公证。新增短名字典在打包 App 中与源码逐字节一致，云端已执行真实 App 的资源预检。DMG 完整性检查通过。未创建新的系统权限、运行时或服务依赖；现有中英文 README 的安装/更新说明仍适用。

Windows x64/ARM64 安装包随后全部成功；完整 workflow success，全部产物已下载，通过 GitHub artifact digest、candidate manifest 的 SHA/运行 ID/架构/文件集校验及 ZIP CRC 检查。`scratch/model-labels-discovery-20261108/cloud-9671d6c9/final-validation.json` 为 PASS，SHA-256 `1fb93a94e64a489f892cc5569f84f26883a1a684ad897b804d87dc47393a1eaf`。

## 本机替换与窗口验收

2026-11-08 16:25:30（Asia/Shanghai）正常退出 build 994，确认旧进程消失后复制并校验候选、保留旧 bundle，再安装 `/Applications/Codex Token Bar.app`。新旧完整文件/符号链接/权限清单都核对通过；安装后签名及 executable SHA 与云端相同。唯一回滚副本位于本工作树 `scratch/model-labels-discovery-20261108/local-install-995-23nuox8t/rollback-build994/Codex Token Bar.app`，未覆盖更早备份。

PID 87373 从正式路径启动，2 分 23 秒后仍为同一进程；主窗口正常可见（1512×897）。真实首页截图 `dashboard-build995.png` 中 `Argon4`、`Sol6.1`、`Astra6`、`Opus5.5`、`Flash3.8` 等短名和金额均正常显示；读取中/刷新中已消失。首轮实际增量刷新为 16:25:35.631 → 16:25:52.755，共 17.124 秒，发现 4,316 个文件、增量解析 1 个、不变 4,315 个。不是冷回填性能测试。

当前本机偏好中 DeepSeek 与 Antigravity 已启用并已确认，因此发现提示不再出现。安装过程中没有点击启用/忽略或修改偏好；不为截图重置用户选择。顶部位置由真实 Header 代码与最终前端 DOM 测试验证，原生六张渲染证明宽度与多项完整展示；本次实机因没有待确认项，没有把“看到顶部待启用卡片”写成已完成的视觉证明。相同短名的不同原始别名仍保留原账本行/颜色，未顺带合并统计身份。

安装、回滚、进程、截图和日志证据集中在 `scratch/model-labels-discovery-20261108/local-install-995-23nuox8t/`。既有刷新诊断开关仅对本次进程生效。未发现本次新增的 App 崩溃报告。本轮未做本机编译/测试，也未发布 main、tag、Release 或 appcast。
