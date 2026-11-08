# 实机滚动、交互与模型表治理验收

## 交付结论与范围

本轮以已安装的 0.9.11 / build 999（`c4330302`）为基线，调查数据加载完成后的连续滚动、模型费用范围切换、会话列表和缓存排行榜。没有本机 Cargo、SwiftPM、Xcode 或前端构建。原始 Instruments、sample、截图及模型来源证据只留在本机 `scratch/scroll-models-20261109/`；其中可能包含进程环境、路径和会话标题，不随维护报告上传。

最终交付为 **0.9.11 / build 1001，源码 `34130edff4232514eaecca24b4fafe78f8f6d0ea`**。该 SHA 的完整 CI `42526799056`、Release Packaging `42525991051` 全部成功，产物校验后已替换本机应用。build 999 和中间 build 1000 均保留完整回滚包。源码和包的验证、已安装运行、实机性能结论分别记录，不互相代替。

模型表的已知别名归并、短名称和长名称布局已落地，原始身份、历史账目及计价边界保持。安全库重复目录读取与图表命中路径有针对性改善；整页滚动仍有显著 SwiftUI 布局/图更新开销，**本轮不能宣称“所有卡顿已消除”**。下文给出同口径测量及其限制。

中间 build 1000（`4612da23`，CI `42518598676`、Packaging `42518600672`）只使整页 Time Profiler 主线程权重下降约 1.3%，部分名称仍受数字列挤压，因此未在该结果上收工。最终版继续减少图表命中路径计算，并将模型名称/金额与 Token/占比分为两行。

### 回归门禁实际拦住的问题

- 新 JSON 最初遗漏 Package.swift 显式资源清单；已补齐资源，并在签名产物上运行真实资源探针、对照源码字节。紧凑卡片高度回归也保留原断言，最终最小高度为 30pt。
- Canvas 重画热力图在半像素边缘、渐变上不等价，已撤回且未安装。最终保留原 HStack/VStack/RoundedRectangle/AnyShapeStyle 网格，仅合成绘制层、关闭装饰层命中；1x/2x、10/14.5pt 和透明色/渐变的像素门禁通过，未放宽精度断言（alpha 容差 3/255；alpha > 0.05 时 RGB 容差 4/255）。
- Windows 既有 V22 缓存测试使用真实时钟，曾在跨五分钟统计边界时失败。仅将该测试改用既有按 Home 隔离时钟，并主动跨十分钟验证缓存失效、不执行 quick-check；生产 Rust 行为不变。
- 同一最终 SHA 的 CI `42525989005` 遇到 GitHub CreateArtifact `ENOTFOUND`。该次不计全绿，另行启动完整 CI `42526799056` 并取得全部成功证据；没有为上传网络问题修改产品逻辑。

## 实机发现与修改

1. **滚动布局反馈。** 原 `InterfaceScaledContainer` 将 GeometryReader 测出的内容尺寸，经 PreferenceKey 写入 `@State`，再施加固定高度。惰性列表的高度估计随滚动变化，造成额外布局反馈。100% 缩放改为原生内容尺寸；自定义缩放通过同步 `Layout` 在同一轮换算逻辑尺寸和视觉尺寸。保持界面比例、动态内容增减和可滚动范围；新增/扩展云端窗口测试覆盖 100%、90%、130% 和大惰性列表。
2. **安全库读取。** build 999 的先前调用栈证明 `refreshSharedAccountAttribution` / `loadContinuityLoss` 路径会在主线程扫描物理库对象目录。本机目录有 33,080 个对象，产生约 123/124ms 停顿。仅在既有、串行保留的物理安全库连接上，按 store + `main.schema_version` 复用对象名集合。每次仍复核物理文件身份、路由/准入和 owner 状态，重新建立逻辑绑定，真实数据行不缓存。外部 DDL、owner seal、物理 A 替换、回滚、未结束事务和逃逸 statement 的安全边界保持原样。
3. **会话表重复投影。** 同一次绘制的计数、空列表判断、可见行和分页原来多次调用 `matchingThreads`，反复过滤/排序本机 4,166 个目录项。现在每轮绘制复用一次结果。选择、删除等操作仍使用实时 store 判断，不把展示缓存作为操作授权。
4. **parser 拷贝。** `unsupportedSources` 原来读取整个 `TranscriptParser` 值再取一个 Bool。改为与已有 state 投影相同的短借用路径，保留各 family、reset、独立值拷贝语义。Agent Speed 上游 pin、价格和上报口径没有更换，只更新本地补丁证明。
5. **派生集合。** Swift 汇总卡已有多客户端费用投影时，不再额外计算没有使用的 Codex 单端费用集合；Tauri 模型 family 分组使用 memo。Windows 会话过滤/排序及排行榜分组本来已有 `useMemo`，列表仍保留分页。Rust 命令的存储工作在 `spawn_blocking` 边界内。没有把 macOS 实机帧率推断为 Windows 实机帧率。
6. **图表命中路径。** 实机栈定位到 `NSView._regionForOpaqueDescendants → platformGlobalWindowDragPreventionPath → ContentResponderHelper.addContentPath → CG::stroker`：滚动会对装饰性趋势曲线重复构建命中区域。将背景、曲线、网格和选中标记留在原坐标下的绘制组，设置 `.allowsHitTesting(false)`；真正接收 hover/click 的 `HoverTrackingArea` 及日期标签仍独立。热力图同样只合成原色块网格，不替换数据计算或交互层。

