# 模型费用与紧凑任务层级验收

## 目标与数据边界

本次承接已安装的 0.9.11 / build 1001（`34130edf`）。用户明确要求补计历史 Claude 缓存写入费用、识别两个 Antigravity 路由槽位、将未知模型合成一个末尾参考卡，并补全运行任务标题、压缩三级菜单卡片。

最终源码 `a012bdc8` 的 0.9.11 / build 1002 已于 2026-11-09 09:07（北京时间）安装到 `/Applications/Codex Token Bar.app`，首次刷新、安装确认和实际页面验收通过。未执行本机 Cargo、SwiftPM、Xcode 或前端构建。原始模型库存、SQL 复算、截图和云端构件只保留在本机，未上传真实会话内容；原 `scratch/models-tasks-20261109/` 已归档清理，位置见末尾。已有无关维护文档不纳入本次提交。

## 计价与展示

- 历史 `cache_write_tokens` 总量有效、5m/1h 拆分缺失或无效时，使用标准 5 分钟写入价格。有效 1 小时拆分始终优先；缓存读/写总量与输入的包含关系、负数/溢出、每请求长上下文档位和历史价格日期检查继续保留。没有修改原始 payload，也没有把默认假设写成来源事实；后续取得有效拆分仍可补全并重新计价。
- 两个用户确认的别名通过同一 JSON 合同供 Swift、Rust 和前端使用：`gemini-3-flash-a → gemini-3-flash-preview`、`gemini-3.8-flash-n → gemini-3.8-flash`。账本中的原始键不改写。展示名分别为 Flash3、Flash3.8；计价仍使用每条记录的时间和档位。
- 费用表只显示有 Token 记录的模型，不生成 Fable 等零用量占位。
- 未报告、自动路由、合成标记和无法识别的模型在当前选定客户端范围内，跨客户端合并到唯一的末尾「未知模型」卡。原始来源在悬停提示中保留；不把这些记录推断成某个已知模型。
- 未知卡用回退模型（默认 Sol5.6）的输入/缓存读/输出费率显示「参考」金额，提示中注明估算模型与不计入已知费用。原本已有的已知贡献仍进入已知费用小计；仅有未知记录时，已知费用是 `—`，不是捏造的 `$0.00`。Spark 与按日期区分的 Auto Review 参考价格继续独立。

### 本机逐条只读复算

对本机记录按新规则、原始时间和每请求微美元舍入独立复算（`target-price-audit.json`）：

| 原始标识 | 请求 | Token | 5m 默认次数 | 修复后费用 |
|---|---:|---:|---:|---:|
| `claude-opus-5` | 200 | 20,790,977 | 194 | $24.300421 |
| `gemini-3-flash-a` | 520 | 56,282,494 | 0 | $9.303014 |
| `gemini-3.8-flash-n` | 837 | 55,714,167 | 0 | $10.759866 |

这是逐条独立复算结果；下方实机部分另列程序的格式化显示值。Flash3.8 卡还包含已有标准/high 记录，不能直接把最后一行当作整卡金额。

## 标题读取与层级设计

主任务在动态检查 SQLite 列存在后，按 `name → title → preview → first_user_message` 选择第一条有效标题；再使用 rollout 前缀中的首条用户消息。标题取非空首行并去除 Markdown 标题前缀，长度有上限。

子代理保留显式名称，随后读取表字段及 `session_meta/source.subagent.thread_spawn` 中的 nickname、path 和 role：优先显示 `James · windows_model_scroll_inventory`，没有任务路径时可显示 `Rawls · worker`。首条任务消息中的 `Task name:` 也可作为回退。最终仍无信息时显示任务类别加短 ID，避免一排相同的「未命名任务」。

标题提取是展示用途，不参与父子归属、liveness、任务计数或操作授权。父子关系仍仅来自原有可靠 ID 关系；不能根据路径名称猜父任务。额外 rollout 标题读取限制为前 64KiB 内的完整 JSONL，冷启动仅为仍在运行且没有元数据标题的任务读取；结果随既有文件状态缓存，已经超过前缀预算的文件不会在每次追加时重新扫描标题。Claude 继续使用已有有界标题解析结果，不在 SwiftUI/React render 中读文件。

2026-11-09 08:31 左右的本机只读元数据复核（最近一天、未归档，非运行数量）：24 个普通/旧来源任务 `name` 为空但 `title` 非空；14 个子代理 `name/title` 为空，但都有 nickname/path 元数据。这是新增读取链覆盖的实际缺口，未为此改写 `state_5.sqlite`。

三级菜单改为主任务 1–2 行标题加一行元数据（色点、短模型名、推理/阶段、必要的客户端标记和子代理数）；子代理为 26pt 树状行，左侧标题单行截断、右侧短模型名与推理/阶段，悬停显示完整说明。模型与阶段缺失时保留 `—`/提示，不编造推理强度。

