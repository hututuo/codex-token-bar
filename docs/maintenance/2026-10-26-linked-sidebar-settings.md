# 一二级侧栏统一排序与三级设置

2026-10-26；工作目录为`/Users/huyiyang/.codex/worktrees/multi-client-tokens/codex-token-dashboard`，分支`codex/multi-client-tokens`。本次基线`4128e344`；仅更新隔离候选，不安装或重启正式版，不触碰主线程工作区、Windows EXE或Anthropic接口。

## 实现

- 现有三级面板内的一张列表同时管理一二级，拖动把手排序、勾选隐藏；悬停行高亮实际二级模块。一级外观只作默认折叠的按需预览。
- 拆分原组合模块的配置项：实时速度／正文TPS、每客户端额度／模型占比。复用原色条、圆环、原生拖动源和通用形变组件，不新增独立侧栏控制器。
- 额度按客户端整组排序；5h与7d固定前后及左右，单窗口完整圆环。保持46pt条长与现有180ms宽高／形变同步，不再提供长度选项。条目过多滚动保留。
- Swift布局模型：`QuotaSidebarItemLayout.swift`，新键`quotaSidebarLayout.v1`；原模块／额度键保留作回退。Swift控制器保留旧调用的投影接口，只有一份新布局。
- Tauri：`sidebarLayoutModel.ts`、`sidebarLayoutPresentation.ts`、`SidebarCompactBars.tsx`、`useSidebarLayout.ts`；Rust新增读取／保存命令，沿用窗口权限与设置文件锁。首次初始化不覆盖已存在配置，避免两个窗口重复迁移覆盖用户编辑。保存后从文件回读；迟到回复／事件不直接覆盖最新值。失败禁用编辑，可重试。
- 恢复默认仅重排，保留隐藏项、额度勾选及颜色。旧设置键、SQLite账本、Token索引不删不改。

## 验证

| 项目 | 结果 |
|---|---|
| Swift侧栏／多客户端／通用形变／浮窗定向测试 | PASS，175项；原生窗口快速反向／交接测试通过 |
| 会改变正式右侧高度的生产测量测试 | NOT_RUN，本次显式排除，避免干扰正式实例 |
| 前端侧栏与多客户端全部测试 | PASS，114项；含拖动／键盘取消、只在放下保存、隐藏与默认顺序、延迟回复、迁移、失败重试 |
| TypeScript及Vite生产构建 | PASS |
| Rust `cargo test --offline --lib sidebar_layout` | PASS，3项；含重复迁移在用户保存后保持新配置 |
| 实际Tauri组件浏览器操作 | PASS：鼠标拖动Claude到Codex之前、隐藏两级、关闭5h变整环、展开一级预览；开发夹具使用模拟数据 |
| Mac隔离候选 | 已编译并启动；完整手工原生拖动与流畅度仍需用户实看 |
| Windows EXE运行／安装 | NOT_RUN，仅同步Tauri/Rust源码与构建验证 |

日志：`scratch/sidebar-linked-native-final.log`、`scratch/sidebar-linked-ui-final.log`、`scratch/sidebar-linked-ts-final.log`、`scratch/sidebar-linked-rust-final.log`。原生组件渲染图：`docs/design/2026-10-25-integrated-clients/32-native-linked-sidebar-settings.png`，模拟额度明确隔离，非正式应用截图。

## 性能与回退

空闲没有新增扫描或计时器。原生用系统拖动，前端只在指针移动时调度一帧更新；排序只在放下写一次。一级预览折叠时不挂载。仍不能将主线程准备测试等同于GPU帧率或功耗验收。

候选位置：`scratch/launch-preview/TokenBar Multi-client Preview.app`，独立bundle、偏好及数据目录，左侧；正式应用及主线程不变。回退到基线前保留新旧配置，不删除账本；旧代码继续读取保留的旧键。新配置不会被旧版更新，因此再次升级时沿用新配置，若要重新迁移需显式处理新键，不能无条件清空用户设置。

## 后续修正：整环与独立层级显示

用户要求覆盖原「两级同开关」方案：排序仍一份，显示分别设置。布局版本1追加可缺省的`hiddenCompact`／`hiddenExpanded`，旧`hidden`仍保留；编辑原共同隐藏项的单级开关时，先将旧隐藏展开到两级，再只改变目标级，避免另一层意外显示。Swift自定义兼容解码，Rust缺省空数组并校验ID，TS归一化后使用同一语义。两端首次初始化CAS不变，读取失败仍禁用编辑并可重试。

原生和Tauri主条、展开菜单、设置内一级预览分别使用相应层级过滤，旧模块／额度键不覆盖。原长短条选项不恢复。没有一级表现的项目显示「—」。只显示一个层级时，原生形变只对真实存在的两端配对，保留原显隐回退。

整环的两个凸半弧原先叠到整条并淡出一半；现在右半弧接下半条、左半弧接上半条，合成一根连续直条，两边均不淡出。扩展原`ClientQuotaMorphGeometry`适配器承载速度和任务，实际仍由同一`MatchedStrokeMorphView`执行，无新动画控制器／常驻计时器。速度按模型分段保持颜色与比例；任务只有原琥珀状态描边与状态条，不伪造任务百分比。180ms同步收起及440ms展开不变。

Mac累计Token模块原先只在`clientScope == codex`显示Codex，汇总漏掉；现改用现有范围投影。模块内部标题为「累计 Token」。候选实机AX已确认汇总包含`Codex, 1162.8M, 累计 Token`及`Claude Code, 45.2M, 累计 Token`；此为隔离候选数据，不代表正式实例的当前总量。预览的该模块为本次核对开启，正式偏好不变。

