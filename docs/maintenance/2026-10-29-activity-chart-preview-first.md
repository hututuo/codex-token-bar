# 菜单速度图：先跨平台预览，再同步原生与替换

用户于 2026-10-29 要求：先改跨平台界面，提供实际组件渲染预览，确认后再同步原生、构建及替换。本轮不打包、不安装。

## 最新定稿（覆盖此前 24 小时活动速率图方案）

- 主页去掉活动速率图；正文 TPS 和二级菜单中位数保持原样。
- 二、三级菜单共用最近 3 分钟的速度图，二级紧凑、三级完整。
- 沿用 Agent Speed 的平滑曲线、渐变面积、末端标记和独立悬停层。
- 客户端首次有有效正速率后才出现标签。后续确知空闲显示 0；读不到数据时断开，不延伸之前的速度。
- 显示数据只保留在内存中。速率图不再写库或查询历史库；保留旧表和旧记录，不影响正文 TPS 数据库。

## 本轮实现与边界

跨平台已移除主页 ClientActivitySpeedPanel，二级菜单新增紧凑图，三级测速页新增完整图，TPS 组件未改。ActivityLiveHistory 每客户端最多 181 点，180 秒时间窗，配置变化清空；组件没有持久化或历史查询。显示接口仍使用本地 helper 已有速率数值，不增加外部网络请求。

尚待用户确认预览后处理：原生图同步；停止 Swift ActivitySpeedHistoryController 和 Rust activity_speed_capture 的旧速率持久化写入；保留旧 SQLite 表和数据。当前正式版 build 974 尚未切换这些修改，不能宣称正式版已停止写速率库。不得同时停掉正文 TPS 的记录、保留和明细统计。

原生上一轮的 24 小时绘图 WIP 已保存到忽略目录 scratch/20261029-live-speed-preview/previous-24h-wip.patch；相关源文件已恢复到本轮开始时的 HEAD，待确认后按新方案同步。

## 上游来源

已核对 pinned a94a67fcc78e5d8eea5f82d8d5e737bccf994e2c 的源码，并只读查看 GitHub main。实时图默认近 2 分钟，可选 1/2/5 分钟；核心历史为最近 300 个逐秒桶。原历史页按日汇总，不含现成的 24 小时半分钟速度图。

- https://github.com/zoefix/agent-speed/blob/main/macos/Sources/AgentSpeed/Dashboard/ChartSeries.swift
- https://github.com/zoefix/agent-speed/blob/main/macos/Sources/AgentSpeed/Dashboard/ChartGeometry.swift
- https://github.com/zoefix/agent-speed/blob/main/macos/Sources/AgentSpeed/Dashboard/ChartPlot.swift
- https://github.com/zoefix/agent-speed/blob/main/macos/Sources/AgentSpeed/Dashboard/ChartCrosshair.swift

Catmull–Rom 控制点规则移植为 TypeScript，保留 MIT 来源说明，许可证位于 Vendor/AgentSpeed/LICENSE。未更新 vendor pin、测量公式或上报协议。

## 预览

http://127.0.0.1:58914/dev-previews/live-speed-menus-review.html

使用本机旧活动速率记录只读提取的最近一段 3 分钟做静态预览。只含真实读到速度的 Codex，无 Claude 模拟速度。JSON 和截图在被忽略的本机预览/scratch 目录，不提交用户数值数据。

## 本轮验证

- 前端全量 1357 项通过（scratch/20261029-live-speed-preview/frontend-tests.log）。
- TypeScript 检查通过；git diff --check 通过。
- 浏览器已核对两个实际组件尺寸、单图、客户端标签和悬停时间/速度读数。截图位于 scratch/20261029-live-speed-preview/menus-three-minutes.png。
- 未运行正式打包、替换或原生实机验收。

## 本轮后续定稿：原始点连线、配色和页头分组

用户认可原始 Bar 采样点，要求只平缓连接，不做 5/10 秒均值，不移动原点。当前跨平台 ActivitySpeedLivePlot 已改为保形三次连接，控制点在相邻样本值之间，删除面积填充；测试验证所有原点仍为线段端点、没有额外峰谷。内存缓存不再合并同一秒内的不同采样，180 秒时间窗、每客户端 2048 点硬上限。Codex 跟随现有 Bar/Agent Speed 选项，其他客户端沿用 Agent Speed；二级与三级使用同一绘图组件。

本轮主页配色只改 StatsStrip 的默认展示：现有最新 GPT/Claude 分组保留颜色，其他分组默认灰色。手动覆盖优先，复用 speedDisplay.customColors.v1 持久配置（跨平台 localStorage），没有新建数据库。所有日期范围均可双击修改，恢复默认后旧模型回到灰色。其他界面的模型默认配色未被这条主页规则改写。

页头当前跨平台候选组件：标题右侧为全局工具（刷新、设置、完整日志、更多中的导出/更新/自启）；下方开放式 Codex 专属区（目录、会话管理、增强、自动续跑、会话消失修复、Codex 索引状态）。仅 Claude 视图隐藏该区。没有删除额度行的重置卡或刷新工具，没有恢复头像/用户名。

验证：前端全量 1360 项通过，TypeScript 通过；浏览器已验证汇总/Claude 单独切换及其他模型的灰色配色编辑入口。截图为现有本地快照的真实组件渲染。未构建或替换正式版。原生同步及旧速率落库链路停用仍属下一阶段，不能把当前预览状态说成已部署。

- 主页预览：http://127.0.0.1:58914/dev-previews/dashboard-open-header-review.html
- 原始点菜单连线：http://127.0.0.1:58914/dev-previews/live-speed-menus-review.html
- 检查日志：scratch/20261029-header-tools/frontend-tests.log

## 2026-10-30 用户确认替换：原生同步阶段

用户已在预览后明确要求“替换”。原生现在同步开放页头/全局与 Codex 工具分组、主页旧模型灰色默认与现有 UserDefaults 自定义颜色，以及二三级同一个近 3 分钟原始点图。Canvas 和悬停信息分离，鼠标移动不触发整条路径重建。每客户端/算法内存上限 2048 点，保留亚秒采样，无活动读数的客户端没有标签。主页活动速率图已移除；正文 TPS、中位数组件、账本和额度统计未改变。

Swift 活动速度控制器已经去除 SQLite 打开/写入/历史查询；Rust activity_speed_capture 去除写线程及队列，仅保留旧读接口的来源跟踪。两端都不删旧表和旧样本，正文测速的持久化不在本次停写范围内。新增 Swift 回归覆盖原始点、双算法隔离、断点、上限、曲线不越界及持久颜色覆盖。

当前前端 1360 项、TypeScript 与 Swift 语法解析通过。云端全量编译/测试和安装验收待完成；本段不是已安装声明。预备构建号 975，仍使用已确认的 Agent Speed pin，不公开发布。
