# 额度侧栏 / Quota Sidebar

独立交互原型，使用固定示例数据，不读取账户、不改动 Swift/Tauri 运行应用。

运行：`npm install` 后执行 `npm run dev -- --host 127.0.0.1 --port 4178 --strictPort`。

- 三层：16px 纯竖向色条常驻（无文字和数字）；悬停展开 88px 额度环速览；点击额度环或任务项打开详情卡片。进入详情卡片保持展开；离开后延迟 300 ms 收起。
- 独立开关、左右吸附、额度/任务页签、固定详情、Esc 收起。
- 播放演示：模拟鼠标靠近、环形速览展开、点击后打开详情、移出收起；可中断。
- 额度环统一显示剩余比例。详情区展示 5 小时/周额度、本地今日用量、实时速率、运行任务和完成提醒。

视觉参考：用户提供的截图及 https://github.com/vinzdg/codenotch 。阅读了 NotchLayout.swift、SideNotchShape.swift、TooltipCard.swift，借鉴主体/详情分开布局的思路；本 Demo 为独立 React 实现，没有复制其源代码。

本版验证交互和信息层级；真正的屏幕边缘吸附、透明原生窗口、跨屏和全屏工作区留待设计确认后的产品实现。
