# build 993 首页进度与多客户端发现栏调查

状态：最终源码完整云端 CI、macOS/Windows 打包及所有下载校验已通过；本机安装尝试被系统进程/启动服务异常阻止，尚未替换，恢复后仍需耗时复现与最终安装验收。本文不代表本机修复安装已完成。基线为 `db4e6e42`，安装产品仍为 `9762f754` / 0.9.11 build 993。

## 已确认的事实

用户截图显示准备索引 `0/4311`、读取中和刷新中，同时已有汇总数值。原图保存在 `scratch/user-feedback-20261108/dashboard-issues-20261108.png`。

12:32 对原进程 PID 76255 采集五秒线程栈，主线程仍在正常事件循环；样本没有捕获持续执行中的 Exact 扫描或索引打开栈，不能用这份样本认定此前的耗时点。12:36 取到的窗口截图已经显示「数据更新于 12:35:12 · 图表至 12:35」，读取中和刷新中消失，仍是原进程。因此已排除“本次进程永久不收口”，但尚不能判断前段的最长耗时具体属于哪一步。

采样与现场窗口保存为 `scratch/dashboard-fixes-20261108/build993-hang-sample.txt`、`build993-current-window.png`。

源码中 `loadFromTokenCountJSONLExclusively` 在发现文件后先报告 `.preparing / completed=0 / total=sessionFiles.count`，随后打开/校验/准备索引、核对签名、读取 state 会话标题，最后才进入 `synchronize` 的文件扫描计数。这些前置工作未报告自己的阶段，因此文件计数一直停留在零。顶部「读取中」只检查刷新状态，没有区分已经显示旧统计与首次没有数据。

发现栏的两个直接缺陷：原生 SwiftUI 行缺少其他卡片的 `maxWidth: 980` 限制；Swift `.prefix(1)` 与前端 `.slice(0,1)` 都只保留首个待处理发现项。启用/忽略首项之前，其余发现项不会显示。已启用、已忽略及由专门引导承接的 Claude CLI 仍按既有规则过滤，不自动开启任何客户端。

只读诊断发现当前 A 包含 33,080 个 schema 对象、632 个 `exact.swift` namespace；当前 Home 的 schema 为 14，存在 4,348 个 source、36 组重复 session ID。这些是规模背景，不是该次耗时根因证明；未清理或改写任何数据库。

随后按生产 `CanonicalUsageProjection` 的 UUID 条件复核，36 组重复 ID 均不进入该算法，实际重复 UUID 来源为 0，不能据此认定该投影是热点。有限只读 SELECT 诊断的目录/归因行计数等合计约 0.84 秒，state 标题查询 4,140 行约 0.02 秒；两者均不包含完整原生打开流程、锁、Swift 映射或真实启动竞争，不拿这些数字充当整轮性能。

本机偏好文件中 Antigravity 尚未启用/忽略，Orca 的 Antigravity 数据目录存在，按检测规则应成为待处理项；原来的首项截断使它排在 DeepSeek 后面无法同时看到。这里只读取允许列出的客户端状态，不读取凭据或会话内容。

## 本次源码修正

- 准备阶段不再把发现文件数作为已扫描进度的分母；使用未知总量的进度指示。真实扫描、回填的 completed/total 仍由原执行路径上报，只有完整结果提交后才显示 100%。
- 打开索引增加版本/保护、schema、账本、计费、重复来源投影与保全阶段提示，并接入现有可选 `RefreshPerformanceProbe` 的 `exactIndex.open` 分段记录。未改变 SQL、事务、连接/锁或账本数据处理。实际迁移一旦报告进度，后续普通准备提示不得覆盖未解决的迁移状态。
- 签名核对、会话标题读取、统计/图表读取分别报告实际阶段。已有精确数值时顶部显示「更新中」，提示保留上次可信结果。
- 原生发现栏成为一个居中的最多 980pt 容器；全部待处理项逐行展示，窄宽度可将按钮移到下一行。每项启用/忽略仍独立。前端移除同样的首项截断。

## 新增验证与边界

本轮回归：

1. Swift 实际 loader 的首次/再次读取：输入 120 tokens，两轮保留总数、完成流与最终 complete；准备阶段无伪造文件分母，源文件字节不变。
2. Swift 原生发现栏渲染：360 / 872 / 1404pt 三种容器、单项/三项，验证居中和 980pt 上限、三项高度与不自动启用；云端输出 PNG 供人工查看。
3. 前端实际发现组件交互：已启用、已忽略和 Claude CLI 正确过滤；多个其余项同时显示，忽略中间项和启用最后项不会改变其它项。
4. 既有未完成迁移用例保留原分母、计数和不假完成断言，并要求迁移开始后不能退回普通准备提示。

