# Windows 额度侧栏：黑条展开为圆环

## 审查结论

本轮用户确认的目标是 `quota-sidebar` 的 rest → hover 动画，不是悬浮窗贴边展开。
`git fetch origin` 后远端 main 为 `29b77776`；当前分支基线 `1a20e4c5` 已包含远端全部提交，领先 107 个提交，无需 pull/merge。工作区此前保留的 7 个悬浮窗相关未提交文件及 `HANDOFF.md` 未纳入本轮修改。

1. 最近的 `ec2bd2a3`、`e7f3a9dd`、`b20c7e88`、`1a20e4c5` 修改的是 floating 路径，未覆盖用户指出的额度侧栏。
2. `placement.rs` 原 Windows 路径每帧分别调用 set_size / set_position。Tauri 和 Wry 会把新尺寸传给 WebView2，网页随窄黑条到圆环的过程反复重排。
3. `main.tsx` 的固定画布 CSS 只对 Mac 启用。Mac 的 `canvas_macos.rs` 已把固定内容和原生裁切分开，Windows 缺少对应实现。
4. 审查还发现 floating 的跨父子 HWND `DeferWindowPos` 批次不符合 API 要求；它不属于本次用户确认的路径，本轮没有修改。微软要求同一批窗口拥有相同父窗口：[DeferWindowPos](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-deferwindowpos)。

以上为代码证据和实现缺陷；本轮没有在 Windows 上复现或宣称完成视觉验收。

## 修改

- Windows 额度侧栏固定 WebView2 和承载 HWND 为 88×560 逻辑像素，禁用 Tauri 自动缩放并复用已有 Wry per-HWND viewport gate。
- 展开/收回使用 `SetWindowRgn` 改变可见、输入区域。常规动画中承载窗口和 WebView2 不改变尺寸或位置，避免父子 HWND 不同步；圆环和文字的页面布局保持不变。
- 左右贴边、100%/125%/150%/175%/200%/250% DPI 均通过同一套像素几何计算。先取整固定边缘、再求窗口坐标，避免右侧逐帧一像素漂移。
- 窗口区域由 Windows 持有，失败时释放临时 GDI region；不加入 DwmFlush、额外 hover 延迟或常驻轮询。
- 位置读取、鼠标离开判断、拖动和反向动画读取真实裁切区域，不将固定画布的透明部分视为侧栏范围。
- 原生事件仅为装饰边框发布当前裁切尺寸；圆环定位不依赖事件到达时间。
- 详情卡保留独立窗口及正常 WebView2 缩放。Mac 沿用原实现。
- 修正已有测试夹具：quickToggle 缺少 `platform: "windows"`，cards 的 DOM 环境缺少 `Element`；未放宽产品断言，并增加 loading 平台禁用断言。

Windows x64 和 ARM64 共用 `#[cfg(windows)]` 实现，没有架构特判。

## 本地验证

- PASS：56 项侧栏前端测试。
- PASS：20 项 Rust 侧栏几何/动画/拖动测试，含 2,904 个固定画布动画采样。
- PASS：TypeScript 检查及 Vite 生产构建。
- PASS：Windows x64、ARM64 原生适配器类型检查，使用真实 Tauri/WebView2/Win32 依赖及生产源码。
- PASS：SSR Windows 动画夹具生成；`git diff --check`。
- BLOCKED：完整应用 Windows 构建。本机缺少 Windows C SDK，依赖 ring 编译在 `assert.h` 缺失处停止。
- NOT_RUN：Windows 应用/探针执行、WebView2/DWM 实际合成、鼠标穿透及视觉验收、两架构安装包构建。
- NOT_RUN：替换运行中的 Mac 应用、发布/上传。

日志位于 `runs/20260920-windows-quota-sidebar/`。模块类型检查刻意绕过主应用的 SQLite/ring C 依赖，不能替代完整应用编译或运行验收。

```sh
node --test tauri-app/src/quota-sidebar/*.test.mjs
cargo test --manifest-path tauri-app/src-tauri/Cargo.toml --lib platform::quota_sidebar
npm --prefix tauri-app run build
cargo check --manifest-path tauri-app/src-tauri/tests/sidebar-windows-api/Cargo.toml --target x86_64-pc-windows-msvc
cargo check --manifest-path tauri-app/src-tauri/tests/sidebar-windows-api/Cargo.toml --target aarch64-pc-windows-msvc
```

## Windows 虚拟机验收

有 Rust、MSVC/Windows SDK 和 WebView2 Runtime 后，在仓库根目录生成并运行独立探针：

```powershell
node tauri-app/scripts/prepareSidebarMotionFixture.mjs runs/sidebar-motion
$SidebarFixture = (Resolve-Path runs/sidebar-motion/hover-windows.html).Path
cargo run --manifest-path tauri-app/src-tauri/Cargo.toml --example sidebar_motion_windows -- $SidebarFixture
cargo run --manifest-path tauri-app/src-tauri/Cargo.toml --example sidebar_motion_windows -- $SidebarFixture --left
```

探针加载真实侧栏组件的静态输出和生产 Windows 画布代码，不初始化主应用的账号、设置或用量数据库。输出 `REPORT` 的 viewport 应保持约 88×560、summary 中心应保持 280；原生 host 大小固定，clip 随动画变化。探针只检查布局，仍需观察实际合成画面。

随后在候选应用中检查：

1. 左/右侧最窄黑条 → 圆环 → 黑条，快速进出/中途反向；无斜移、裁切、闪跳。
2. 点击圆环打开/关闭详情，圆环侧栏不跳位。
3. 收起后原圆环区域可点击桌面；移出可收回，固定后保持展开。
4. 拖动到两侧、屏幕顶/底边界；125%/150%/200% 缩放与跨屏移动。
5. 有/无 5h、减少动态效果设置。探针默认仅无 5h，其他状态由候选应用验收。

用户将在准备好后开启虚拟机；本轮交付的是待 Windows 运行验收的代码修复。