## 本机真实模型清单

盘点取自只读、带超时的 SQLite 快照与 Exact 持久快照。被冻结输入的 SHA256 为 `41be52c2573f540b76b3588b2513f85f8353dc9ba49a078fcbaee8319700b113`。后续本机仍有新使用记录进入，不能拿两次不同时间的总额直接当作守恒验证。

### 外部客户端：16 个原始项 → 13 个展示项

| 客户端 | 原始模型标识 | 冻结 Token 数（输入+输出） | 新展示/处理 |
|---|---|---:|---|
| Antigravity | `claude-opus-4-6-thinking` | 10,981,374 | Opus4.6 |
| Antigravity | `claude-opus-5-5-high` | 42,482,663 | 与 low 合并为 Opus5.5 |
| Antigravity | `claude-opus-5-5-low` | 40,495 | 同上 |
| Antigravity | `gemini-3-flash-a` | 56,282,494 | Flash3 · A；独立路由项 |
| Antigravity | `gemini-3.8-flash` | 8,443,936 | 与 high 合并为 Flash3.8 |
| Antigravity | `gemini-3.8-flash-high` | 257,899 | 同上 |
| Antigravity | `gemini-3.8-flash-n` | 55,714,167 | Flash3.8 · N；独立路由项 |
| Antigravity | `gemini-4-argon` | 659,019,963 | 与 high 合并为 Argon4 |
| Antigravity | `gemini-4-argon-high` | 537,509 | 同上 |
| Antigravity | `gemini-pro-default` | 11,961,557 | Gemini Pro · 自动；独立路由项 |
| Antigravity | `unknown` | 12,528 | 未报告模型；保留未知价格 |
| Claude CLI | `claude-opus-5` | 20,790,977 | Opus5；保留未知价格 |
| Claude CLI | `deepseek-v4-flash` | 34,030 | DS4 Flash；不再显示成 DS4.1 Flash |
| Claude Desktop | `claude-haiku-5-5` | 39,588,622 | Haiku5.5 |
| Claude Desktop | `claude-opus-5-5` | 793,528,177 | Opus5.5；保持客户端边界 |
| Claude Desktop | `claude-sonnet-5-5` | 1,313,909 | Sonnet5.5 |

Antigravity 的 11 项均找到了实际 conversation `.db` 来源，涵盖 `.gemini` 和 Orca 的发现目录。只解码 generation/executor 的模型字段及关联步骤，不提取对话正文。`high/low/thinking` 是配置或命名修饰；`-a`、`-n`、`default` 没有足够身份依据可并入其他模型，因此仍独立显示且不补猜价格。

唯一的 Antigravity `unknown` 是来源 step 3，输入 5,555、输出 6,973；该文件唯一 generation 的模型元数据只列出 step 1，executor 表为空。不能把同文件的 Gemini 模型套到未关联的 step 3。

Claude Desktop 三类模型可追溯到当前 JSONL 的 `assistant.message.model`。Claude CLI 的两个旧模型仍有历史账本记录，但对应原始文件不在当前发现根目录中，未声称重新读取到旧源文件，也未删除这两项。

### Codex：16 个原始身份和 38 个历史价格段保持

