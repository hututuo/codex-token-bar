# 跨平台侧栏展开偏移修复

工作目录：`/Users/huyiyang/.codex/worktrees/8b5b/codex-token-dashboard`。

## 根因与修改

真实 Tauri 窗口复现了独立 WKWebView 测试没有复现的问题：88×560 的网页画布被居中裁切到 88×470 的窗口时，WebKit 自动加入顶部遮挡边距，可视高度变成 515。DOM 中的固定中心仍是 280，但实际内容向下多偏了 45；窗口缩小时这个补偿继续变化，形成斜向移动。不能用纯 CSS 或请求窗口坐标的测试证明画面正确。

`quota_sidebar/canvas_macos.rs` 现在为无标题栏的侧栏显式接管遮挡边距。macOS 26 使用公开的 `setObscuredContentInsets:`；该 setter 对相同值直接返回，所以在显示前先设 1 再归零，确保进入手动模式。旧系统保留能力检查后的 WebKit SPI 分支，旧系统实机验收尚未完成。[WebKit setter 实现](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebView.mm)，[macOS 自动边距实现](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/mac/WKWebViewMac.mm)。

网页本身固定在独立的 AppKit 画布内；动画只移动外层画布和原生裁切窗口。画布按 AppKit 实际接受的取整尺寸定位，避免用未取整的动画目标产生亚像素错位。没有新增常驻轮询。

一级色条、二级圆环保持挂载，切换只改变透明度；隐藏的二级内容使用 `inert` 和 `aria-hidden`，不拦截点击或键盘操作。保留非线性进度动画与减少动态效果设置。

## 验证状态

- PASS：38 项前端侧栏测试。
- PASS：17 项原生侧栏几何和状态测试。
- PASS：真实 Tauri + WebKit 的展开与收回，共 112 次原生布局采样，viewport 恒为 88×560，内容中心恒为 280，屏幕贴边坐标恒定。原生中心的取整误差不超过 0.5 点。470 高的测试内容上下留白均为 70 点。
- PASS：生产构建、应用签名校验、`git diff --check`。
- BLOCKED：Mac 锁屏后无法完成修复后的肉眼动态验收。
- NOT_RUN：Windows、旧 macOS、120 Hz 实际呈现帧率验收。
- NOT_RUN：替换运行中的应用；未启动新生产包读取本机历史索引。

112 次采样检查的是原生窗口与 WebKit 布局，不等同于实际呈现帧率。

日志、前后对比和 `verification.json` 位于 `runs/20260910-sidebar-motion/`。
已构建候选包：`dist/sidebar-motion-preview/Codex Token Bar.app`。

## 重现原生布局检查

在仓库根目录生成真实 React 组件的静态夹具：

```sh
node tauri-app/scripts/prepareSidebarMotionFixture.mjs runs/sidebar-motion
cargo run --manifest-path tauri-app/src-tauri/Cargo.toml --example sidebar_motion -- "$PWD/runs/sidebar-motion/hover.html"
```

该 example 只加载夹具和生产原生画布代码，不读取账户、设置、会话或索引。日志返回窗口实际尺寸及 WebKit 中测量的内容矩形。用 `SIDEBAR_SMOKE_HOLD=1` 可让展开状态停留三分钟，供视觉检查。

## 替换与离开事件补查

2026-09-10 已应用户要求替换测试包；用户确认展开定位正常。随后修复偶发鼠标离开后仍停留的问题：原实现只在离开事件后检查一次；动画过程中结果仍为 inside，后续再漏掉 exit 事件时就没有收回机会。

`presence.ts` 仅在展开、未固定、非拖动时，每 250ms 串行检查侧栏和详情卡的真实窗口范围。连续两次 outside 才收回，跨越详情间隙或重新进入会清零判断；固定、拖动、关闭、禁用都会取消检查及失效在途结果。无重叠 IPC，收起时没有补查定时器。

42 项前端侧栏测试通过（含漏事件、短暂离开、在途取消、错误和慢响应回归）。构建与签名通过，新测试包已启动，PID 57363；启动日志确认侧栏、详情卡渲染及主界面 ready。此轮未声称完成偶发问题的长期人工验收。
