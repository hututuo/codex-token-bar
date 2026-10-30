# 二级菜单速度图左侧截断

978只限制最大尺寸并裁切，未复用中位图的内宽和按钮排布。88pt原生组件渲染中仍可复现标题左侧被切掉，fittingSize为88不足以证明内部没有越界。

修复与SidebarBodyMedianContent对齐：固定图面74pt，置于88pt侧栏中心，横向/纵向内边距5/4pt，使用同一个SidebarPulseButtonStyle；标题9pt、时段7pt。取消整块内容的裁切，曲线仍在自己的Canvas范围内绘制；时间窗已过滤读数，绘图裁切保留线帽空间。三级详情和速度原始采样不变。

跨平台同样采用74px图面，外围按钮居中而非撑满后截断。实际产品CSS/组件预览测得速度图、中位图、速度标题均为left221/right295/width74，侧栏left214/right302/width88，两侧各7px；小图点击已验证到详情。

本地小型原生布局渲染使用真实视图源码、同一段既有速度记录回放，采集/偏好依赖由无IO测试替身代替，不代表安装版截图。原生图面边界像素检查两边4pt安全区为0个非背景像素。另加入全项目的原生像素回归，使用隔离的内存history与临时defaults，不读取或改写真实账本。

- 原生前后图与小型渲染工具：scratch/20261030-sidebar-chart-inset/
- 跨平台预览：http://127.0.0.1:58914/dev-previews/sidebar-chart-inset-review.html
- 跨平台1366项通过；TypeScript通过；小型原生源码Swift6编译与渲染通过。

## 云端检查和本机替换

- 源码：`be11283c1b8827fce54798e462b30890d2fedd70`。
- 全量检查：https://github.com/hututuo/codex-token-bar/actions/runs/41015363740 （全部通过）。Swift XCTest2173项、28项平台跳过、0失败；另665项Swift Testing通过；前端1366项、TypeScript、双端Rust和updater检查通过。
- 构建：https://github.com/hututuo/codex-token-bar/actions/runs/41015382518 。Mac候选已通过签名、资源、manifest与SHA核对。Windows安装包结果另以该运行最终状态为准，未替换Windows EXE。
- 15:04退出978、备份后替换0.9.7 build979；从/Applications正式位置启动，进程92225，SHA256 `8d9ea447a8dd8dba3d90e326b9a9c89dfdcdbe5453a2a570e0a91034c43319ca` 与云端一致。
- 备份：`/Users/huyiyang/Library/Application Support/CodexTokenBar-InstallBackups/20261030-150409-build978-before979`。
- 576份历史索引无旧事件键缺失，527397条、85481203509 token替换前后完全一致；客户端历史、正文测速和旧活动速率记录均保留，核对JSON在scratch/local-install-build979。
- 新版已加载精确数据，速蹬15:06:06显示统计已上报。当前自动化仍只暴露主窗口，不能把组件渲染/像素测试说成已在正式非激活侧栏完成点击验收。跨平台实际组件88px边界与点击通过；原生全项目像素测试通过。
- 原生旧图在两侧4pt保护边距绘入269个像素，修复后0个；云端真实项目测试产物见scratch/20261030-sidebar-chart-inset/cloud-previews/native-sidebar-speed-insets.png。

无schema/日志扫描/价格/账本变化，既有数据与其他预览保留。