| 原始身份 | 冻结 Token 数 | 展示/边界 |
|---|---:|---|
| `codex-auto-review` | 448,154,824 | 保持按日期映射的 Auto Review (5.4)/(Luna) 和独立额度参考价 |
| `gpt-5.2-codex` | 9,537,010 | Codex5.2 |
| `gpt-5.3-codex` | 213,677,797 | Codex5.3 |
| `gpt-5.3-codex-spark` | 58,294,071 | Spark；独立额度参考价 |
| `gpt-5.4` | 293,032,226 | 5.4 |
| `gpt-5.4-mini` | 35,948 | 5.4 Mini |
| `gpt-5.5` | 7,672,127,860 | 5.5 |
| `gpt-5.6-luna` | 17,153,604,463 | Luna5.6 |
| `gpt-5.6-sol` | 43,233,497,865 | Sol5.6 |
| `gpt-5.6-terra` | 211,945,474 | Terra5.6 |
| `gpt-6-astra` | 5,298,402,783 | Astra6 |
| `gpt-6-luna` | 5,932,041,759 | Luna6 |
| `gpt-6-sol` | 39,822,646 | Sol6 |
| `gpt-6.1-sol` | 13,719,151,577 | Sol6.1 |
| `gpt-6.1-terra` | 2,561,410 | Terra6.1 |
| 未报告（model=null） | 1,688,670 | 未知模型；5 次调用原样保留 |

这 16 个身份均通过 Exact 的 events→sources 映射定位到来源。压缩历史的逻辑 offset 不冒充原文件可直接 seek 的字节位置。原始身份、历史价格段和特殊额度统计没有改写。界面的 Fable5.1“暂无记录”来自价目目录的最新模型占位，不是扫描出的使用事件。本机未发现把 JSON 错误正文误记成模型名的实际记录；相关控制字符、格式字符和异常长度仅作为负向回归用例。

## 归一化合同与守恒

Swift、Rust、TypeScript 使用同一 presentation policy 和 39 条共享样例。已知模型允许大小写/下划线等命名形式，以及明确列出的供应商包装前缀；只有身份形状一致、价表中明确存在的别名才能归并。仅有“同价”关系不能证明模型相同。未知未来版本、未文档化快照日期、任意路由前缀、Fast/free 和未分型 GPT5.6 均保留边界。

展示先读取各原始行已经计算好的价格贡献，再相加；不拿合并后的 Token 重新计价。任何未知价格贡献都让对应完整价保持未知，已知部分另计。悬停明细保留原始模型名，异常文本隐藏但原始账目键仍保留。卡片第一行显示名称和金额、第二行显示 Token 和占比，避免旧版省略号把路由名截成难以辨认的 `ge…`。

冻结实机输入经过生产 TypeScript identity 映射后，前后以下字段完全一致：

| 字段 | 前后均为 |
|---|---:|
| 调用数 | 11,520 |
| 输入 Token | 1,686,720,801 |
| 输出 Token | 14,269,499 |
| 缓存读 Token | 1,587,234,952 |
| 缓存写 Token | 21,248,868 |
| 推理 Token | 7,579,983 |

这是冻结输入的展示映射对账，不能替代计价回归；价格守恒和部分未知成本由双端投影测试另外验证。安装 build 1001 后，再按安装前各模型的时间截点查询历史前缀，16/16 原始模型的调用、输入/输出、缓存读写及推理量均与原快照相等（`build1001-ledger-prefix-comparison.json`）。本机继续追加的 Argon/Astra 新账单另行保留，不被旧截点比较排除或改写。

## 实机性能测量口径

同一台 Mac、同一真实数据目录、1512×897 pt 窗口、100% 缩放。保留正常监听、定时刷新、实时速率和侧栏，没有通过关闭真实功能降低采样负载。数据加载完成后测量；记录期间的增量刷新仍可能与滚动重叠。

本机还有正常工作的其他应用，数据持续追加；跨夜期间系统自动外观从深色变为浅色（自动外观设置开启），因此截图验收比较结构、完整标签及行为，不把整窗截图作为逐像素等价证据。热力图的像素等价另外由固定渲染环境的云端测试证明。以下百分比是指定录制窗口的观察值，不是多轮受控实验的统计显著性结论。

