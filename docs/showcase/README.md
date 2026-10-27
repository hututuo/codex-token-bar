# 展示页与素材 / Showcase and media

本目录与 README 介绍基于正式发布的 v0.9.7，功能证据取自对应标签及发布说明。显示方式、历史用量、额度和正文 TPS 使用作者授权公开的本机统计快照，采集于 **2026-10-22 20:32（Asia/Shanghai）**。访问者看到的是静态快照；网页不读取访问者的 Codex Home、凭据或会话，不连接访问者的 app-server，也不发起雷达查询。

## 查看与重建

仓库根目录：

```bash
python3 -m http.server 8080 --bind 127.0.0.1
```

打开 `http://127.0.0.1:8080/docs/showcase/`。可交互页需要 HTTP 服务，不能直接双击 HTML 运行模块。

构建演示组件：

```bash
cd tauri-app
npm ci
npx tsc --project showcase/tsconfig.json --noEmit
npx vite build --config showcase/vite.config.mjs
```

这使用现有锁定依赖，输出到本目录的 `demo/`。展示入口位于 `tauri-app/showcase/`，未接入应用入口或改变生产组件。`demo/` 的已构建文件随仓库保存，访问者不需要先安装 Node。

## 原程序组件与边界

显示方式演示使用跨平台端的原 React 渲染树和原 CSS。产品在独立 iframe 文档中渲染，只加载 `src/styles/global.css` 和 `src/quota-sidebar/QuotaSidebar.css`；外面的宣传页样式不能进入产品文档。

| 展示 | 复用来源 |
|---|---|
| 色条／概要 | 原 `SidebarRailContent`、`sidebarRailClassName`、`SidebarSummaryLayer` |
| 完整详情 | 原 `DetailSurface`，包括标题、导航、正文、页脚和按钮；Vite 仅追加导出，不改 JSX |
| 悬浮窗 | 原 `FloatingPanelSurface`、`DEFAULT_FLOATING_SETTINGS`、`floatingPanelAppearance`；保留默认全部内容，不启用 previewMode |
| 窗口尺寸 | 构建时从原 Rust 侧栏几何代码提取：双窗口 16×250 / 88×680，仅周额度 16×192 / 88×590，详情 420×600；悬浮窗由原内容高度函数计算 |
| 趋势图／年度热力图 | `RecentUsageChart`、`TokenActivitySection` |
| 正文 TPS | `ObservedSpeedDetails`、原模型展示与样本质量判断 |

Windows 固定画布的 88×680 文档按原生窗口的可见尺寸和居中位置裁切，保留贴边一侧的直角与内侧圆角。窄屏只等比缩放整个桌面画布，不单独缩小字体、重排控件或压低侧栏。

`fixture.ts` 只把已保存的 `real-data.json` 转为原组件所需结构，不随机生成数据。快照包括本机已去重的用量账本、真实正文测速记录、官方当前额度、原扫描器采集的运行会话，以及实际雷达返回的展示字段。账号名、会话标题及样本 ID 经作者授权保留；不包含密钥、鉴权与路由字段、原始对话正文或本机路径。

原生事件传输由离线消息通道代替，原侧栏 reducer 处理状态；不调用原生窗口管理或证明多屏兼容性。桌面背景是工作区示意，不是 Codex 截图。详情的原生历史读取入口保持禁用。额度只返回 7 天窗口，未补造 5 小时额度；未读状态未采集。瞬时活动速率未持久化，因此侧栏显示不可用，悬浮窗原组件的 `0.0` 占位在窗外明确标注，不当作实测的空闲状态。

快照时钟固定在采集时刻，让原组件的近 15／30 分钟筛选与当天日期保持一致；没有把样本改成访问时间。动画和交互仍可运行，数据本身不会随时间新增。

演示可以暂停，减少动态效果偏好默认停用自动演示。源码 hash 保存于 `asset-manifest.json` 的 `renderingSources`。

## README 动图

- `displays.gif`：原样程序组件渲染的贴边、速览、完整详情、右侧停靠和默认悬浮窗状态，在状态间作展示用淡化剪辑；不是原生窗口动画逐帧录像。
- `usage.gif`：原图表组件的 24h / 7d / 30d 状态回放。
- `cache-reminder.gif` / `.mp4`：已完成的 12 秒操作宣传片。Codex 部分为独立模拟；Bar 提醒由原 SwiftUI 视图原生渲染。模型／强度／Fast 切换只是演示情境，不证明它们必然造成低命中。
- `body-tps.png` / `heatmap.png`：原组件截图，使用本机真实快照。

保存的 PNG 是动图源素材，可用本机 ffmpeg 重建：

```bash
python3 scripts/showcase/render-media.py
python3 scripts/showcase/manifest.py
python3 scripts/showcase/verify.py
```

缓存宣传片的音效为原项目自行合成的点击、键入、发送和提示声，无外部音乐或人声。GitHub GIF 无音轨，完整 MP4 保留音效；网页默认静音，用户可自行开启。

## 快照数据链路

`scripts/showcase/export-real-data.py` 以 SQLite 只读事务读取应用的已提交索引，使用 `dashboard_source_totals` 和 `dashboard_5m`，不重新累加原始重复事件。正文样本来自应用的 `body-speed` 数据库，均速为合格样本 token 总量除以总时长。额度历史仅使用同一账号的已观测记录，无观测的桶留空。当前额度与运行会话分别在准备阶段由只读 app-server 请求和原运行扫描器采集。

`scripts/showcase/normalize-real-data.mjs` 再调用原雷达解析器及原样本质量判断，校验当日总量与按模型、按日汇总一致，拒绝凭据字段和本机路径后输出公开 JSON。中间采集文件不提交。更新快照需重新获得数据所有者授权，并同时重建界面、截图、动图和素材清单。

组件、样式与展示源码沿用仓库 AGPL-3.0；原项目 MIT / Codex++ 归属继续保留于根目录 License 与 notices。没有复制外部项目代码、图片或字体来搭建新展示页。素材 hash 见 `asset-manifest.json`。

## 口径与未启用功能

- 官方额度通过本机 Codex app-server 取得；雷达预测和均匀使用参考不冒充官方余额。
- 正文 TPS 是本地正文分词与记录时间口径，可能包含网络等待，不是服务器纯推理速度。隐藏思考、工具返回和动画估算均不作为正文测速样本。
- 历史账本保留已入账事实，不从已丢失且从未读取的会话凭空补量。
- 缓存续问时限、旧间隔图及额外扫描仍停用；速度叠加用量趋势和未合入 PR 不宣传为 v0.9.7 正式功能。

## 核对来源

`release-notes/v0.9.7.md`、`Sources/CodexTokenBar/QuotaSidebarGeometry.swift`、`ThroughputTelemetry.swift`、`CompletedBodySpeed.swift`，以及 `tauri-app/src/quota-sidebar/`、`components/liveRate/`、`components/recentUsageChart/`、`floating/` 下实际实现。数据口径以对应源码与应用内说明为准。
