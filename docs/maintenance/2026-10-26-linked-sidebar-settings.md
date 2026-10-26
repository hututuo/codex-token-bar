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