## 回归和交付记录

新增门禁覆盖：旧 TTL 默认与有效拆分优先、别名按历史日期计价、原始记录不变、跨客户端未知卡 Token/已知费用守恒、源选择范围、零用量卡移除、旧/新 SQLite 列兼容、标题追加与前缀预算、父子归属以及 10 子代理的紧凑布局。云端同时保留原有完整库、生产恢复场景和存储负控。

首轮候选发现共享 Flash3 名称表尚保留 Preview 文案，以及若干旧用例要求未知模型分散显示；按新产品要求更新展示断言，保留原有 Token、金额和归属断言。全未知小计可能误显示零值的问题另外修正并加入负控。相关失败候选不作为可安装验收结果。

Flash3.8 有 2027-01-01 起的已公告价格段，计价别名测试必须提供事件时间；首轮测试使用无时间的 admission helper 被正确拒绝，已补上明确事件时间，未放宽生产的历史日期检查。首轮 Swift 完整库除上述已定位的四个旧预期外没有新增失败，紧凑 10 子代理布局、标题回退和 TTL 默认用例已真实执行；最终仍以修订 SHA 全绿为准。

中间源码 `d4e0a09ddea310087e1c6371868c608aabb083e4`：CI `42537279106`、Packaging `42537279186`。前端 1,450 项测试、18 项云端脚本、TypeScript/Vite 生产构建通过，生产依赖高危审计为 0；两平台各 16 个生产恢复场景通过，但整轮未通过，不作为安装证据。

该轮在 UTC 零点暴露两项原有日期敏感夹具：Swift 并发追加测试于 23:59:59 开始，写入 `now + 2s` 的下一日事件，日图正确排除未来事件且跨日快照正确转为 `staleCompatible`；Windows 自然日均值测试在 00:01 执行，`now - 120s` 和 `now - 60s` 正好分属两天，因此当天只有第二条、剩余比例为 0.70 而非期望的 0.75。修订仅改测试：追加夹具事件放在已结算区间、缓存断言按实际日界/结算桶判断并加验代次与 stale 重新水合语义；均值夹具固定为前一本地自然日中午两条记录，继续走真实数据库读写并保持 0.75/0.55 断言。未修改生产时间、事务或缓存规则。