真实滚动使用 CGEvent 的 Began/Changed/Ended phase，目标间隔 1/60 秒、14px/次，每 6 秒上下换向，共 36 秒。脚本与 AX 调用有开销，并非精确 60Hz 回放：Time Profiler 三轮实际事件数为 1,728 / 1,717 / 1,719，约 47 次/秒；会话表两轮为 863 / 1,295。因此比较的是同脚本参数和相同路径，不声称逐事件时序完全相同。AX 内容位置和截图证明页面确实移动。早期没有 phase 的 wheel 校准没有真正滚动，已明确作废，不能混入基线。`sample` 取其中 30 秒、5ms 间隔；完整 Time Profiler/Animation Hitches 各录 40 秒，比较中间 4–37 秒同一区间。

会话列表选“全部会话”；排行榜展开完整列表并加载到 40 行；模型费用今日/近7天/累计按固定顺序切换 12 次。Apple-event 响应探针在单独一轮连续滚动中执行，包含 osascript 启动开销，不能当 FPS。`sample` 的线程样本数量也不能直接当毫秒，包含关系的热点不能相加。

基线原始证据：`build999-scroll-sample/`、`build999-scroll-Time-Profiler/`、`build999-scroll-Animation-Hitches/`、`build999-session-sample/`、`build999-ranking-sample/`、`build999-model-switch.sample.*`、`build999-scroll-response.json`。优化后使用相同脚本和参数记录。

build 1001 第一轮 Animation Hitches 与上一份 Time Profiler 导出在开始阶段重叠，保留该证据但不作为主要前后对比。第二轮 `build1001-scroll-clean-Animation-Hitches/` 在 40 秒录制结束后的保存阶段，可用磁盘空间曾降至约 280MiB，随后保存失败（exit 17），也不计为成功。原始内核采集压缩保留为 `failed-kernel.ktrace.zst`，解压内容 SHA256 `7302ef2c32dba5840533746e4fde06c3191c8f30ecb38c9ee287425faf47f11e`；压缩前后校验相等后才回收临时原文件。

因此补录 16 秒的 `build1001-scroll-bounded-Animation-Hitches/`，采用同一真实 wheel 参数、14 秒滚动；与 build 999 都取录制第 4–13 秒，明确作为短窗口对比。录制时不运行其他采集、导出或解析任务。保存后只导出选定的 CPU、potential-hangs、hitches 和 context-switch 表，不导出包含进程环境的完整 TOC。

## 实机性能结果

### 完整滚动：Time Profiler 的 4–37 秒窗口

以下是 **33 秒内主线程的累计 CPU 采样权重**，不是一次操作等待时间，也不是帧率。各热点含上下层调用关系，不能相加。

| 项目 | build 999 | build 1000 | build 1001 |
|---|---:|---:|---:|
| 主线程总 CPU 权重 | 30,906ms | 30,509ms | 29,852ms |
| 图表/窗口命中路径 | 5,001ms | 4,999ms | 2,207ms |
| 布局相关栈 | 11,515ms | 11,239ms | 12,185ms |
| AttributeGraph 更新栈 | 7,908ms | 7,886ms | 8,803ms |
| 文本相关栈 | 2,282ms | 2,184ms | 2,721ms |
| 模型派生投影栈 | 166ms | 211ms | 131ms |

命中路径权重下降约 **55.9%**，但总权重只下降 **3.4%**。布局、图更新、文本栈的权重仍高，这些观察不支持“整页滚动已彻底流畅”。独立 `sample` 中，主线程 UI 布局/显示类样本比例为 92.9%（999）与 93.4%（1001）；该分类比例也未显示总体开销已经消失。

### Animation Hitches：无导出干扰的 4–13 秒窗口

较短补录完整保存成功（exit 0），CPU 表覆盖 0.646–17.165 秒，所选窗口均在有效范围内。两版均按同一 9 秒窗口过滤，只计应用本身、非 system、起止均落在窗口内的 hitch。

| 项目 | build 999 | build 1001 |
|---|---:|---:|
| 主线程 CPU 采样权重 | 8,427ms | 7,259ms |
| 命中路径权重 | 1,457ms | 516ms |
| hitch 条目数 | 238 | 291 |
| hitch P95 | 58.33ms | 41.67ms |
| 超过 100ms 的 hitch | 4 | 1 |
| 最长 hitch | 141.67ms | 166.67ms |
| potential-hangs 超过 100ms | 6 | 3 |

短窗口内长 hitch 变少、P95 下降，但最长 hitch 更长且总条目数增加，不能挑选有利项宣称全面改善；也不能从条目数或累计 duration 换算 FPS。后测仍有约 111ms、180ms 的主线程忙碌区间，栈集中在布局和 AttributeGraph；另一约 279ms 区间只有 67 个运行样本，含等待，不能全部算作执行时间。上述区间没有命中安全库、parser copy 或会话过滤热点。

