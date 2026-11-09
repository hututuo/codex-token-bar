# 多客户端折线图完整接入与按渠道分组

## 实机调查

安装基线为 build 1006 / `1f1db01f`。Swift 与 Tauri 均已复用原 `RecentUsageChart`，不存在另一套简化的 Antigravity 绘图组件。新客户端适配此前接通了 Token/请求/缓存，但没有接通逐时间桶金额：外部客户端金额禁用，混合范围金额仍只取 Codex。

本机只读查询证实 Antigravity 近24小时约6.39亿 Token，Claude Desktop 约0.68亿。实际 AX 界面 Antigravity 显示6.4亿，汇总14.2亿；Token 已有聚合，不能把“金额仍是 Codex”误报为所有 Token 均未汇总。修复将剩余金额管线接通，并加入全部客户端逐桶守恒测试。

另一个边界在共享图表的初始化：横向文档短暂具有正但尚未完成的宽度时，旧逻辑会把期望最新位置截断到该临时宽度并提前标为完成。切换客户端历史长度后可停在错误历史窗口，影响可见区缩放和裁剪。双端继续使用原图表的布局、坐标、自动缩放、hover、选区与翻页，只在初始定位等待完整期望宽度；不覆盖后续用户手动翻阅。

## 修改合同

- Swift ledger 的价格读取函数同时服务 summary 与 trend；在同一只读事务中合并 Token 与逐请求已核算价格。Rust 同样复用 `api_cost_micro_usd_at`，保留现有 aggregate 事务和按 revision/minute 的缓存。时间桶新增内存/IPC 价格与未定价请求字段，不建表、不迁移、不改原始账目。旧 IPC 缺少字段仍可解码，缺失价格不伪造0。
- 将已核算的价格按5分钟/小时/6小时接进原图表的价格数组，复用原自动缩放、点线与预览。汇总金额为 Codex + 其他所选客户端；存在未知请求时显示“已知金额”，全未知显示未报告。额度与额度反推仍绑定 Codex 来源，外部客户端不套用 Codex 额度或回退单价。
- `Argon4` 放最新主力第一位。Antigravity 的其他模型（包括 Opus/Sonnet/Haiku）归第二组“Gemini · Antigravity”；最新 Claude 5.5 的原生渠道仍在第一组。同名来源ID和费用不合并、不重算。四列、30pt、稀疏组四槽位保持。
- 共享排序 fixture 同时覆盖原生/Antigravity 同名 Opus5.5、Sonnet5.5、Sonnet5、旧Opus和Argon例外，所有输入顺序下保留相同账目。新增 Swift/Rust 逐请求价格守恒，Swift/TS 原图准备和渲染管线守恒、正但不完整滚动宽度负控。

## 验证范围

本机仅源码、JSON/脚本语法检查、只读诊断和真实应用观察；无本机 cargo/swift/frontend 构建。最终候选已通过云端门禁并安装，详情见后文。上轮 build1006 的滚动性能尚无有效同条件后测，本轮不能借其安装成功宣称所有滚动卡顿已消除。

## 运行中主 Agent 数量专项

2026-11-09 13:30 UTC 只读检查：最近24小时数据库候选中有9条最新生命周期仍为 `task_started`，其中7条为 `codex_exec`，已停写约3～24小时；其尾部为工具结果、reasoning或token_count，没有 `task_complete`。本机当前 Codex 进程均未持有这些 rollout 的打开句柄。它们是中断退出后遗留的运行态，并非7个正在执行的工作。用户报告12个是当时界面值；这次快照不能倒推全部12个的客户端构成。后续旧版主页现场显示7个，说明24小时候选到期和真实任务变更也会改变数量。

旧逻辑在24小时内只看最后一个开始/结束事件，进程消失不参与判断。新逻辑保留24小时候选发现及原生命周期缓存，显示投影另加5分钟静默检查：文件近期推进仍有效；长时间静默必须存在该rollout的真实写入句柄。macOS一次枚举Codex进程的内核FD，以设备/inode及FWRITE匹配，不扫描每条会话的全部进程，也不启动lsof或app-server。Windows复用项目已有的只读共享模式探测合同。终止事件始终优先，单独持有writer-lock、读句柄、打开的空闲会话不复活为运行；观察失败进入已有stale/unavailable分支，不发布伪造零。

数据库`thread_source`/嵌套subagent来源现在参与分类，补齐旧rollout缺少标记的场景；普通fork、attached side chat不凭父ID改为子Agent。投影过滤不改rollout、不改SQLite、不改真实生命周期缓存，后续恢复写入可以重新计入。

