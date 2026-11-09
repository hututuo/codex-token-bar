# 主页图表客户端、侧栏费用与滚动热点

用户已确认 24h 切换需求指主页的 24h / 7d / 30d 折线图，不是侧栏“最近 24 小时”小图。本轮在四列恢复 build 1005 安装后继续，费用条四列、30pt 高和已确认模型分组是保持项。

## 调查与实施边界

- 主页图表目前使用页面整体客户端范围，没有图表自己的客户端选择。接入独立切换后，三种时间窗口使用相同选择；外部客户端的 Token/请求/缓存数据来自各自持久汇总，Codex 额度和逐桶成本不套给其它客户端。切换时清除旧来源的选择区间和异步结果，热力图、排行与价格表仍保持其页面选择。
- Swift 三级菜单把外部客户端 `ClientUsageSummary` 转为通用 `ModelTokenBreakdown` 后重新计价，丢失已经核算的 `apiCostUSD`、缓存写时长等信息；今日直接明细缺失时，也没有复用主页的已索引事件回退。Windows 汇总侧栏还使用只列累计 Token 的 `ScopedSidebarUsage`，未显示费用；Codex 分支沿用旧未知模型逻辑。计划复用主页费用投影合同，保留原始来源及已知/参考金额边界，不另建计价器。
- 滚动改动必须依据新安装 build 1005 的主线程 `sample` / Instruments 证据。历史报告已有布局、文本和 AttributeGraph 残留热点，不能将前次局部优化视为滚动已流畅；本轮继续核验具体生产调用栈。保持统计计算、权限与数据库校验、四列费用条和现有交互。

全部编译、测试和安装包构建通过云端工作流；本机仅进行代码/产物检查、已安装应用采样和真实 UI 验收。后续修复另用新 build；不把源码改动或单测通过当成实机性能改善证明。

## 当前候选云端验收