CI 已将两项新 Swift 用例列为必须实际执行，并收集原生预览。遵守用户要求，没有本机编译或测试。统计加载状态机本身未做推测性改写，仍需云端完整回归及本机诊断。

首轮源码 `319f30df646c87d2dbe2616802aaf30d93306b9a`：前端 1,438/1,438、cloud scripts 18/18 通过，零跳过；新实际首次/再次读取用例通过。Swift 2,424 项执行、38 跳过，只有新原生布局测试失败（6 组×3 尺寸断言共 18 次），原生截图已生成并确认三个宽度全部展示三项、宽窗口居中且最大 980pt、窄窗口按钮换行。失败来自测试 PreferenceKey 回调未写入测量值，全为 0。

`e85c24f6a8e48e31b26281afefb483aed18e93ae` 仅将测试测量改为真实背景 NSView 的转换后 bounds，未修改产品，也未移除宽度/居中/高度断言。首轮 CI `42448637787`、打包 `42448678525` 的原始失败材料保留在 `scratch/dashboard-fixes-20261108/cloud-319f30df/`；剩余旧任务停止，避免阻塞新 SHA。

当前完整 CI：[42449658329](https://github.com/hututuo/codex-token-bar/actions/runs/42449658329)；同 SHA build 994 云端打包：[42449678755](https://github.com/hututuo/codex-token-bar/actions/runs/42449678755)。产品改动没有 Rust 或数据库 SQL/事务变化；本轮完整门禁仍包含双平台 Rust、各 16 生产场景及两类负控，不重跑未改动的四版本 Rust 历史矩阵。

第二轮 Swift 2,386 通过、38 原有跳过、零失败，两项新增必跑回归通过，前端 1,438 通过。但收尾静态复审发现：普通打开提示也会进入 `loadCompactSummary`，而该路径只为迁移/回填发送终止提示，普通准备提示可能在轻量成功后遗留。因此进一步限定 compact 路径不转发 `.preparing`（保留其原有迁移、回填与完成提示），并在实际冷/暖 loader 测试后增加 compact 成功无准备提示残留的断言。该修正需要第三轮最终 SHA 验证，不能沿用第二轮通过状态安装。

### 最终 SHA 的独立门禁结果

最终源码 `ee1746bfc7c99d5d165440380e702838c9676e2e` 已推送任务分支。[完整 CI 42450845402](https://github.com/hututuo/codex-token-bar/actions/runs/42450845402) 为 success；原始日志、源码前后封印、测试身份、必跑用例、生产报告和负控已经本地重新解析验证，汇总为 `scratch/dashboard-fixes-20261108/cloud-ee1746bf/native-validation.json`。

| 项目 | 最终 SHA 实际结果 |
| --- | --- |
| Swift XCTest | 2,386 通过 / 38 原有跳过 / 0 失败 |
| AgentSpeed Swift Testing | 674 项 / 79 suites 通过 |
| macOS Rust | 1,811 通过 / 14 ignored / 0 失败 |
| Windows Rust | 1,755 通过 / 14 ignored / 0 失败 |
| 前端 | 1,438 通过 / 0 跳过 / 0 失败 |
| Cloud / release scripts | 18 通过；111 通过 / 1 原有跳过 |
| 生产场景 | 两端各 16 个，通过且原始输出与报告一致 |
| 备份负控 | 两端正常/关闭保护/恢复保护为 0/101/0，关闭时确实因回收保护缺失失败 |
| 物理 A 替换负控 | 两端正常/关闭保护/恢复保护为 0/1/0，六个入口保持保护，源码恢复 hash 一致 |
| 新增真实 loader 和原生布局 | 均实际执行并通过；compact 防残留断言也包含在最终用例内 |

最终原生预览 `visual-previews/discovery-{360,872,1404}-{1,3}.png` 六份已生成；人工复看窄/宽三项图，内容和按钮完整，1404pt 容器内发现栏居中且宽度为 980pt。此为云端生产 View 渲染证据，与本机最终窗口验收分开。

[最终打包 42450846688](https://github.com/hututuo/codex-token-bar/actions/runs/42450846688) 的 macOS job success。App ZIP SHA-256 `fd284607392929ebf36e0d517a292b726a889c21b9c8cbcb85ed902bcb39333b`，可执行文件 SHA-256 `587c09ee14f7453a8953b5b4997b031129f13e60695cc732273c14c9e30962f8`。版本 0.9.11/build 994/arm64，`codesign --verify --deep --strict` 通过，指定签名要求、bundle ID、Sparkle feed/key 与已安装版一致。按既有策略为 ad-hoc，未 Apple 公证。已解压候选位于同一证据目录的 `unpacked/Codex Token Bar.app`，尚未替换本机。

最终整个打包 workflow 已为 success；Windows x64/arm64 安装包也已下载并通过 manifest/资产 hash 校验。macOS DMG 经 `hdiutil verify` 完整性检查通过。`validate_cloud.py` 重读全部最终原始证据后返回 PASS，`final-validation.json` SHA-256 为 `c1e4309c89a0bdfb0ebc3b99e086a404b1817df0eaaf5b3bcd0f4e069b98b14b`。旧轮次材料不参与最终成功判定。

## 当前阻塞与安装状态

为测量原版真实启动耗时，在保留现场后正常退出 build 993，准备使用既有环境开关启用诊断。此时 macOS 图形服务发生重启（新 WindowServer / loginwindow 约从 12:37 起运行），本机用户服务查询不可用：`id -un` 仅返回 UID 501，Directory Service 返回 `eServerError`，`launchctl print gui/501` 返回 `141: Reentrancy avoided`。启动服务返回 `-10827 / kLSNoExecutableErr`；直接启动也未成功，尚未产生新的诊断 trace。没有证据将系统服务异常归因于产品代码。

同时普通 `gh` 无法连接 GitHub，`curl https://api.github.com` 返回 `Could not resolve host`。改用 Go DNS 后又因系统证书服务不可用返回 `OSStatus -26276`。后续交叉检查发现 Node 的标准 HTTPS（保持证书校验）仍可访问 GitHub API；可以通过该路径继续云端流程。未修改网络/用户服务配置，也未绕过项目云端规则运行本地测试。本机启动仍被系统服务故障阻塞。

安装目录仍完整保留 build 993，可执行文件 SHA-256 复核为 `c785588982bac565ebe6d4c0db2dd1d9743792f60c2f4248f699da9d59a8435d`，签名检查通过。诊断重启未成功后，约 13:00 观察到新的 App 进程 PID 16493，未携带本轮 probe 日志；没有证据说明由哪个启动者恢复。再次采样没有捕获 Exact 索引耗时栈。当前工具仍不能访问该 GUI 会话或启动系统辅助功能进程，不能声称第二次窗口或耗时验收完成。未替换为本轮尚未验证的新代码。此前 build 992 回滚副本仍保留在上次安装记录所指目录。

全部云端门禁通过后，14:03 执行本轮安装脚本。App/签名/hash/版本预检查通过，AppleScript 退出请求返回后，`pgrep` 返回退出码 3：`sysmon request failed with error: sysmond service not found; pgrep: Cannot get process list`，安装脚本在任何目录移动之前停止。`ps` 仍能看到 PID 16493，安装版本仍为 993、可执行文件 hash 未变。随后 `open` 仍返回 `-10827`。这不是签名或云端构建失败，不能通过强制覆盖正在运行的文件来宣称完成安装。脚本补充了当前用户解析和进程服务的先行检查，服务恢复后才会退出旧 App、建立唯一 build 993 回滚目录并替换。

本轮没有删除用户数据库、会话或旧 App，也没有生成新的正式回滚目录（安装尚未到该阶段）。用户已授权安装，当前缺的是可工作的本机桌面/工具连接，而非再次授权。

## 恢复后的完整收尾

1. 桌面登录/系统服务恢复后，先启动现有 build 993，启用 `CODEX_TOKEN_BAR_REFRESH_PROBE=1`，日志限定在本轮 scratch；采集准备阶段对应的真实调用栈和时长。若原版无法给出足够细分，使用已通过云端验证的新候选分段诊断，不能仅凭显示修正宣称耗时根因已解决。
2. 如发现真实热点，按证据做最小修复并加相应回归；不清空历史、不放松保护或用计时器伪造完成。
3. 推送任务分支，在最终 SHA 上执行完整云端 Swift/前端/双端 Rust、生产场景及既有负控；检查新增用例实际执行、预览 PNG 与原始报告。涉及历史/数据库行为变化时补相应历史兼容矩阵。
4. 云端 `prepare-release.yml` 使用同一最终 SHA、递增 build（预定 994，执行前复核）、既有 AgentSpeed reviewed pin 与理由。校验产物 manifest/hash/签名/版本。
5. 保留唯一命名的 build 993 回滚副本，替换 `/Applications/Codex Token Bar.app`，重启并实测准备→扫描/读取→完成以及发现栏实际宽度/多项显示。只有此后才能宣告本轮完成。

用户已授权本轮修复、云端执行和本机替换；恢复后不需要再次询问安装许可。未授权也未执行 main 合并、Release/tag/appcast 发布或数据库清理。