新增双端回归覆盖：退出但无结束事件、长时间静默仍有writer、完成后仍持句柄、恢复写入、权限失败、数据库子代理标记、普通fork及真实内核读/写/锁句柄负控。5分钟是缺少终止信号时的最大近期活动宽限，不表示能够从本地日志准确识别网络重试、等待批准等全部远端状态。

首候选`fd3c1a58`云端发现Swift复杂类型推导超时，已将聚合拆为显式类型步骤；TS旧断言仍要求汇总金额标签为Codex，现改为检查全客户端已知金额及缺失价格。两项均在合并候选重新走完整门禁，不安装失败候选。

15:19 UTC 再次用本机44个近期rollout与内核FD交叉核查：旧判定为主7/子0，新判定为主1/子0；6条退出的exec被排除。一个已完成主任务和两个已完成子Agent仍有真实写句柄，但结束事件优先，均未计入。该结果是定时快照，并非把运行数固定为1。独立诊断脚本枚举内核FD约131ms，之前同口径一次约44ms；产品位于后台扫描，只在存在静默候选时一次读取，不应将其描述成UI主线程耗时。

本轮新增Swift夹具曾遗漏`daily`参数，Windows测试还曾依赖写句柄关闭前立即更新mtime。分别在`dd4cec90`、`8abaec42`修正。`8abaec42`产品测试已通过：Swift XCTest 2476执行/38原有跳过/0失败，Swift Testing 676；macOS Rust1828通过。CI随后npm下载`undici-types`失败，Windows Public097下载`ws`连续500/502，均未进入相关后续检查。

`dcf9184a`仅修改云端npm传输：对`registry.npmmirror.com`使用npm原生`--replace-registry-host`重定向到官方源，不改任何lockfile、版本、integrity或历史生产源码。两个故障包的官方源字节已与原锁定integrity核对一致。该提交与`8abaec42`的产品源码及单测完全相同，仍在最终提交上重新运行完整CI与打包。

## 最终候选与云端门禁

产品源码为 `dcf9184ad7bfa282ef364b2a9f72f142251054e6`，版本0.9.11/build1007。`9974a670`的修复包含在此候选中；后续修正测试夹具和npm下载路径，没有撤回运行态、图表或模型分组修复。

