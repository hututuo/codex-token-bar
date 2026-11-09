# 模型费用排序、原版四列布局与 TPS 设置定位框验收

## 用户指定顺序

本轮以 build 1003 为安装基线，保留单行 30pt。排序只用于费用表，三个周期共用 Swift/Tauri 同一 JSON 合同，不修改原始模型键、账目或费用。

1. 最新主力：Fable5.1、Opus5.5、Sonnet5.5、Haiku5.5、Astra6、Sol6.1、Terra6.1、Luna6，共 8 个型号。按用户最终确认，最新 Fable 并入该组，不再单列。Sol6 明确放入后面的 GPT 组。
2. Gemini · Claude：Argon4、Flash3.8、Opus5、Sonnet5，用户已确认。不存在实际用量的型号不生成零记录卡。
3. GPT 其他：版本从新到旧，同版本按 Astra/Sol/Terra/Luna 等固定系列序列；包括 Sol6 和 GPT 5.x。
4. Claude 其他：版本从新到旧，同版本 Opus/Sonnet/Haiku 顺序；旧 Fable5 归在这里。
5. 其他：剩余已知模型；独立参考用量置于该组末尾。
6. 未知模型：固定最后，保持统一汇总和参考金额。

相同型号跨客户端不合并费用或抹掉来源；来源可在悬停详情查看。排序不依赖用量，所以刷新和切换周期不会让同一组按金额/Token 随意换位。

## 布局与验证范围

恢复 build 1003 的原始自适应网格：Swift 为 `GridItem(.adaptive(minimum: 204), spacing: 7)`，Tauri 为 `repeat(auto-fill, minmax(204px, 1fr))`；正常主页宽度一行四卡，卡片继续为 30pt 单行。模型名优先保留完整文本，无中间省略号。今日/近 7 天每个非空组不足四格时补齐无金额、无点击动作的“暂无其他模型用量”，不作为模型对象加入汇总或账本。确认无用量时显示四格空态；正在同步/来源不可用时继续保留原来的等待/错误提示。累计不添加空模型槽。

共享 fixture 逐项验证组序、组内顺序、反转输入稳定性、原始来源 ID、Token 和费用不变；Swift 实际渲染与前端完整 CSS 校验覆盖满行、完整“未知模型”和 30pt。新增排序资源加入安装包资源完整性检查。

候选 `c9d56abe` 的 1,452 项前端测试通过，但随后 TypeScript 编译遇到 JSON 空数组被推断为 `never[]`；修订为显式 readonly string[]，不改变运行逻辑。失败候选没有安装。一次更早的调度发生在推送连接完成前，checkout 失败，也不计入验证。

