# 展示页与素材 / Showcase and media

本目录与 README 介绍基于正式发布的 v0.9.7，功能证据取自对应标签及发布说明。它是静态产品介绍，不读取 Codex Home、账号凭据或用户会话，不连接本机 app-server，也不运行第三方雷达查询。

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

| 展示 | 复用来源 |
|---|---|
| 色条／悬停概要 | `SidebarRailContent`、`SidebarSummaryLayer`，原 `QuotaSidebar.css` |
| 额度、任务、重置卡详情 | `QuotaDetails`、`RunningDetails`、`ResetCreditDetails` |
| 悬浮窗 | `FloatingPanelSurface`，选用程序支持的简洁内容配置 |
| 画布中的位置吸附 | 原 `resolveDockAnchor` 纯几何函数；不是原生多屏窗口管理器 |
| 趋势图／年度热力图 | `RecentUsageChart`、`TokenActivitySection`，保留真实组件交互 |
| 正文 TPS | `ObservedSpeedDetails`、原模型展示与样本质量判断 |

账号、会话标题、ID、用量、额度、TPS、日期分布和重置卡均为 `fixture.ts` 中的模拟数据，不能当作模型测试结果。桌面背景与工作区是说明场景，不是 Codex 的实际截图。演示画布只复用组件与边缘位置判定，不能证明原生多屏兼容性。详情中的原生历史读取入口保持禁用，打开主窗口动作改为介绍页内导航。

自动演示可暂停；减少动态效果偏好会停用自动播放。窄屏详情中隐藏演示悬浮窗，防止遮挡额度；不改变软件行为。

## README 动图

- `displays.gif`：程序组件渲染的贴边、速览、详情、右侧停靠、悬浮窗吸附状态，在状态间作展示用淡化剪辑；不是原生窗口动画逐帧录像。
- `usage.gif`：原图表组件的 24h / 7d / 30d 状态回放。
- `cache-reminder.gif` / `.mp4`：已完成的 12 秒操作宣传片。Codex 部分为独立模拟；Bar 提醒由原 SwiftUI 视图原生渲染。模型／强度／Fast 切换只是演示情境，不证明它们必然造成低命中。
- `body-tps.png` / `heatmap.png`：原组件截图，数据为模拟。

保存的 PNG 是动图源素材，可用本机 ffmpeg 重建：

```bash
python3 scripts/showcase/render-media.py
python3 scripts/showcase/manifest.py
python3 scripts/showcase/verify.py
```

缓存宣传片的音效为原项目自行合成的点击、键入、发送和提示声，无外部音乐或人声。GitHub GIF 无音轨，完整 MP4 保留音效；网页默认静音，用户可自行开启。

组件、样式与展示源码沿用仓库 AGPL-3.0；原项目 MIT / Codex++ 归属继续保留于根目录 License 与 notices。没有复制外部项目代码、图片或字体来搭建新展示页。素材 hash 见 `asset-manifest.json`。

## 口径与未启用功能

- 官方额度通过本机 Codex app-server 取得；雷达预测和均匀使用参考不冒充官方余额。
- 正文 TPS 是本地正文分词与记录时间口径，可能包含网络等待，不是服务器纯推理速度。隐藏思考、工具返回和动画估算均不作为正文测速样本。
- 历史账本保留已入账事实，不从已丢失且从未读取的会话凭空补量。
- 缓存续问时限、旧间隔图及额外扫描仍停用；速度叠加用量趋势和未合入 PR 不宣传为 v0.9.7 正式功能。

## 核对来源

`release-notes/v0.9.7.md`、`Sources/CodexTokenBar/QuotaSidebarGeometry.swift`、`ThroughputTelemetry.swift`、`CompletedBodySpeed.swift`，以及 `tauri-app/src/quota-sidebar/`、`components/liveRate/`、`components/recentUsageChart/`、`floating/` 下实际实现。数据口径以对应源码与应用内说明为准。