| 最终 SHA 的检查 | 结果 |
| --- | --- |
| [完整 CI 42648172101](https://github.com/hututuo/codex-token-bar/actions/runs/42648172101) | 全部 job completed/success |
| Swift | XCTest 2438通过、38原有跳过；Swift Testing 676通过 |
| Rust | macOS 1828通过、Windows 1771通过；各14原有ignore |
| 前端 / 云端脚本 / 发布脚本 | 1457 / 18 / 112通过；发布脚本1原有跳过 |
| 生产路径 | 双平台各16个场景；备份负控退出码0/101/0；物理A替换负控0/1/0，各6个入口 |
| [Public097 42648172070](https://github.com/hututuo/codex-token-bar/actions/runs/42648172070) | 双平台通过；Swift升级8项与支持测试105项、Rust升级3项、4个生产阶段及19个manifest场景 |
| [打包 42648209361](https://github.com/hututuo/codex-token-bar/actions/runs/42648209361) | macOS ARM64、Windows x64/ARM64全部成功 |

原有兼容性测试仍在最终运行中执行。诊断采集器的只读、独占锁、敏感诱饵和既有输出保护负控也在两个平台通过。按manifest的source SHA、构件大小与SHA256、日志hash及执行结果核验，证据保存在 `scratch/chart-aggregation-20261109/dcf9184a/final-validation.json`。这份文件是安装前门禁，安装后证据单独保存，不回写伪造安装前状态。

所有构件均已下载核验，包括macOS app.zip/DMG和两个Windows安装器。macOS app.zip SHA256为 `8036f02925fe8875c7d48bcd804fb3cd71872e1bd6419bad69045826a80bea5b`。本次为本机候选安装，保持项目既有ad-hoc签名政策；未公证、未发布release/tag或更新appcast。

## 本机安装与首次刷新

2026-11-10 00:27:56（北京时间）替换 `/Applications/Codex Token Bar.app`，确认build1007，进程PID14399正常运行。安装后可执行文件SHA256为 `22dd9f96b4b22bda281c63774a68041181420aab673737572f6549d57972da2f`，与已核验云端产物一致。

上一版build1006完整保存在：

```text
scratch/chart-aggregation-20261109/local-install-1007-ehc55rda/rollback-build1006/Codex Token Bar.app
```

该目录的 `installation.json` 记录新旧二进制hash、备份校验和安装attempt。`runtime-validation.json` 为 `PASS_INSTALLED_RUNTIME`：首次刷新约46秒完成，4376个文件完成、pending为0、schema14、published generation27212；后端完成时间与UI收到完成时间分开核对，安装确认绑定同一build/PID/attempt。精确统计指示器正常收口。

诊断ZIP仍有一个既有边界：6000条事件上限会遗漏此次启动所在的最新会话。本次以持久化脱敏journal直接核对当前进程与安装attempt，不能声称该ZIP包含完整本轮时间线；此问题独立于本批三项修复。

## 实机验收：模型表、图表与运行计数

截图均来自运行中的已安装build1007；未用预览或测试数据替代。原始截图、捕获时间、窗口ID、SHA256及OCR结果留在 `scratch/chart-aggregation-20261109/`，含会话内容的整窗截图不提交到仓库。

### 模型费用表

`build1007-today.png`、`build1007-sevenDay.png`、`build1007-lifetime.png` 三周期已人工查看，`build1007-ui-validation.json`通过：

- Argon4位于“最新主力”首位；原生Opus5.5/Sonnet5.5/Haiku5.5仍在该组。
- Antigravity的Opus5.5位于“Gemini · Antigravity”，未与原生同名条目混为一条。
- 保持每行4槽位、单行30pt；今日实际3个模型并保留第4个空槽，不生成假账目。
- 未出现“价格未知”、Flash路由后缀或零用量Fable占位；近7天/累计的未知模型仅一张末尾卡片，名称完整。今日无未知用量，因此不生成未知卡。
- 本机没有Antigravity Sonnet实际记录；Sonnet5.5/Sonnet5的渠道分组由双端共享fixture验证，不把它写成实机截图结果。

### 24h / 7d / 30d 折线图

实际切换“汇总”、Codex、Antigravity、Claude Desktop，各完成三个周期，共12个组合。截图文件为 `build1007-chart-{all,codex,antigravity,claude-desktop}-{24h,7d,30d}.png`。所有组合均显示所选客户端、对应时间窗、Token/调用/命中率/金额，非空客户端曲线可见；切换历史长度后最新窗口定位及原有缩放/坐标管线正常。

`build1007-chart-validation.json`校验12张截图的捕获回执与hash；Antigravity 7d的OCR漏识别客户端和部分图例，已直接查看原图确认Antigravity、12.6亿、9166调用、93%与$369，未将漏识别标成自动通过。`build1007-chart-contact-sheet.png`提供去除会话排行区域后的12图对照，已逐图人工查看。

| 界面快照 | 24h Token | 7d Token | 30d Token |
| --- | ---: | ---: | ---: |
| 汇总 | 14.8亿 | 62.9亿 | 222.9亿 |
| Codex | 7.3亿 | 40.8亿 | 200.7亿 |
| Antigravity | 6.4亿 | 12.6亿 | 12.7亿 |
| Claude Desktop | 1.1亿 | 9.5亿 | 9.5亿 |

这些是依次抓取的动态滚动窗口显示值，不是冻结同一时刻的精确SQL对账。7d/30d显示值可见汇总包含其他客户端，不能再解释为仅Codex。逐桶Token/调用/价格的严格守恒由云端回归测试证明。24h留存截图汇总金额约$1511，Antigravity为$160（较早的界面观察为$162）；外部客户端金额已接入图表。30d Antigravity显示“已知金额$373”，忠实保留历史未定价请求边界，不伪装完整报价。

### 主 Agent / 子 Agent

安装后00:28:47快照：旧规则主8/子0，新规则主2/子0；主页实机显示“运行2 · 主2 · 子0”，与该时点只读rollout/内核FD证据一致。00:55:40再次采样为旧主9/子0、新主3/子0，仍排除同6条历史exec；采样无权限错误。展开侧栏也留有主4/子0及后续详情底部主2/子0的截图。侧栏当时为全客户端“汇总”，而只读脚本针对Codex；数量还随真实任务开始/完成变化，因此不能把不同来源、不同分钟的数值直接相减当作误差或严格一致性的证明。

已完成但仍被app-server持有写句柄的主/子会话没有复活为运行。截图中没有真实运行中的子Agent，因此本机验收证明子0正确；活跃子Agent与普通fork的分类由双端回归覆盖，未人为启动任务来制造截图。

本批结论限于：排除已退出且长期停写的孤立运行态、按真实身份分类、全客户端图表和渠道分组。5分钟近期活动宽限与远端等待状态的可观测性限制仍存在；Windows完成云端全量测试和双架构产物校验，未声称执行Windows实体机GUI验收。全局滚动性能A/B与诊断事件上限仍是独立后续事项。