build 1004 的源码 `7eeaf8f2` 已通过 [CI 42584677441](https://github.com/hututuo/codex-token-bar/actions/runs/42584677441) 和 [Packaging 42584679945](https://github.com/hututuo/codex-token-bar/actions/runs/42584679945)，并完成安装。但其中把费用表固定成两列，是实现者对“至少填满一行”的错误扩展；用户明确要求保持原有四列。本报告不把 1004 的双列布局当成最终验收通过。

恢复四列源码为 `5223102afae48563d6fb1ffe9335f71d347b3319`；[CI 42600571422](https://github.com/hututuo/codex-token-bar/actions/runs/42600571422)、[Packaging 42600574385](https://github.com/hututuo/codex-token-bar/actions/runs/42600574385) 全部成功，build 1005 已于 2026-11-09 19:14:24 +08:00 安装至 `/Applications/Codex Token Bar.app`。新的 Swift 回归直接测量 840pt 宽生产网格：四卡高 30pt、八卡高 67pt；双列回归会因高度翻倍而失败，不再仅检查占位数。

验证计数：Swift XCTest 2427 + Swift Testing 676；Rust macOS 1824、Windows 1767（两端原有 14 项 ignored）；前端 1453、工作流脚本 18。两端各 16 个生产场景、备份清理负控、物理 A 替换负控均通过。包 SHA256 `684a234f9cca2a5badedc0d6c7ffb3db3a775cb5e6ee8920d8e1b85ada0b1bd3`；安装后主程序 SHA256 `abba9bcd15aded6c910bf093fc1e7696a55b0047386ecb370175590e3b44c6b2`。沿用 ad-hoc 签名、未公证，未发布 Release 或 appcast。

回滚副本保留于 `scratch/model-order-20261109/local-install-1005-1rcle9ev/rollback-build1004/Codex Token Bar.app`。只读核验绑定安装 attempt `6266f202-2c04-4db8-85e0-330ee973f6ca` 和 PID 64571，确认 startup、首次 refresh、backend/UI completed 及 updater confirmed，详见该目录 `runtime-validation.json`。

实机三周期截图 `scratch/model-order-20261109/build1005-{lifetime,sevenDay,today}.png`；OCR 结果 `build1005-ui-validation.json` 确认每个周期均存在四个卡片/空槽同排，未出现“价格未知”或内部路由后缀。累计图人工核对：未知模型完整显示；原有四列、30pt 和分组顺序正确。无本机 Fable 记录，Fable 排序由共享 fixture 覆盖，不宣称实机出现了该型号。TPS 零样本高亮由原生实际绘制测试通过；本机设置页定位截图尚待补齐，不把云端截图当实机证据。

## 正文 TPS 的设置定位框

Swift `QuotaSidebarRail.sidebarItems` 和 Tauri `SidebarRailContent.layoutItems` 在没有近期正文采样时过滤掉整个 TPS 模块，但设置页仍列出该项。因此高亮状态正常变更，却没有实际目标可以绘制定位框。

修复只在设置页保留原有“正文 TPS / 等待采样”空态作为真实定位目标；退出设置后仍隐藏无数据模块，用户明确隐藏二级 TPS 的选择仍然生效，也不增加一级圆点。空态不创建速度读数、不启动历史查询/轮询，不改速度计算。已有样本继续使用原来的 TPS 内容。

云端实际原生侧栏回归覆盖：零样本目标产生非零布局、悬停高亮增加实际绿色像素、显隐与退出设置后高度恢复、无合成样本、一级无 TPS 点；Tauri 实际组件/CSS和轮询测试覆盖对应目标、显隐、颜色和零查询。原生绘制证据为 `native-tps-settings-empty-locator.png`。

## 实机诊断采集的独立限制

1004 本机持久化脱敏事件存在 startup ready、refresh ready、backend/UI completed，以及和安装 attempt 对应的 updater confirmed，主进程稳定运行。先前 helper 的“First refresh not yet confirmed”不是应用没有完成刷新：导出包恰好达到 6000 条事件上限，只包含较早的 998/1003 事件，`latest-observations.json` 也停在旧版本。

源码 `TokenBarDiagnosticsCore/DiagnosticCollector.swift` 在遍历文件时先截断到 6000 条，之后才按事件时间排序。这是诊断包覆盖当前会话的真实缺口，本轮独立记录，不扩大四列/TPS修复的产品改动范围。实机安装验收使用只读原始脱敏事件与当前 PID、build、attempt 精确绑定；另验证导出包签名/版本、无业务库访问、无敏感字段、导出不改变主进程。不会将该导出包宣称为完整当前运行时间线。

## 空闲线程持锁专项

本机只读核查 `thread-writer-locks` 与对应 rollout 最新生命周期：4 个历史线程仍由 PID 17482 的 Codex 持锁，但最新事件是 `task_complete`。Swift `RunningThreadScanner` 和 Rust `thread_activity` 都将 `task_complete / turn_aborted / thread_rolled_back` 判为 idle，汇总只计最新 running；两端均不使用 writer lock 判断活跃，因此这 4 个线程不会仅因持锁被算为运行中。没有删除锁、停止进程或修改会话。

边界：如果异常退出没有留下结束事件，最后一个 `task_started` 可能在既有 24h 生命周期有效期内继续显示。这不同于已写出 `task_complete` 的空闲持锁线程，本次没有扩大为另一套进程判活机制。审计仅记录线程 ID、进程和生命周期时间，不导出对话正文。
