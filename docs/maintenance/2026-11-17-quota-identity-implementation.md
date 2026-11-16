# 多客户端额度兼容补充

状态：代码`b0ee81ef08f7df4c6a46f0dde346a16571bc5513`已通过全量云端检查；0.9.11/build1023已于2026-11-17 04:12:04（北京时间）安装并完成本机真实数据验收。Windows双架构候选与来源清单校验通过，[同机性能对照](2026-11-17-daily-projection-performance.md)亦已完成。

## 行为

Claude Desktop从既有本地历史和HTTP缓存中的组织字段生成SHA256，追加到既有source键。各组织的额度条继续显示最新一次本地观测；曲线和热力图只选对应组织的历史。旧无身份记录仍在原表原位置，作为独立历史入口。新组织没有有效额度时保持空白，不回退到其他组织。来源切换后可导入新的本地组织历史，仍保留原观测时间。

Swift、Rust共享组织标识fixture；TypeScript核对“新组织无读数、旧组织有历史”时的空白和显式选择行为。组织字段不是用户级认证证明，界面继续说明未验证当前账号。没有更改数据库版本、表结构或将原文组织ID写入账本。

同时将热力图的额度来源/周期独立成行，隐藏重复的“周期”标签，保留完整来源名称和5小时/7天按钮。

## 缺少额度提供者的调查

见[本地额度来源取证](2026-11-17-local-quota-provider-evidence.md)。Gemini CLI仅核实到内存额度和远端读取；DSH为充值余额远端查询；OpenCode没有已核实的通用本地额度。三者仍保留用量、费用、模型、缓存模式和无额度来源说明，不猜造5h/7d。

## 兼容与验收

原build1022全量测试、安装和真实数据点验记录见[第一包记录](2026-11-17-multiclient-heatmap-implementation.md)。本包追加组织切换、旧历史保留与相同哈希样例。安装时另验原用量修订、Codex额度快照及原外部额度来源历史摘要；原App保留回退。

最终源码的全量检查[`43942074963`](https://github.com/hututuo/codex-token-bar/actions/runs/43942074963)已全部通过：Swift XCTest2528项（38项既有跳过、0失败）、Swift Testing676项；前端1491项；macOS Rust1857项、Windows Rust1800项（各14项既有忽略、0失败）。更新器检查与源码证据封存通过。新增组织切换、哈希一致、新组织空白及旧行保留测试通过。

候选：[`43942083419`](https://github.com/hututuo/codex-token-bar/actions/runs/43942083419)的macOS、Windows x64/ARM64、来源清单核验和汇总均成功。编译、测试、打包继续云端执行；Windows实机暂无设备证据。没有公开发布或修改更新源。

## build1023本机验收

安装位置`/Applications/Codex Token Bar.app`；可执行文件SHA-256为`765d722d2418a81df0f1f28927744b5e92b27fe8b825615bd48a9510a054c0dd`。来源清单、ZIP路径/符号链接、签名、资源和DMG均通过核验；build1022正常退出并保留在本次证据目录的`rollback-build1022/Codex Token Bar.app`。

运行诊断证明startup.ready、index.ready、refresh.completed（numeric_ready/detail_ready均为1）及refresh.ready；安装确认事件的attempt与本次替换一致。04:22再次核验的主进程为84229，版本与二进制摘要匹配。

真实界面检查：

- Claude当前组织的5h为11%、7d为0%；热力图显示4次有效样本、04:10–04:16的时间范围。
- 旧未分组织的历史仍可显式选择，5h日均14.86%/28次，7d日均9.8%/30次；没有拼入新来源的均值。
- 完整来源标签与横排5小时/7天控件正常；原“周期”竖排问题已修复。
- 汇总页Antigravity四窗口分别为97.42%、81.6%、100%、100%，保留两池和小数。
- 完成后已实际确认热力图恢复跟随主页、每日模式、当前额度来源，主页恢复汇总。

安装前后两库inode、schema、user_version一致，quick_check均为ok；26,822条client_usage_revisions与55,896条quota_snapshots的原行完整内容摘要一致。外部额度核对原三个来源在安装前10分钟截止线以内的3,081条采样，行数与内容摘要一致；截止线排除正在增长的尾部。新组织历史导入另记新来源，没有重写旧行。未复制真实数据库。

证据目录：`~/Library/Application Support/CodexTokenBar-Maintenance/2026-11-17-quota-source-identity/`，含`installation.json`、`database-before.json`、`database-after.json`、`runtime-verification.json`、全量测试日志和候选清单。

## 已知边界

Claude组织隔离不等于同一组织内不同用户的认证账号隔离。Claude CLI与Antigravity现有本地契约没有稳定用户ID，继续如实显示未验证状态；本次没有新增认证或对外额度请求。旧本地历史与HTTP缓存的未分组织入口都保留，其名称相同但source键独立。Windows已做云端编译/测试，尚无Windows实机证据。