修订源码 `1f1db01f1b1e0e65e7db8d1ff724896013f8fe18`，目标 build 1006。[完整 CI 42614334802](https://github.com/hututuo/codex-token-bar/actions/runs/42614334802) 全部成功：Swift XCTest 2431 通过、原有 38 项跳过；Swift Testing 676 通过；Rust macOS 1824、Windows 1767（原有 ignored 保留）；前端 1455、脚本 18。两端各 16 个生产场景、备份清理负控、有效物理 A 替换保护负控均通过，源 SHA 与总验收凭据一致。额外自动运行的 [Public097 42614334813](https://github.com/hututuo/codex-token-bar/actions/runs/42614334813) 也通过；本次不声称重跑四版本历史矩阵。

[Packaging 42614401613](https://github.com/hututuo/codex-token-bar/actions/runs/42614401613) 全部成功，已下载校验 macOS 及 Windows x64/ARM64 安装包。macOS ZIP SHA256 为 `aee10d861f35c35acab5f6e9a1b94787770994f3116768198f2bba48f395f0bc`，程序 SHA256 为 `4260390f4d020b5c44765af1cf66d9ac911137dbba5953f592a4084c4123f886`。已核对 bundle ID、build、arm64、ad-hoc 签名与资源源码绑定；下载后诊断 helper 的独占锁、隐私诱饵、无源改动和输出不覆盖测试通过。沿用未公证候选政策，未创建公开 Release/tag/appcast。

2026-11-09 20:56:20 +08:00 已安装到 `/Applications/Codex Token Bar.app`，进程 PID 40920。旧 build 1005 完整保留于 `scratch/chart-scroll-sidebar-20261109/local-install-1006-hyqa37jk/rollback-build1005/Codex Token Bar.app`，逐文件 hash 与签名验证成功。安装 attempt `76a6c4f6-0323-41ad-8718-33efe1329c7d` 已由新版本正常首次刷新确认；已记录 startup/refresh/backend/UI completed，schema14、完成4368、pending0。诊断导出仍有前述6000事件截断限制，所以运行验收直接对齐新进程的已脱敏持久事件；未把旧导出时间线当作新会话证明。

本机滚动补录 `build1005-no-selection`、`build1005-neutral`、`build1005-neutral-ready` 均因检测到指针移动而中止，不用于前后性能结论；前两份完整基线继续保留。图表基线截图为 `build1005-chart-before.png`。实时数据继续变化，金额对比须匹配同客户端、同日期及相近刷新时间，不能用相隔数小时的绝对总额直接判定账目变化。

## 实现与回归合同

- 图表在 24h / 7d / 30d 旁增加独立客户端菜单，默认跟随主页；可选汇总、Codex 及已启用/有历史的客户端。保持时间窗口，切换来源时清除选区和旧异步准备结果。禁用且无历史的旧选择回退主页。默认跟随模式复用已准备投影，不重复扫全部桶。双端使用同一偏好键 `recentChartClientScope.v1`，不改页面偏好。
- Swift 侧栏使用主页 `ClientModelCostPeriodsCache`，Tauri 使用主页 `clientModelCostItems/clientCostGroups`，保留外部账本已核算费用；未知条目只生成一个参考组，参考金额不加入已知费用。Swift 同时继承主页的今日 indexed fallback。Tauri 从现有精简 summary 保留精确今日数值，不解析缩写字符串。外部缓存字段缺失时不伪造命中率，也不把未知缓存当未缓存输入；输入总量依然显示。
- 滚动热点候选：热力图 53 个列堆栈与 371 个固定尺寸 frame 改成一个直接按已知坐标放置原生圆角形状的 Layout，保留每格 SwiftUI 渐变、drawingGroup、hover/click overlay；不改数据、格子位置、数值或输入采样频率。费用芯片增加完整矩形命中区域，避免从字形/装饰路径逐项推导。热力图既有逐像素参考对比继续运行，并新增完整年网格 365 个数据格与 6 个空格的尺寸/颜色验收。实际收益待相同安装环境复测，不预先声称消除所有卡顿。
- Windows 原有历史图组件已通过 memo 避开高频 live 更新，不为追求双端改动数量强行改写 CSS/SVG 布局；增加真实组件客户端切换、时间窗口保留、金额来源隔离与价格投影回归。

## build 1005 实机基线

首个候选 `1f4385ea` 前端完整测试通过；Swift 构建成功，但新增全年网格测试直接比较未取整尺寸及 `NSColor` 动态颜色，和实际 SwiftUI 像素管线不一致，另一个旧源码约束仍只查根文件中的旧 chart 调用。修正测试为与原始 HStack/VStack 实际渲染比较，并让交互边界断言同时覆盖新的图表包装层；没有放宽既有逐像素等价门禁，没有改生产实现规避失败。失败候选未安装。

`scratch/chart-scroll-sidebar-20261109/` 保留输入驱动、采样、表导出和分析。真实 CGEvent wheel 每次 14px，约 60Hz，六秒下/上交替，实际滚动位移由 AX 位置核实；主进程绑定 build 1005 与 executable SHA。没有本机重编译。

Time Profiler 完整保存成功，CPU 表覆盖 0.356–17.241 秒，对比窗口第 3–16 秒：主线程 CPU sample weight 8931ms，布局 3732ms、AttributeGraph 2764ms、命中路径 767ms、文本 761ms。分类为包含关系，不能相加，也不是帧率；该窗口无 storage 栈样本。普通 sample 的第一次捕获前几秒与 OCR 有短暂重叠，不作为严格速度结论依据。

Animation Hitches 首次 16 秒录制保存失败（exit 17），无有效 trace，不计入结果；保留失败 JSON，仅删除确认已无进程持有的该次 6066686736 字节原始临时文件。改用 10 秒录制/8 秒滚动成功保存，CPU 覆盖 0.428–11.792 秒，约定前后取第 3–9 秒。应用自身 non-system hitch 184 条，P95 50.00ms、最长 191.67ms、超过 100ms 共 4 条；potential-hangs 中最长 1974.66ms，不能把这一含等待区间直接视为 CPU 执行耗时。该模板采样权重与 Time Profiler 不同，不跨模板作提速比较。
