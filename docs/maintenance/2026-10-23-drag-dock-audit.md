# 2026-10-23 拖动把手、贴边与 Windows 审计

状态：源码修改与定向回归完成，未打包、替换或发布。Windows 独立悬浮窗卡左的用户现象尚未实机复现，不标记为已修复。

## 产品修改

- macOS 原生与 Tauri/Windows 侧边额度栏顶部增加短横杠，收起和展开均显示，使用既有12pt顶部留白，不增加高度。
- 原生把手独立于固定680pt SwiftUI画布，跟随实际可见窗口裁切；Tauri把手按原有native-width/native-height/canvas-height变量定位。左右吸附、短屏及中途开合不会把提示藏到裁切区之外。
- 把手不截断原有拖动事件，不新增轮询、采样或持久数据。原生顶部拖动区从28pt缩到12pt，避免覆盖顶部24pt工具按钮的点击区域。

## 行为核对

- 侧边额度栏：拖动中自由移动；松开后吸到目标显示器的左右边缘。Windows按目标屏幕左右半区判断，macOS按最近边缘判断，正常工作区内等价。不是可长期停在屏幕中央的窗口。
- 独立悬浮窗：48逻辑点内自动吸四边，超出范围保持自由位置；原生Windows提交层未发现强制左边坐标。新增回归验证收起的左吸窗口拖进屏幕中间后不回吸、不留下计时器，以及跨负坐标/1.5x/2x屏幕移动时不在松手前写回旧边缘，释放后按目标屏幕DPI吸边。
- Windows窗口权限包含startDragging；前端等鼠标释放后才结算吸附；启动位置恢复只执行一次，未发现常驻恢复保存坐标的逻辑。

## 初始SSH检查（下方MCP实测已补充）

Windows通过已知主机密钥核对的Tailscale SSH可达；LAN与悠悠映射本轮未建立SSH连接。只读确认HTTWIN、Windows11 build26200、运行0.9.7。
当前进程47768，EXE SHA256 238b776eeb5d605e64de7a6ee31ea9725a2f391da608df4f0d3e1a82ce9b28eb，与原13:28安装收据acf442...不同，不能用版本号认定源码相同。
当前SSH会话仅枚举WinDisc 1024x768 /96DPI虚拟屏；硬件另有GameViewer/NVIDIA/BOE显示信息。没有实际混合DPI多屏拖动验收，也没有通过SSH操作鼠标或抓屏。

## 验证

- Swift：QuotaSidebarTests、FloatingEdgeDockTests、QuotaSidebarHeightBudgetTests最终52项通过。第一次并行Rust编译时，原有生产侧栏高度等待断言超时（隐藏TPS后未在0.8s内缩高）；单独复查及整组复查均通过，保留首次失败日志，不隐去时间敏感性。
- 前端：浮窗吸附/拖动、侧栏拖动/高度/隐藏树、位置保存/几何生命周期等66项通过；补充把手不参与测高、隐藏树卸载后仍保留把手的3项组件测试再次通过（与66项重叠）。
- Rust：quota_sidebar29项及dock_frame_tests4项通过。运行于macOS，属于跨平台逻辑测试，不能替代Windows HWND/多屏实机验收。
- TypeScript tsc --noEmit、git diff --check通过。
- 浏览器使用正式SidebarRailContent及CSS查看左右、展开/收起四状态；示例读数，非安装后的运行截图。图片在outer仓库runs/20261023-drag-dock-audit/sidebar-drag-handle.png。

## 后续统一验收

1. 安装一致源码的Windows测试构建，核对路径/哈希，拖动独立悬浮窗从左右四边到屏中，核对快速拖放、正在缩放时按住拖动。
2. 实际双屏/负坐标/混合DPI：将悬浮窗和额度栏分别拖到副屏；主副屏交换、热拔插后确认位置恢复。
3. macOS原生把手与顶部三个工具按钮的真实鼠标点击/拖动验收；定向测试已有事件路由和裁切验证，未替换安装。
4. 与已保存的缓存排行、元/s和收回分段等改动一起统一验收；保留所有主索引和账本。

## 追加：Windows-MCP 交互桌面实测（2026-10-23）

用户指出远端有MCP后，已启动原有windows-mcp-server登录任务，经已验证主机密钥的Tailscale SSH临时转发访问Windows loopback MCP。未改Codex MCP登记、UU映射、防火墙或代理。工具返回“成功”不当作验收，逐步核对鼠标位置、按下状态和截图；MCP普通Move受其物理输入控制影响，侧栏最终使用该MCP的PowerShell工具发送完整按住/移动/释放手势。

- 运行物：Windows 0.9.7，PID47768，InstalledAppRemaining/codex-token-bar.exe，SHA256 `238b776eeb5d605e64de7a6ee31ea9725a2f391da608df4f0d3e1a82ce9b28eb`。已找回10月22日14:49安装及构建收据，源码为`5fb403e528eebf7939a4cd6129808e7132ef2120`，不是13:28旧收据。关键浮窗拖动代码与本轮改动前ad1009f0相同；本轮把手尚未安装。
- 交互桌面：2560×1440、工作区2560×1362、150%/144 DPI，仅一个活动显示器。之前SSH的1024×768/96 DPI是另一个虚拟视图，不能代表交互桌面。
- PASS：独立悬浮窗拖到屏中并保持自由悬浮；左侧吸附收起、移入展开、从左侧拖回屏中；额度侧栏右→左→右，最终回到右侧。
- 未通过：独立浮窗移到右边并移开指针后仍完整显示，未自动收成窄条，伴有标题栏/绘制残影。右侧仍能拖回屏中。不能宣称所有吸附方向通过。
- NOT_TESTED：真实双屏、负坐标显示器、混合DPI及热插拔；只有逻辑回归覆盖。
- 原进程在本轮操作前已有设置/额度/精确统计读取失败，本轮结果只证明窗口交互，不证明数据读取链路健康。未删除/修复/重建真实索引。
- 结束时关闭测试开启的独立悬浮窗，侧栏回到右侧；关闭本轮UU桌面查看连接，保留其他连接。MCP ControlStatus确认ready，没有遗留AI输入占用。首次浮窗引导已走完/跳过。

## 追加：Windows拖动坐标修正（源码，未安装）

锁定依赖Tao0.35.3的handle_os_dragging把局部POINTS的地址当作WM_NCLBUTTONDOWN的lParam投递；该消息实际需要低/高16位编码的有符号屏幕坐标。已添加仅floating窗口可调用的原生命令，在主线程读取鼠标位置、检查按住、释放捕获，再投递打包坐标；负坐标正确编码，超出Win32消息范围明确失败。非Windows继续原start_dragging路径，无后台定时器。此缺陷与右侧残影/不收起的因果关系尚未实机证明。

本轮追加检查：TypeScript通过；前端floatingEdgeDock+nativeFrameContract37项通过；Rust dock_frame_tests5项、窗口权限25项通过；diff检查通过。另以原生函数原文和windows-sys0.61.2对x86_64-pc-windows-msvc做compile-only API类型检查通过；Tauri窗口句柄/按键观察在该小型harness中为桩，不能代替完整Windows产品构建或修复后的实机验收。

截图与动作回执位于outer仓库runs/20261023-drag-dock-audit/；左侧展开、拖回屏中、侧栏两侧和右侧异常分别保留，未用合成图冒充。
