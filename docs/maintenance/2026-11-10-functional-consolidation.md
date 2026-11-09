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

检查：待新增双端共享 fixture 与生产消费接线回归；云端 NOT_RUN；GUI NOT_RUN。

## 后续 Loop

- L2：固定 24h/7d/30d 为 5m/1h/6h；曲线、顶部、hover、选区共同消费带客户端/模型/已核算价格的桶，Codex quota 证据独立。
- L3：展示身份、计价身份、渠道身份；检查所有费用与名称/颜色消费点。
- L4：运行主/子任务聚合、source quality、标题与存活适配。
- L5：scope、IPC、异步回复、刷新和设置生命周期。
- L6：诊断事件裁剪、当前启动证据和升级回执。
- L7：剩余服务 owner 矩阵；只收束有实际重复决策证据的模块。
