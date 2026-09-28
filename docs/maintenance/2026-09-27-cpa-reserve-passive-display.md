# Luna Reserve：普通响应中的储备额度展示

状态：IMPLEMENTED_LOCAL_NOT_INSTALLED。本机验证日期：2026-09-27。

分支 codex/cpa-reserve-display，基线 be27b084b646a7dbf301c05d89d58f572b207b7c。本次仅实现用户要求的 CPA 式被动读取与展示；不代表已发布，也不证明任一真实账户会返回 Reserve。

## 请求和出现条件

Swift 和 Rust 均沿用原有刷新时机及无参数的 account/rateLimits/read 请求。

- 不增加第二次 Reserve 请求，不发送 supportsLunaReserve，不添加 Reserve opt-in header。
- 读取 rateLimitsByLimitId；识别 ID base_model_inference、gpt-reserve 或名称 gpt-reserve，忽略大小写及首尾空白。
- 服务器返回相应窗口和有效百分比，就显示该窗口；不要求普通 5h / 7d 先耗尽。
- 服务器不返回 Reserve，就不添加储备占位圆环；字段损坏按待读取/未知处理，不补造 0% 或 100%。
- 这项改动不会启用 Reserve、切换模型、发起推理或执行额度 fallback。重置卡继续走原有独立逻辑。

## 数据与界面

- Swift 从 AccountQuotaSnapshot.limitCards 提供独立 reserveWindows。
- Rust QuotaSnapshot 增加可选序列化的 reserveWindows；空列表不输出，读取旧快照时默认空列表。Tauri / Windows 共用此字段。
- 按窗口时长保留储备 5h、7d 两个读数及各自重置时间；只有其中一个时只显示那个窗口。
- 主窗口额度区、二级侧栏圆环、三级额度详情增加独立的 Luna 储备读数。
- 二级侧栏出现储备圆环时允许纵向滚动，沿用现有原生窗口尺寸和 Windows 固定画布/裁切协议。
- 一级窄条与旧浮窗仍显示普通额度；储备不替换普通 5h/7d，不写入普通额度历史、均一化和速登恢复判断。
- 仅 Reserve 的有效响应按成功读取缓存；读取失败时保留此前储备并标旧。储备不会被选作普通额度或历史身份；如果同时提供旧式 rateLimits 普通卡，仍保留该普通卡。

## 已运行的本地检查

| 检查 | 结果 |
|---|---|
| Swift reader / Reserve / sidebar 定向测试 | PASS：78 项 |
| Swift store / segment / history 定向测试 | PASS：94 项 |
| Rust quota / history 定向测试 | PASS：186 项，含 Reserve 解析、IPC 与缓存/历史隔离回归 |
| Tauri QuotaStrip SSR 与 sidebar 测试 | PASS：90 项 |
| TypeScript + Vite production build | PASS |
| 短屏真实 CSS 滚动布局检查 | PASS：336px 可视区、692px 内容，滚到底后最后元素仍在容器内 |
| 浏览器截图目检 | BLOCKED：Ego Browser 的 Page.captureScreenshot 连续超时，未声称视觉验收通过 |
| Windows 实机、真实账户返回、安装和发布 | NOT_RUN |

测试使用合成返回值，不读取用户凭据，也不发送真实额度或模型请求。浏览器检查属于本地 HTML/CSS 预览，不能代替 Windows 原生裁切和 Swift 实机视觉验收。rustfmt 当前工具链缺少组件，未安装；编译、测试及 diff 空白检查另行验证。

本地测试日志与离线预览保存于忽略目录 runs/20260927-reserve-passive-ui/。旧主动 opt-in 方案继续保留在 codex/luna-reserve-read-only，未整分支恢复。
