# 右侧一级菜单：圆点内收与十格任务条圆弧封口

状态：已完成。最终源码 `01e28c365c7892475a561b40829cf917180709ac` 的完整云端 CI、双平台打包与产物核验均通过，已于 2026-11-08 21:15:24 CST 安装并启动 0.9.11 / build 996；精确刷新正常完成。用户解锁后，21:38 CST 完成实机截图、展开/收起/快速回切和逐列像素验收，结果通过。起点为 build 995，源码分支 `codex/storage-responsibility-split-20261106`，本次修复前 HEAD 为 `26a9e08c`。

## 实际根因

安装版侧栏窗口截图保留在 `scratch/sidebar-rail-geometry-20261108/before-build995.png`。客户端圆点直径 5pt，灰色轨道宽 4pt，左右各超出 0.5pt；圆点中心还停在轨道顶部起点，导致圆点上半部在轨道之外。原生静态绘制、原生动画与前端 CSS 都沿用此几何；前端动画又把圆点直径硬编码为 5px。

底部十格任务条的各格都是平头矩形，首尾也各留下 0.3pt 分隔留白，整体没有胶囊裁剪。相应动画只有十条 `butt` 线段，终点同样平头。上方模型占比条已有胶囊裁剪，不是本次底部十格问题的来源。

## 修复边界

- 保留灰色轨道 4pt、长度/位置和全部窗口高度预算。收起态圆点改为 3pt，中心移到轨道顶部半圆中心（外部轨道区域 y=4.5pt），上下左右均有 0.5pt 内缩。展开额度环仍是原 5pt 圆点。
- 原生动画终点同步 3pt；前端从真实元素测量中心和直径，按 3→5 / 5→3 连续变化。快速反向时恢复当时的中心和直径，避免结束/反向跳成大圆点。
- 十格任务条使用整体胶囊裁剪，仅第一/最后一格延伸到外轮廓，形成上下半圆端帽。中间九条 0.6pt 分隔缝、每格一个任务、自下而上顺序、颜色和过期/未知语义均保留。
- 动画仅给首尾两条线段增加圆头 mask；绘制仍用 `butt`，不把十格变成十个胶囊，不填死内部缝。沿用现有通用动画/清理机制，不增加常驻动画、扫描或刷新工作。

无数据库、价格、汇总、任务计数、偏好迁移或菜单点击/拖动逻辑修改。预计线、额度数值长度及已验证的存储拆分保持原样。

## 验证

新增原生像素回归直接渲染生产 `ClientQuotaRailTrack` / `SidebarTaskMeter` 与生产 `MatchedStrokeMorphView`：验证圆点每个蓝色像素位于灰色胶囊内；空/部分/满/过期任务条的四角透明、首尾中心有像素、十格和九条缝完整，并比较静态/动画交接像素。另测即时反向与关闭动画恢复原始 View。三项测试被列入完整 CI 的必跑清单；云端输出五张 PNG。

前端回归读取真实 CSS 验证 3px 圆点与 4px 轨道的内缩关系、胶囊容器和首尾格尺寸；使用真实动画函数验证首尾 mask、反向状态及原始元素清理。已有任务计数/状态/几何测试继续执行。

本机仅源文件检查和产物核验，全部编译/测试/打包走 GitHub Actions。沿用 release-macos-app 的签名、资源、完整性、稳定更新身份和独立回滚备份检查。只推任务分支并安装本机候选，不发布 main、tag、Release 或 appcast。

第一轮 `c073c4e5`：前端 1,443 项全通过，原生圆点包含、圆帽四角/中心、九缝十格、动画反向/恢复检查通过；新增像素交接检查中将 46pt/10×8=36.8px 近似用 37px 取模，未正确跳过抗锯齿边界，产生 11 个断言失败。已改为实际像素中心距每条分隔线的距离，仅避开原定 0.6pt 缝及一个抗锯齿像素，没有扩大比较容差、删除断言或改产品形状。五张云端生产组件 PNG 已保留并人工复看。失败轮次没有安装，修正后的最终 SHA 已重新通过完整 CI/打包。