最新验证：Swift179项、前端118项通过，TS/Vite通过；Rust布局3项通过，含新字段回存与旧隐藏兼容。日志分别为`scratch/sidebar-levels-native-final.log`、`scratch/sidebar-levels-ui-final.log`、`scratch/sidebar-levels-ts-final.log`。新增测试覆盖整环两半端点、不淡出、总填充长度、半环独立完整条、模型颜色比例、两级独立隐藏、重启保存和恢复顺序保留勾选。原生实际组件测试确认速度／任务也注册同一形变层，反向后清理归零。

33号图是实际原生组件渲染、模拟额度。Mac隔离预览已重新编译启动；完整人工拖动及动效手感未替代用户验收，Windows EXE未运行／替换。此前测试中的JSON原字符串比较改为保存原编码再比，避免再次编码产生不同字典键序误报。

### 文字显隐跟随展开／收起

用户发现文字在圆环尚未到位时已完整出现。原二级内容层只做60ms淡入，现改为与展开同长的440ms渐入（前段较轻、后段逐渐清晰），收起按原180ms非线性曲线淡出；百分比、标签、TPS和按钮文字共同处理，不逐个添加定时器，也不等圆环完成后再突然显示。环形路径仍由原合成器接管，淡入只作用于原内容层。

Tauri二级内容层同步440ms进入／180ms退出，退出保留内容与320ms事件丢失回收兜底不变。减少动态效果时取消过渡。原生定向测试日志`scratch/sidebar-disclosure-fade-native.log`；前端118项通过，TS/Vite通过，日志`scratch/sidebar-disclosure-fade-ui.log`及`scratch/sidebar-disclosure-fade-ts.log`。这属于透明度过渡调整，不新增扫描、刷新或常驻动画循环；人工视觉验收仍看隔离Mac预览。

### 设置并排对照、等时收起与半环接缝（最新，覆盖上文180ms收起）

- 收起改为440ms，与展开时长一致；仍保留各自的非线性曲线。原生宽高／路径／文字退出同长，Tauri原生窗口与CSS也同步440ms，退出内容回收兜底延长到540ms，防止动画结束前卸载。
- 整环两个半弧的透明描边原来单独混合，交界处透明度叠加变亮，交回原圆时消失。通用`MatchedStrokeMorphView`增加可选透明度合成组；相同整环的两半先合成，再统一应用透明度。普通不透明填充不加合成组，左右不同额度仍保留真实分界。反向采样计入父组透明度，结束／取消同时释放子描边与合成组。
- 新增像素测试：未知用量只画12%灰轨道，连接处最大alpha不再双倍；已有快速反向／结束清理测试保留。合成组只在过渡期间存在，不增加常驻动画或轮询；GPU功耗仍未做严格对照。
- 打开侧栏设置时临时展示`一级16pt → 8pt间隙 → 二级88pt → 原间隙 → 三级420pt`，右侧贴边镜像。Mac复用原compact renderer挂载轻量预览面板；退出设置、拖动或关闭时移除内容，恢复正常贴边。两级显示与顺序仍来自同一份配置，指向行会同时高亮一级和二级对应内容。三级原按需一级预览入口暂保留折叠，支持独立查看。
- 原生纯几何测试覆盖两侧、负屏幕坐标、小屏夹取、设置退出及预览区域鼠标保持。Tauri通过瞬态`settingsPreview`标志让原生rail变成112pt，前端使用同一compact组件同时显示两级，不另建renderer。原窗口命令省略该参数保持旧行为；切换详情页也进入去重键。

34号图：`docs/design/2026-10-25-integrated-clients/34-native-all-levels-settings.png`，真实原生组件渲染、模拟额度，非正式应用截图。Swift定向181项、前端122项及TS/Vite通过；Rust原生侧栏几何／动效／canvas定向测试36项通过。日志`scratch/sidebar-compare-native-final.log`、`scratch/sidebar-compare-ui-final.log`、`scratch/sidebar-compare-ts-final.log`。Windows未构建或替换EXE，Mac仅更新隔离预览。

Windows与Tauri/macOS此前固定88pt画布会裁切新增区域，现携带目标宽度88／112pt，通过整个动画保留较大的画布，在终帧后收回。前端跟随匹配的`quota-sidebar-motion-result`回执恢复宽度，不在收起起始时抢先重排；同为detail模式但设置开关变化也进入请求去重与完成判据。CSS侧栏平移使用compositor的`translate`过渡，避免逐帧修改left。共享物理像素测试覆盖1／1.25／1.5／2倍缩放及两侧输入裁切。Windows目标编译尝试在ring的C依赖阶段因缺少MSVC `assert.h`而停止，未达到Windows特定Rust模块的目标编译，不能把Mac通过等同Windows EXE通过。

功能支持核对独立保存于`2026-10-26-client-capability-matrix.md`。当前Claude Code没有接TokenBar正文TPS、活动速条与任务／子Agent扫描；额度只读已有本地缓存。不能用模拟界面或独立Agent Speed的来源适配冒充这些功能已完成。

同时修正单看Claude等客户端时借用Codex任务数的显示：任务、活动速率及原Codex模型占比条只在包含Codex的范围出现，其他客户端不借用；汇总中的任务圈帮助信息明确为Codex。正文TPS未接入时仍明确显示暂无样本。