原完整 40 秒基线里的部分秒级 potential-hangs 只有极少运行样本，切换栈包含 WindowServer/CA fence 等等待。它们不是已证明的秒级业务 SQL 阻塞。40 秒后测的工具导出重叠及失败补录均如实保留，最终短窗结果不能代替长时间稳定性统计。

### 连续滚动时的响应、会话表与排行榜

Apple-event 版本查询在独立一轮真实滚动期间执行 32 秒，包含 osascript 进程启动开销，只是响应探针，不是输入到屏幕的延迟或 FPS：

| 响应指标 | build 999 | build 1000 | build 1001 |
|---|---:|---:|---:|
| P50 | 67.22ms | 70.70ms | 62.92ms |
| P95 | 83.32ms | 79.91ms | 79.01ms |
| 最长 | 98.03ms | 82.53ms | 86.21ms |
| 成功 / 总次数 | 100/100 | 99/99 | 101/101 |

会话表按相同入口选“全部会话”，后测目录 4,169 项（基线 4,166），普通会话 1,025（基线 1,024），保持相同首批分页与滚动路径。`matchingThreads` 在主线程中的包含样本由 **47/3,189 降为 7/2,965**。它支持重复过滤已减少；UI 布局/显示分类却为 1,550/3,189 与 1,635/2,965，不能把单入口的下降当作整个列表的同幅提速。两轮实际 wheel 事件数不同，也不能把样本比例直接换算为响应耗时。

排行榜均实际展开并加载到 40 行再滚动；当前总条目随真实源更新，后测准备时为 363、基线为 362。主线程 UI 布局/显示样本为 2,328/2,649 与 2,214/2,888，等待样本为 278 与 645。未改排行榜的统计内容、排行规则、分页或安全判断。

模型费用范围按今日/近 7 天/累计切换 12 次，最终恢复累计。主线程 UI 样本为 818/3,009（999）与 849/2,925（1001），存储类样本为 24 与 25；交互完成，未证明这一场景总体计算量显著减少。该场景的主要交付是名称清晰、归并正确及部分未知价格仍可辨认。

### 刷新读取与 parser

build 1000 与 build 999 的同口径点击刷新 Animation Hitches（1–39 秒）中，主线程存储 CPU 权重为 **7ms 对 53ms**；超过 100ms 的区间内，`refreshSharedAccountAttribution` / `loadContinuityLoss` 安全库栈样本为 **5 对 55**。目录缓存代码完整保留在 build 1001。这证明针对性读取开销缩短，不是整个刷新提速 87%：两轮主线程总权重分别为 6,304ms 和 4,364ms，不能混用或掩盖。

`unsupportedSources` 的 parser 全值复制已改为短借用，云端值语义回归通过；三版完整滚动样本的 parser copy 命中数为 2 / 0 / 0。未命中采样不能证明其他所有调用点都绝无复制。

### 实机界面验收与剩余边界

- 模型表前后截图：`build999-model-switch-proof.png` → `build1001-models-final.png`。Antigravity 从 11 项收拢为 8 项；重复 Argon4、Opus5.5、Flash3.8 合并，Flash3 · A / Flash3.8 · N / Gemini Pro · 自动仍独立且名称可完整辨认。DS4 Flash、Auto Review 两类标签可读，未知项与 Fable 无记录占位未伪装成已知使用量。
- `build1001-argon-source-tooltip.png` 证明归并后的 Argon4 在真实悬停提示中仍列出 `gemini-4-argon`、`gemini-4-argon-high` 两个原始身份。
- `build1001-heatmap-two-click.png` 证明真实两次点击选出 38 天范围并显示范围总计；`build1001-chart-two-click.png` 证明趋势图两次点击后的选区、数值弹窗及轨迹标记仍有效。没有用测试 hook 代替本机鼠标交互。
- `build1001-session-ready.png`、`build1001-ranking-40.png` 证明列表已加载和展开。会话目录既有的重复 ID 警告仍会关闭危险操作，没有为顺畅浏览放松保护。
- `build1001-sidebar-expanded.png` / `build1001-sidebar-collapsed.png` 及 CGWindow 几何证明悬停展开、离开收起仍正常（宽度 88pt → 16pt）。最终关闭测试弹层，恢复模型累计范围和正常仪表盘。

