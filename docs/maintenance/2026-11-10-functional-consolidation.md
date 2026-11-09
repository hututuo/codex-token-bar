# 功能区统一入口收束

基线：`109350b6310d6d544f89719396f434b89dd55c32`，工作树 `f97f`，分支 `codex/storage-responsibility-split-20261106`。

状态：实施中。源码检查不等于云端测试或实机验收。本机不运行构建/测试套件；最终同 SHA 完成 Hosted checks、Public097 和双端候选包校验后停在安装前，由 Argon 安排用户实机测试。既有脏文件、scratch、A–D 存储合同保留。

## L1：实时速率

定位：三级缺少圆圈对应的模型速度条；圆圈/设置预览各自选择速率与配色，Swift morph 仍直接使用模型色。旧速率 API 依赖调用者事先排除来源重叠；当前配置已明确排除 upstream 的 Claude，未发现重复计数实证。新入口按客户端选择 reader，保留该隔离。

合同：每个客户端只选择一个速率 reader；先按来源核对总值和未知残差，再生成 client+model 行。实时 total、modelRates、colorRates、行 share 与相对最大值条长来自同一快照。行保留客户端、原始模型、采样时间和来源标识；不同客户端同名模型保留独立行。颜色/短名复用现有注册表，数字统一一位小数。停用/不可用归零，状态不伪装为正常空闲。

| 入口 | 权威投影 | 消费者 |
| --- | --- | --- |
| Codex Bar / 本地 Claude / upstream 本地观察 | Swift `ClientLocalRuntimePresentation.liveRate` → `ModelRatePresentation.snapshot`；TS 对应纯投影及 reader adapter | 二级圆圈、一级竖条、morph、设置预览、三级实时模型条 |
| 正文完成样本 | 既有 Body TPS 投影 | 正文 TPS 历史，不加入实时 total |
| 近三分钟观察序列 | 既有活动历史 | 活动折线图，不以窗口均值替代实时条 |

检查：新增双端 `Tests/SharedFixtures/live-model-rates.json`、生产圆圈/模型条组件回归、非法值/停用/切源/来源身份/配色检查。`93d46fea` 云端前端通过，Swift 新行视图类型推导超时；`fe38279c` 拆成明确的名称/轨道/行组件。修订的 Public097 `42680101699` 已成功，完整 CI `42680102143` 尚在执行。GUI NOT_RUN。

## L2：趋势桶与多客户端用量摘要

定位：`RecentUsageChartData.prepare` 与 TS `prepareRecentChartData` 因细序列覆盖情况将 7d 改为 300 秒；B 库趋势查询按 client/time 合并，没有模型维度；框选摘要读 Codex quota 的事件及 totals，模型只显示前三项，可能隐藏整个其他客户端。

| 入口 | 权威计算 | 消费者 |
| --- | --- | --- |
| B 已有事件与逐请求价格 | Swift `trendBuckets` / Rust `read_trend_buckets` 按 client+raw model+5m；同一只读事务，附缓存字段完整性 | 主页原图投影、图表外部贡献 |
| 原图显示范围 | Swift Range / TS RANGE_CONFIG：24h 300s、7d 3600s、30d 21600s | 单来源和汇总共用原图坐标、缩放、滚动 |
| Codex 原始模型桶 + 所选 B 趋势贡献 | Swift `RecentChartPreparedSnapshot.usageBuckets/usageSummary`；TS `buildChartUsageSnapshot/chartUsageSummary` | 曲线价格、顶部、单点 hover、固定框选、下方选区用量及所有模型 |
| Codex quota provider | 独立细序列证据；显示选区按时间映射，返回显示索引 | 额度下降、跨 reset、分钟证据、shared-account 归因；外部用量不参与 |

模型贡献保留 client 与 raw IDs，展示 alias 仅在同一 client 内合并；原生/Antigravity 同名模型不吞并。所有选区模型在有界滚动列表中可见，不再截为前三项。按原始请求计价后再合桶，未知费用与缓存完整性单独保留；不修改 B 表结构、原始记录、A 库、迁移状态机或存储连接/事务拥有者。

共享 `recent-chart-usage.json` 验证三种粒度、六种 scope、同名跨渠道、反向/单点选区、费用守恒和未知缓存。新增真实 React 图表 hover/固定选区/下方摘要回归及 Swift/Rust 同桶多模型、价格、旧 IPC 缺省回归。原 7d 细桶测试改为断言 1h 显示与 5m quota 证据同时保留，未删除低点保护。新增代码尚待云端编译和测试，不以本机 JSON/脚本语法检查替代。

## 后续 Loop

- L2：固定 24h/7d/30d 为 5m/1h/6h；曲线、顶部、hover、选区共同消费带客户端/模型/已核算价格的桶，Codex quota 证据独立。
- L3：展示身份、计价身份、渠道身份；检查所有费用与名称/颜色消费点。
- L4：运行主/子任务聚合、source quality、标题与存活适配。
- L5：scope、IPC、异步回复、刷新和设置生命周期。
- L6：诊断事件裁剪、当前启动证据和升级回执。
- L7：剩余服务 owner 矩阵；只收束有实际重复决策证据的模块。