最终产品源码 `a012bdc8a56c9a1947f7aec65d067a6e415b317a`：[CI 42538943166](https://github.com/hututuo/codex-token-bar/actions/runs/42538943166)、[Packaging 42538952683](https://github.com/hututuo/codex-token-bar/actions/runs/42538952683) 均为 `completed/success`。所有构件已下载并通过 GitHub artifact digest、源码 SHA、包内 manifest 和完整文件校验；`a012bdc8/final-validation.json` 为 PASS。安装门禁也为 PASS。

已下载的最终 SHA 测试记录：Swift XCTest 2,425 通过、38 个既有跳过，另有 Swift Testing 676 通过；前端 1,450 通过、0 跳过，云端脚本 18 通过，发布脚本 112 通过、1 个既有跳过。macOS Rust 1,824、Windows Rust 1,767 通过，各 14 个既有 ignored；各 16 个生产恢复场景、备份清理负控与有效物理 A 替换负控均通过。最终 SHA 的 10 子代理截图与已审布局 PNG 字节一致（SHA256 `6cb26862b0c9ce0fcc152bce4d94b461c278caeff1ec8592deb726d28d913011`）。本轮未重跑可选的四版本历史矩阵和规模性能矩阵；不将既有跳过项计作通过，也不将云端 Windows 验证说成 Windows 桌面实机验收。

汇总校验保留了历史存储测试逐项状态比较。仅将两个因用户明确改变 TTL 策略而改名的旧用例映射到新用例（缺失/无效拆分不再要求 unpriced，而要求标准 5m）；必须确认两个新用例均实际通过，不以删除旧名绕过其他存储门禁。

## 安装与实机验收

| 构件 | SHA256 |
|---|---|
| macOS App ZIP | `df5dc175a12d4f888a34afb6eac63e37afdca66faf137b2ed49c4df394f9665b` |
| 已安装可执行文件 | `c40386bcf3d4adf3ba4ce02c9e13df18576093afd8efb75d1b49c2ac86ff2c82` |
| Windows x64 安装包 | `057183808fe7430c8763c9cbbada08f33a3084a8a18a398548fe6ee0714b89d4` |
| Windows ARM64 安装包 | `4ff8e9330b32b04f1d5cd382cfb23dca56770dcbdc47fb3c517df917fbbc913a` |

安装时完整比对候选文件清单与复制后的 App，再执行 `codesign --verify --deep --strict`。架构为 arm64；bundle ID、designated requirement、Sparkle 公钥和 feed 与旧版相同。保持既有 ad-hoc 签名策略，未 Apple notarize，未发布 tag/Release/appcast。旧版 build 1001 完整备份未覆盖，备份可执行文件 SHA256 为 `45e14b17bf51ab4993595c2ceb377523cd6d75301dde04049fcab3446e8d0323`。

正常启动 PID 为 59451。下载包的独立诊断 helper 在独占 SQLite 锁与隐私诱饵环境下通过；安装后再次导出诊断包用时 1.212s，主进程未改变，启动与首次刷新均 ready，匹配本次安装 attempt 的 `updater.confirmed` 已落盘。没有把“已请求启动”当作升级成功。

`capture_ui.py` 对运行中的已安装窗口截图，核对用户实际选中的时间范围，再用 `verify_ui.py` + 本机 Vision OCR 和人工图像复核完成验收。初次抓取中恰好发生刷新造成控件位置变化，保留为 initial-capture、不计入验收；最终三页均验证了真实选中的 scope。OCR 区分顶部参考小计说明与模型卡，避免把说明文字误算成第二张卡。

| 实际页面 | 结果 |
|---|---|
| 累计 | 无“价格未知”、无 Flash3 · A / Flash3.8 · N、无 Fable 零记录卡；Opus5 为 `$24.3`、Flash3 为 `$9.30`；Flash3.8 合并 64,416,002 Token，显示 `$12.9`。末尾唯一未知卡为 13,662,755 Token，显示“参考 $18.9”。 |
| 近 7 天 | 无上述残留项；只有一个未知卡，显示 120.8 万 Token、“参考 $0.83”，与已确认费用分开。 |
| 今日 | 无上述残留项；当日没有未知模型用量，不生成未知占位卡。 |
| 任务三级菜单 | 5 个实际运行主任务均有可读标题，未出现“未命名任务”；短模型名 Astra6 与 max/low/high 同行。截图中同一两行标题主卡由约 119pt 降到约 66pt，单行标题约 51pt。 |

本机当时实际运行子代理为 **0**，没有人为制造或伪装成真实任务。子代理标题读取、归属和追加回退由双端回归验证；26pt 树状行及 10 子代理容纳能力由最终 SHA 的 Swift 实际绘制截图、布局测量和前端测试验证。**本次没有在已安装 UI 中看到运行中的真实子代理**，这是实机覆盖边界，不宣称已完成该项现场观察。Windows 同样是云端测试与打包验收，未做 Windows 桌面截图。

16 组外部原始模型在升级前各自截止时间内的请求数、输入/输出/缓存读写/推理 Token 全部一致，`build1002-ledger-prefix-comparison.json` 为 `allOriginalRawModelPrefixesUnchanged: true`。没有用持续增长的全局总数作错误对比。原始路由键、历史 payload、用户会话库和存储迁移边界保持原样。

## 本机证据、回滚与清理

本轮证据归档根目录：`~/Library/Application Support/CodexTokenBar-Maintenance/2026-11-09-model-costs-build1002/`。归档前后逐文件哈希一致，清单为 `archive-file-hashes.json`，搬迁映射为 `cleanup-and-relocation.json`；旧报告中的原 scratch 绝对路径按该映射解析。

- 最终构件与日志：`a012bdc8/`，保留两个平台安装包、Swift/Rust 全库、生产场景、负控、manifest、CI 凭据和最终校验报告。
- 四张实际窗口截图：`build1002-lifetime-after.png`、`build1002-sevenDay-after.png`、`build1002-today-after.png`、`build1002-tasks-after.png`；对应 OCR 与捕获元数据均保留，汇总为 `build1002-ui-ocr-validation.json`（PASS）。
- 云端子代理绘制：`a012bdc8/visual-previews/compact-running-task-hierarchy.png`，与实际运行窗口截图明确分开。
- 完整回滚 App：`local-install-1002-pi0_vm9r/rollback-build1001/Codex Token Bar.app`；安装记录及诊断实机结果在同一父目录。需要回滚时退出 build 1002，保留它后复制该 App 回 `/Applications/` 并校验签名；不覆盖任何业务数据库。
- 本轮 scratch 目录已移出工作区；三份重复/失败候选下载归档和多余解包 App（合计 380,921,427 字节，约 363 MiB）移到废纸篓 `TokenBar-build1002-temporary-fb0ba20070`，可恢复，未清空废纸篓，故不把它声称为磁盘已释放空间。其他任务 scratch、测试报告、保留兼容性二进制和此前回滚备份均未动。

结论：模型费用清理、主任务标题与紧凑布局已在已安装 build 1002 实机通过；子代理读取与 26pt 布局通过双端测试及云端绘制，真实活跃子代理的安装后观察仍受当时数量为 0 的限制。