剩余热点是整页 SwiftUI 的布局、文本测量和 AttributeGraph 更新，已定位到实际主线程忙碌区间，但尚未证明可以用某一个小改动安全消除。关闭真实后台刷新、减少统计数据、跳过安全库校验都不属于可接受的提速。已尝试的 Canvas 替代因视觉回归被撤回；进一步改变大块视图结构需要新的因果隔离和视觉/交互回归，不能把本次云端全绿当作该类重构已获验证。

## 云端、安装与优化后验收

最终源码 SHA 的证据：

| 验证 | 结果 |
|---|---|
| [完整 CI 42526799056](https://github.com/hututuo/codex-token-bar/actions/runs/42526799056) | 全部 job completed/success |
| [Release Packaging 42525991051](https://github.com/hututuo/codex-token-bar/actions/runs/42525991051) | macOS、Windows 及 summary 全部 completed/success |
| Swift XCTest / Swift Testing | 2,419 通过、38 既有跳过 / 676 通过 |
| Rust macOS / Windows | 1,821 / 1,764 通过，各 14 既有 ignored |
| 前端 / 云端脚本 | 1,448 通过、0 跳过 / 18 通过 |
| 两平台生产恢复 | 各 16 场景通过 |
| 备份清理故障 / 有效物理 A 替换 | 两平台负控通过 |
| 诊断包隐私、锁冲突、源不变、既有输出保留 | 两平台生产 smoke 通过；下载 helper 本机 smoke 通过 |

新增模型 identity、价格/Token 保全、目录缓存外部 DDL/rollback、动态缩放和惰性布局、热力图像素对照、长名称紧凑布局、图表第二次点击和摘要卡真实点击均有通过记录。历史四版本矩阵与多尺寸回填规模门禁未在本轮重跑；没有 Windows 实机滚动测量，云端测试不能替代该项。

macOS arm64、Windows x64/arm64 安装包及验证产物均已下载，按 GitHub artifact digest 与包内 manifest 校验；`34130edf/final-validation.json` 为 PASS。macOS app ZIP SHA256 为 `bd3d1745269b844405ad20ff3647b200d49dd95dbff5f23d8fe0170ce865b521`，可执行文件 SHA256 为 `45e14b17bf51ab4993595c2ceb377523cd6d75301dde04049fcab3446e8d0323`。arm64、深度严格 codesign、DMG 校验通过；保留既有 ad-hoc 策略，没有 Apple notarization，也没有发布 Release/tag/appcast 或更新 feed。

从下载包实际运行 `--verify-bundled-resources` 通过，新规则及样例 JSON 与最终源码逐字节一致。bundle ID、designated requirement、Sparkle feed 和公钥均与 build 999 一致。构件验证文件中的 `installed:false` 表示该记录只负责包校验；安装事实另由安装回执与运行态验收证明。

### 安装与回滚

已备份后替换 `/Applications/Codex Token Bar.app`，正常启动 build 1001；首次刷新完成后记录升级确认，而非仅以启动安装器作为成功。无性能环境变量覆盖，也未关闭刷新、监听、侧栏或来源校验。

运行态 PID 76649 的签名、版本、可执行文件 hash 与云端产物一致。安装后诊断 helper 与主程序 `--export-diagnostics` 均通过；主程序入口耗时 1.62 秒、主进程不变，确认了该 build 的首次刷新成功和相同安装 attempt 的升级确认。结构化检查证明诊断没有打开业务库/执行查询，输出未包含原始 Home 路径或敏感字段诱饵。

本机证据根为 `scratch/scroll-models-20261109/`，回滚路径均相对于该目录：

- 上一版 build 1000：`local-install-1001-bc4q53j8/rollback-build1000/Codex Token Bar.app`。
- 本轮原始基线 build 999：`local-install-1000-jex3p922/rollback-build999/Codex Token Bar.app`。
- 最终安装回执：`local-install-1001-bc4q53j8/installation.json`，安装 attempt `641f289e-4cd7-4d7d-90e7-10f00dc0c736`。

原始模型/调用栈/trace/截图仅在本机保留，不将含路径、会话标题或进程环境的材料提交到仓库。Instruments 完成保存后，仅移除了本次采集生成且已无进程持有的冗余原始 `.ktrace` 临时文件；可重新分析的 `.trace`、采样文本、导出表和采集参数仍保留。