## 最终候选云端证据

源码修复提交为 `c073c4e5`，测试像素采样修正提交为 `01e28c36`。最终 [CI 42474995041](https://github.com/hututuo/codex-token-bar/actions/runs/42474995041) 已全绿；[Release Packaging 42474997807](https://github.com/hututuo/codex-token-bar/actions/runs/42474997807) 使用同一完整源码 SHA，目标 build 996。

| 检查 | 最终源码结果 |
| --- | --- |
| macOS Rust 完整库 | 1,811 通过，14 项既有 ignored |
| Windows Rust 完整库 | 1,755 通过，14 项既有 ignored |
| Swift XCTest 完整库 | 2,393 通过，38 项既有 skipped，0 失败 |
| AgentSpeed Swift Testing | 674 通过 / 79 suites |
| 前端 | 1,443 通过，0 跳过 |
| 云端脚本 / 发布脚本 | 18 通过；111 通过、1 skipped |
| 生产存储场景 | macOS / Windows 各 16 个通过 |
| 备份清理负控 | 两端均为基线 0 / 关闭保护 101 / 恢复 0 |
| 有效但物理 A 被替换负控 | 两端各覆盖 6 个入口，退出码均为 0 / 1 / 0 |
| Windows updater job | 通过 |

三项新增原生像素/动画回归均实际执行并通过。已核对原始日志、测试清单、执行前后源码封印、生产输出与保留报告一致性；`scratch/sidebar-rail-geometry-20261108/cloud-01e28c36/native-validation.json` 为 `PASS`。新增五张侧栏 PNG 及既有六张发现卡片 PNG 一并保留。此轮没有重跑四版本历史矩阵；本次不涉及其存储代码。

打包首轮：macOS 成功，Windows 已生成 release 可执行文件，但从 `https://github.com/tauri-apps/binary-releases/releases/download/nsis-3.11/nsis-3.11.zip` 下载 NSIS 工具时返回 HTTP 504。已保留 `package-logs-windows/windows-package.log`（结尾 6169–6170 行），仅重试同一源码的 Windows 失败 job `128714294720`，不以修改产品代码或跳过 Windows 打包绕过此失败。

同一 run 的第 2 次尝试成功，Windows x64 / ARM64 安装器均生成并通过 manifest 校验；成功日志保留在 `package-logs-windows-artifact-13615674889/`。macOS 沿用首轮已经成功的产物。`cloud-01e28c36/final-validation.json` 为 `PASS`，两个 workflow 均为 success，安装脚本再次核验报告绑定的 SHA 和 build 后才执行替换。

## 本机安装与回滚

- 版本：`/Applications/Codex Token Bar.app`，0.9.11 / build 996，进程 PID 79839。
- 新可执行文件 SHA256：`ad4ffb022d9b9a5b6daa708c7dae6be4fac4fc35ee54c93969491f19304dea1c`。
- App ZIP SHA256：`fca009a32efa81bda0dd2816d4fa620037c98cbef641cd9fe474dfc71335618e`；DMG SHA256：`1e865c8cdc861ce9281b42350ca2f40450cdf0a4362342490a821c68584f5873`。
- `codesign --verify --deep --strict` 与 DMG 校验通过；arm64、bundle ID、designated requirement、Sparkle feed/key 与上一版保持一致。沿用 ad-hoc 签名，未公证，未发布公开 Release 或自动更新。
- build 995 原包完整备份：`scratch/sidebar-rail-geometry-20261108/local-install-996-2x3bphan/rollback-build995/Codex Token Bar.app`。旧文件逐项比对后保留，既有回滚备份未覆盖。新包全部文件与已核验候选逐项一致。
- 首次真实刷新：`usageStore.refresh` 于 13:15:43.678 UTC 以 `status=ok` 结束，耗时 14.818 秒；数字阶段与摘录阶段均完成，保留 550,075 calls / 94,077,231,820 tokens。这是本次运行结果，不作为通用性能保证。
- 安装时遇到锁屏：CoreGraphics 可枚举主窗口和侧栏，但全屏 `loginwindow` 下 `screencapture -l` 返回 `could not create image from window`，辅助功能窗口列表为空。锁屏合成下的缩放窗口尺寸未作为应用布局证据。用户随后明确解锁，实际画面验收见下节。

安装记录、refresh log、产物核验报告均在同一 `scratch/sidebar-rail-geometry-20261108/` 目录保留。

## 补充：彩色分段左右错位感排查

此轮没有发现需要为“按颜色横向错位”额外修改产品源码的证据。不能把所有边缘现象都归为显示器子像素：模型/任务条与额度填充条的结果不同，分别记录如下。

实际名称为 Swift `SidebarModelShareStrip`、Web `.qs-model-strip-vertical`。模型条共用 4pt 宽度、同一中心线和整体胶囊裁剪；内部色块仅改变纵向份额，不带独立描边/阴影或 X 偏移。十格任务条各格共用 `track.minX/width/midX`，只算不同的 top/bottom。Web 任务格统一 `left:0;width:100%`，模型 SVG 分段共用同一条 `M .5 0 V 1` 路径。普通状态没有高亮描边，单色额度条也没有逐色横向变换。

| 实测对象 | 保留位图与取样范围 | 像素结论 |
| --- | --- | --- |
| 模型占比分段 | build 995 本机原始截图，32×848，2×；y=610–701 | 内部色块都在 x=12–19，共 8 物理像素；92 行每个 RGBA 左右镜像差为 0，中心始终 x=16 |
| 任务分段 | 同一截图 y=726–817 | 80 个有内容行，每列 RGBA 左右镜像差为 0；不同颜色、灰色空格都共用 x=12–19，中心 x=16 |
| build 996 实机模型分段 | 32×616 原始截图，y=378–469，回切前/后各一张 | 92 行 RGBA 镜像差均为 0；绿色、暗绿及极短紫色段同为 x=12–19，中心始终 x=16 |
| build 996 实机任务分段 | 同上 y=494–585 | 82 个有内容行 RGBA 镜像差为 0；绿色、暗绿色与灰色空格的边界完全对齐，首尾圆帽对称 |
| build 996 云端生产任务条 | 实际 `SidebarTaskMeter` PNG，8×，96×432 | 内部共用 x=32–63，中心 x=48，alpha 全部左右相等；唯一下端帽抗锯齿像素对 y=398、x=42/53 的绿色相差 2/255，双方 alpha 都是 245，未发生几何偏移 |
| 单色额度填充 | 旧版截图绿色 y=390、紫色 y=555 | 范围仍是 x=12–19；左侧 x=12 相对灰轨约 50% 覆盖，右侧 x=19 全覆盖；对比度加权中心分别 x=16.1922、16.1953，约向同一侧 0.10pt，颜色间只差 0.0031 物理像素 |

上述不把透明背景 RGB 值当作可见颜色；本机截图已合成为不透明 RGBA，只有云端 PNG 能直接核对图层 alpha。原始每行每列 RGBA、中心计算、图像 SHA256 和无插值放大裁剪保留在 `before-build995-pixels.json`、`task-cloud-pixels.json`、`pixel-audit-summary.json` 与 `*-baseline-nearest.png`。

额度条的左缘三通道覆盖比分别约 `(0.497, 0.503, 0.505)` 与 `(0.500, 0.500, 0.500)`，说明这是截图中真实存在的共同覆盖/合成差，不是 RGB 三通道横向分离。该路径使用 `SmoothRateFillBar` 的 AppKit 渐变层，再在 SwiftUI 中旋转 −90°；43.5pt 等长度可能产生半物理像素放置。源代码与像素现象支持检查这条变换/栅格化边界，但尚无隔离实验证明具体是哪一级取整。没有给单个颜色硬加 X 补偿，也没有关闭抗锯齿、改用模糊或重写通用动画引入新风险。

动画方面，模型各色段共用相同整条路径、线宽和 capsule mask；任务条共享目的中心线，只有首尾外侧圆帽不同。展开过程中路径本来会在环/横条与竖条之间变形，不能把任意过渡帧当作静止竖条。当前 SHA 的 `testStaticAndMorphUseTheSameRenderedModelBoundaries`、`testStripMaskSurvivesImmediateReversalAndReleasesOriginals` 及新增任务条/圆点回归均在云端实际通过。

结论边界：已排除这些样本中模型/任务不同色段的真实水平错位。色相/明度对比可以改变细条的视觉重量，但普通截图不能证明 LCD/OLED 子像素排列是原因；当前仅识别到内建 Retina 2×，不推断具体面板排列。build 996 本机位图进一步确认同一结果。当前实际额度为 API 模式，无彩色填充，因此额度填充的轻微边缘差仍严格标为旧版实测观察，没有为了复现而修改用户账户或偏好。没有据此追加产品代码改动。

## 解锁后的最终实机验收

最终成功记录在 `scratch/sidebar-rail-geometry-20261108/local-install-996-2x3bphan/live-yQY0rh/live-sidebar.json`，窗口始终为 PID 79839 / window 876。五个阶段的实际窗口如下，右边缘均为屏幕 x=1512pt：

| 阶段 | 窗口宽×高（pt） | 原始截图 |
| --- | --- | --- |
| 初始收起 | 16×308 | `sidebar-collapsed-build996.png` |
| 悬停展开（原有缓存提醒页） | 88×761 | `sidebar-expanded-build996.png` |
| 离开收起 | 16×308 | `sidebar-recollapsed-build996.png` |
| 快速离开再进入后展开 | 88×761 | `sidebar-reversed-expanded-build996.png` |
| 再次离开收起 | 16×308 | `sidebar-reversed-collapsed-build996.png` |

以上五张原始截图位于同一 `live-yQY0rh/` 目录，均已人工查看；七个鼠标位置采样全部与预期一致，结束后恢复原鼠标位置，没有点击或主动修改偏好。首次展开时恰有应用原有的缓存提醒，快速回切后为正常额度/模型/任务摘要；两种内容都正常显示。首次 13:34 UTC 的快速回切探针曾在预期展开时取到收起状态，该轮未记录实际鼠标坐标，无法确定事件投递或外部输入原因；保留原始失败记录，不计为通过。13:38 UTC 补齐坐标记录后的完整重测通过，产品源码没有为探针调整。云端单测另外覆盖了动画尚未提交首帧时的立即反转，本机五张截图证明的是实际交互结束状态，不宣称逐帧录制覆盖所有瞬间。

像素级复核使用原始 2× PNG、无缩放/插值后再测量：

- Codex 与 Claude 圆点都只占 x=13–18，直径 6 个物理像素（3pt），灰轨占 x=12–19，左右各保留 1 个物理像素（0.5pt）；对应纵向范围分别为 y=152–157、268–273。没有超出灰轨。
- 任务条顶端 y=494 与底端 y=585 的角落和中心像素不同、左右镜像相等，形成半圆端帽；各格及内部间隔在静止和回切后均保留。
- 模型条绿色 `(174,216,130,255)`、暗绿色 `(103,137,120,255)`、短紫色 `(182,97,148,255)` 和任务灰色 `(39,40,39,255)` 共用同一列边界；回切前后所有相关行的镜像 RGBA 差均为 0。
- 最新运行日志仍正常完成精确刷新，13:38:23.394 UTC `usageStore.refresh status=ok`；主进程一直为 79839，没有在交互中重启。

`local-install-996-2x3bphan/runtime-validation.json` 为 `PASS`，保留各截图 SHA256、圆点像素范围、端帽逐列 RGBA 以及模型/任务条汇总；完整列值在 `installed-pass-build996-pixels.json` 与 `installed-reversed-build996-pixels.json`。本机成功收起截图 SHA256 为 `fb348caa399c3298d722c72a834da23abe6cd85200b0acc330d57489fce01825`；回切后收起图为 `e2607f53986f365d21b9a978135b6460119b454c31f095c1e69d312253c08e17`。

最后仅补本文档，安装包仍对应已验证的产品 SHA `01e28c36`；不重编译、不变更已封存的产品代码，也不重复运行无变化的云端测试。
