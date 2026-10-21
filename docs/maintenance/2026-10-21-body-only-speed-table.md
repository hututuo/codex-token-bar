# 正文测速列表与近期保留

正文测速使用完整 `output_text`、日志直接记录的 `started_at_ms/completed_at_ms` 和本地 o200k 分词。显示中间消息/最终文本、正文ID、会话/轮次、token、时长、TPS与置信度。工具执行时间不替代参数生成时间；思考和工具返回不混入正文速度。

## 工作区状态

本轮确认并实现的是正文时长大于0.55秒、不限token数，以及首页紧凑列表。下述15/30天保留是此前未部署的工作区草稿；新讨论的7天明细、30天汇总桶与SQLite方案尚未实施，不随本轮宣称完成。

- 删除 macOS Desktop IPC 测速客户端；Windows 停止 Desktop 观察器与旧流式测速接入。用量统计与既有活动曲线保持独立。
- 旧流式样本保留在原数值文件中，但排除出正文列表、历史接口及均速。
- 主页仅显示已识别模型的最新6条，时间、模型、类型、会话、数量/时长、TPS、采样状态同排；旁边“查看详情”打开独立居中窗口查看分页记录。顶部显示各模型15/30分钟加权均速，无当前窗口样本时明确标出近7天均速与末次采样时间。低质量记录仍显示，但以具体原因代替单独“低”字。
- 侧边栏独立显示“正文 TPS”，每个模型仅取30分钟内最新一条合格正文的TPS，不做窗口平均、不限3个模型；过期隐藏。每行模型名与数值，时间留在悬停提示；点击进入明细。读取完整已存样本，避免最近10条截断漏模型。
- 详情仅查看已经采到的数值记录，分页显示，按完成时间默认保留30天，可选15天。
- 不扫描旧会话，不解压压缩历史，不再提供原文回算或独立全历史缓存。软件原有压缩读取器仍供用量统计使用，测速不接入它。
- 会话随后被压缩、归档或删除，不删除保留期内已经采到的测速；过期清理只针对自己的正文测速记录，不动 Codex 文件或用量账本。
- 取消按一万条截断正文记录，改成日期保留。缩短保留期会清掉更早的测速；延长不会自动重建已清理的记录。

## 质量与性能

每次汇总重新检查数值，不信任旧 confidence：非有限数、计时/速率不一致、异常标记、>500或<2 TPS仍排除；按起止端点的原始毫秒精度判断，时长≤550ms不计均速，551ms可以纳入，无最低token数量门槛（数量仍须为正）。合格样本≥5秒为高，其余为中；汇总也不再以token数量限制置信度。500 TPS是保守质量阈值，不是模型物理上限。高/中只是日志估算的质量分级，不证明是服务端生成时间。

主页只渲染最新6条单行记录，侧边三级测速页单独采用10条紧凑布局；详情保留原本较宽松的行距。短时长与异常记录继续出现在明细并显示原因。边界、短正文纳入、历史低置信度重评与加权汇总的回归日志，以及真实数值回放，保存在外层 `runs/20261021-body-speed-055/`。

本机普通日志审计曾读取171个索引文件约1.22GB，配出2623条正文，其中153条>500TPS，典型为64token/1ms。试验 reader 加入未在索引里的普通文件后配出3335条，无重复正文ID，debug约17.1秒。这些是离线审计，不接入产品启动或详情打开流程；也不包括另有约13GB的压缩历史。

近期生产 reader 首次有界回填约1.08秒，空闲增量检查约1.15ms。3335条数值记录的debug汇总约2.33ms、重复合并约1.48ms、编码写盘约17.34ms。生产编码/原子写盘移到独立actor，仅变化时写；递增ticket防止旧快照覆盖新快照。macOS过期检查每分钟一次，界面只渲染主页6条、侧边10条或当前详情分页。

## 本地保存与后续

macOS沿用 `CodexTokenBar/observed-speed-<source hash>.json`，Windows沿用自己的既有测速数值文件。只保存定位ID、模型、起止时间、数量、类型、质量信息，不保存正文、命令或工具参数；损坏原文件不覆盖。未新增全历史原文缓存。

15分钟/每小时历史统计和独立SQLite存储的完整设计见 `docs/plans/2026-10-21-body-speed-retention-and-buckets.md`，尚未作为已安装功能交付。

测试日志、私人数值审计、构建与安装回执及回滚包均在外层 `runs/20261021-body-only-speed/`，不提交。

## English

Body speed uses complete assistant text, explicit local item start/end timestamps and offline o200k counts. Desktop streaming-speed collection is retired. The home view displays the latest six known-model records on single lines with timestamps and a separate details button. All retained model averages remain visible with their time range. The sidebar shows only each model’s latest qualified body TPS within 30 minutes; expired readings disappear, and no average-window controls are shown. Low-quality samples stay visible with a specific reason but are excluded from averages.

Details page only retained numeric samples, with a 30-day default or 15-day retention. It never scans or decompresses historical conversations. Conversation deletion or compression does not erase a still-retained numeric measurement; retention never changes usage accounting. Persistence runs off the main actor. Fifteen-minute/hourly historical views and a dedicated SQLite store are specified separately as the next design stage.

## 本机替换验收

用户确认“替换”后，macOS原生0.9.5/922已替换 `/Applications/Codex Token Bar.app` 并启动。签名、摘要、实际进程与主页最近3条/时间戳/模型均速及历史入口实机验收通过；原481条测速ID全部保留，继续新增采样。920应用及数值记录备份在外层 `backups/20261021-speed-ui-build922/`，回执与实机截图在 `runs/20261021-body-speed-055/`。仅删除已被922替代的917—921候选构建，保留日志、源码检查点和920回滚App；未操作Windows或公开发布。

Native macOS 0.9.5 build922 is now installed and running. Signature, executable hash, process identity and the home/history UI passed local checks. All 481 previous numeric sample IDs remain, and new samples are arriving. Build920 and its numeric records are retained for rollback. Windows installation and public publication were not performed.

## 2026-10-22 紧凑列表与中央详情

主页6条单行；侧边三级页独立显示最近10条，不复用主页模型均速卡片，也不在窄侧栏里弹历史表。侧边“打开详细信息”打开屏幕中央详情：macOS 使用独立可关闭窗口，关闭即释放内容观察；跨平台端唤起并居中主窗口，再由主窗口呈现分页对话框。

跨平台详情请求采用内存待办标志与窗口事件，主界面先订阅再消费，覆盖尚未创建主窗口和订阅时序；只有主窗口能消费待办和读取历史，侧边只发起打开请求。不新增定时轮询。详情源身份固定，普通实时快照对象变化不触发重复读取；切换数据源会重新挂载并关闭旧详情。UI与定向测试证据在外层 `runs/20261022-tps-compact-details/`。

缓存提醒及主界面建议续问横条按用户要求后续隔离分支处理，本轮未改。TPS提醒仍处方案讨论，未新增自动弹出或判断阈值。

The sidebar speed page has its own compact ten-record layout and routes full details to the screen center. Main-window requests are retained until consumed, with no polling. History reads are insulated from live snapshot object churn. Cache-related removal and a TPS notification policy are deferred.

923 已完成本机替换和主页/独立详情验收；旧525条记录无缺失/改写，运行后527条。922回滚包与数值备份在外层 `backups/20261022-tps-compact-details-build923/`。Windows实机验证本轮NOT_RUN。
