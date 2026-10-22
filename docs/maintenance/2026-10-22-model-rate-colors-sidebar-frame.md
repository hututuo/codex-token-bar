# 模型分段速度条与侧栏框架 / Model-composed rate bars and sidebar frame

中文：当前活动曲线为每个模型提供独立贡献，所有速率条及侧栏速率环按其占总速度的比例分色；同模型跨会话累加，未知模型保留灰色贡献。分段不是历史正文均速或今日用量的比例；不改活动曲线算法、费用账本、历史索引和数据库结构。`modelRates` 只增加到实时快照，旧载荷缺失时使用未知色。

English: Current activity-curve rates are grouped by model and used as hard color segments in rate bars and the sidebar rate ring. Contributions from the same model across sessions are added; unknown contributions remain visible in gray. Historical body-speed averages and daily token shares are not used as rate weights. The curve algorithm, billing ledger, historical index and database schema remain unchanged. The additive live `modelRates` field falls back to an unknown color for older payloads.

中文：用量、速度条、测速列表/趋势、模型指纹候选和雷达模型曲线统一调用模型颜色入口。模型身份与指标状态区分：警告、成功率/雷达状态和额度档位仍保留其语义色。已知模型使用相同十六进制色表，5.6 Sol/Luna 与6系列使用独立颜色；未登记模型使用相同 UTF-8 FNV32 计算稳定RGB，避免按图例排序改变颜色。两端颜色对照测试覆盖固定色表和非ASCII自定义模型。

English: Usage charts, rate segments, speed lists/trends, fingerprint candidates and radar model series share model colors. Warning, score/status and quota-tier colors retain their metric semantics. Both platforms use the same fixed hex palette; 5.6 Sol/Luna have distinct colors from the 6 series. Unregistered models receive stable RGB colors from the same UTF-8 FNV32 mapping rather than their legend position. Tests compare fixed colors and a non-ASCII custom model across platforms.

中文：侧栏分为顶部固定工具栏、可滚动模块、底部固定侧栏设置，上下各12pt。只测模块内容高度，避免容器高度参与测量形成增长反馈；保留一个TPS行余量。图表引导两行同字号/字重/正文色；原生鼠标与竖线用同一个可动画坐标在Canvas绘制，并沿实际折线插值，网页用同组SVG及逐拐点路径。按下缩放围绕鼠标尖端，防止漂移。

English: Sidebar chrome is fixed at the top and bottom with 12pt insets; modules scroll between them. Only intrinsic module content is measured to avoid viewport-size feedback, retaining one TPS row of headroom. Both chart-guide instructions use the same readable primary styling. The native cursor and crosshair share one animated Canvas position, interpolated along the actual polyline; the web SVG group follows every vertex. Press scaling preserves the cursor tip.

验证 / Validation:
- Swift related tests: 147 selected, 146 passed, one opt-in skipped; no failures. Native light/dark component screenshots and sidebar height fixtures (582/582/625pt) captured.
- React/TS focused suites: 433 passed; TypeScript/Vite production build passed.
- Rust `cargo check --offline --locked --lib` passed. Full cargo test link was blocked by disk space; direct `rustc --test` harness including production `c_curve.rs`: 10 passed. This is algorithm evidence, not a full Windows build.
- Browser production-component fixture verifies 40/60 → 60/40 with total 100 unchanged, same model colors, equal instruction styling and 12px fixed chrome insets.
- macOS local build942 candidate/install/runtime evidence is recorded outside source in `runs/20261022-sidebar-frame-guide/`. Windows source is synchronized; full Windows build/install and physical multi-display checks remain unverified. No public release in this change.
- No paid detection request or dependency change. A rebuildable Rust incremental cache was removed after a failed test compile exhausted available disk space; user data, source and rollback app backups were retained.

## build943：长轮次中途启动的模型归属修复 / Mid-turn model recovery

中文：build942 实机出现正速率灰色。真实本机 continuation 的模型记录早于应用启动，实时曲线收到新用量但仍为 unknown；正文测速的模型补查没有给活动曲线回填。build943 将活动曲线的 `(会话, 轮次)` 加入同一个有容量上限的元数据查找，并将结果同时回填给测速样本与曲线；已知流式上下文的模型也直接传入。仅回填模型，不回放旧数量，不改预算、速率、队列或结束时间。新轮次缺模型时不继承上一轮的模型；源切换清理源内曲线与上下文。

English: Build942 could show positive rates in gray after starting midway through a long turn. The model context predated app startup, and the existing body-speed metadata resolver did not populate the active curve. Build943 includes active curve `(thread, turn)` pairs in the same bounded lookup, fills both consumers, and passes known stream-context models directly. Recovery changes model metadata only; it does not replay quantities or change budgets, rates, queues or end timestamps. A new turn never borrows the previous turn's model. Switching sources clears source-local curve/context state.

验证 / Validation: exact-turn recovery, mismatched turns, new-model turns, normal completion tail and stopped curves are covered. Native model-recovery/monitor regressions: 99 selected, 97 passed, 2 opt-in skipped, no failures. Opt-in real local metadata replay passed separately: unknown → `gpt-6.1-sol`, unchanged replay rate 218.13333333333333 before/after (synthetic quantity, real model metadata). The read-only replay is evidence for attribution, not a measured TPS claim. Native monitor integration also verifies recovery when there are no body-speed samples.
