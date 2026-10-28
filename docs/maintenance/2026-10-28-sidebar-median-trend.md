# 侧栏正文 TPS 中位数迷你趋势

分支：`codex/sidebar-median-trend`；基线：`3a945511`。仅在独立 worktree 修改。没有打包、安装、替换或重启正式版，也没有修改生产数据库。

## 已接入

- Mac 原生侧栏、Tauri/Windows 侧栏：正文 TPS 原 5/15/30 分钟三列改为「模型 + 中位数数字 + 迷你中位数折线」。点击仍进入已有测速详情。
- 固定最近三小时、六个完整半小时区间。数字只显示最近一个完整区间；缺样本显示 `—`，不借用旧值；空档不连线。
- 继续使用统一模型颜色；每个模型独立纵轴，只比较自身趋势。悬浮说明提供每段时间、中位数和样本数。
- 复用现有 5 分钟统计索引和数据库持有者；不新增库、表、原始日志扫描或网络请求。
- 仅在侧栏展开且可见时每分钟串行读取。收起/隐藏停止；切换数据源忽略过期响应；读取失败清空旧显示并提示。

## 统计口径

每个 5 分钟桶沿用已有质量过滤后的 `输出 Token 合计 / 测量时长合计`。每半小时对这些桶速率等权取中位数；至少 3 个有效桶、6 段正文。偶数样本线性插值。既不是逐条正文的中位数，也不是所有输出除以半小时墙钟时间。

未完成的半小时不参加显示，避免同一数字不断混入新旧区间。与主页分布统计的中位数算法一致；主页是否显示未完成区间、查看范围和现有详细均速保持不变。

## 文件及合并注意

- Swift：新增 `SidebarBodyMedian.swift`、`SidebarBodyMedianView.swift`；`LiveRateMonitor` 仅增加读取入口，`BodySpeedSampleWriter` 复用 actor 和缓存 store。
- Tauri：`SidebarBodyMedianCard.tsx` / `sidebarBodyMedian.ts` / CSS；独立命令 `read_sidebar_body_speed_buckets` 只返回数值桶和读取时间，沿用数据源 token 验证和窗口权限。
- `core/live_rate/observed.rs` 提取共享读取错误处理，两种读取共用同一持有者。
- 主线程若已将 `trend_points` / Swift `trend` 改成 `read_distribution` / `readDistribution`，合并时保留主页改动。侧栏必须读取原始 5 分钟 `read(now, 1)`，不能再次对已经聚合的半小时结果求中位数。
- 不要覆盖主线程的数据库升级、启动修复、速蹬或多客户端工作。无数据库迁移需求。

## 验证

- PASS：Swift 定向测试 20 项，19 通过，1 项原有可选本机审计截图测试跳过，0 失败。覆盖投影、存储质量过滤、侧栏高度和原生组件渲染。
- PASS：原生侧栏高度 709 → 709 → 801pt，验证一个新增模型消耗预留空间、第二个新增模型扩展；隐藏模块缩回。
- PASS：TypeScript `tsc --noEmit`。
- PASS：UI/统计/可见性/数据源切换测试 15 项。
- PASS：Rust 在 macOS 主机编译；新接口窗口权限测试 1 项，已有 observed 测速回归 19 项。
- PASS：实际 React 组件使用真实只读快照渲染并截图；Swift NSHostingView 渲染宽度 88pt 检查通过。
- NOT_RUN：Windows 原生构建及真机交互；正式版安装与运行验收；全项目完整测试。这次只完成改动相关定向验证。

测试日志位于此 worktree 的 `scratch/median-*.log`（不提交）。

运行命令：

```sh
swift test --skip-update --jobs 4 --filter 'SidebarBodyMedianTests|BodySpeedTrendStoreTests|BodySpeedMenuLayoutTests|QuotaSidebarHeightBudgetTests'
cd tauri-app
npx tsc --noEmit
node --test src/quota-sidebar/sidebarBodyMedian*.test.mjs src/quota-sidebar/contentSizing.test.mjs src/quota-sidebar/summaryLifecycle.test.mjs src/quota-sidebar/moduleVisibility.test.mjs
cd src-tauri
cargo test --offline --locked --lib sidebar_numeric_speed_buckets_have_narrow_authority
cargo test --offline --locked --lib core::live_rate::observed::tests
```

真实数据组件预览位于本机会话的 visualizations 目录，使用 2026-10-28 12:40 的只读数值快照。该预览是候选组件渲染，不是已安装版截图；没有会话正文或凭据。
