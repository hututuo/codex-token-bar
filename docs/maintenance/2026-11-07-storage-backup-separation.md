# 备份门禁补强与职责拆分

本批承接[存储拆分方案](../design/2026-11-06-storage-decoupling-plan.md)，范围限定为第0步备份验收和第1步备份职责归位。分区导入/导出/复制仍是下一批，旧库接续与整代发布状态机未改。

工作树为`f97f/codex-token-dashboard`，分支为`codex/storage-responsibility-split-20261106`。所有native编译和运行均在GitHub云端完成，本机只进行源码编辑、轻量门禁脚本测试和证据核对；没有运行正式数据库迁移、安装、合并或发布。

## 修改范围

| 提交 | 内容 | 产品影响 |
| --- | --- | --- |
| `711bba80` | 修正失败备份测试，新增相同/不同快照先落位两种场景，并接入真实Rust清理负控 | 只改测试和CI；备份产品实现未变 |
| `6fbcc435` | 修正Windows CRLF日志解析，补正反例 | 只改门禁脚本；不放宽测试条数、失败或必跑项要求 |
| `d2761701` | 将备份实现归位到`business_store_container/backup.rs`，补同源目标拒绝和活跃WAL快照测试 | 纯职责搬迁，方法体、SQL、文件命名、同步及异常处理顺序保持 |

新`backup.rs`共370行，其中原有方法134行、文件操作辅助函数215行，另有原有文件序号静态变量和模块说明/导入。父容器保留目录、proof、导入、旧输入凭据和历史覆盖。公共调用仍为`Container::backup_snapshot`和`ensure_verified_backup`；两个内部方法仅调整为`pub(super)`以维持父模块测试访问，其余辅助函数保持私有。

没有增加数据库、索引、schema版本、writer或事务包装。没有合并`stage_pool_backup.rs`，因为它保护物理A首次结构变更前的整体镜像，协议不同。

## 门禁实际拦截什么

原失败备份测试用旧前缀`codex-token-bar-`找残留，漏掉当前`.tokenbar-backup-…`命名。本次记录构建回调实际拿到的临时路径，并在回调中创建主文件、WAL、SHM、journal；失败后逐个用文件系统元数据确认不存在。读取目录失败也不能再被`filter_map(Result::ok)`吞掉。

竞争场景使用已有构建回调精确安排“最初检查后、临时文件发布前”的目标落位，不依赖线程睡眠：

- 相同逻辑快照先落位：用不同`application_id`制造物理字节不同但业务proof相同的目标，验证它被复用而未被覆盖，临时文件已清理。
- 不同快照先落位：最终目标必须符合预期摘要；被移开的竞争目标字节仍保留，不能把它误当成功，也不能丢弃它。
- 备份目标指向来源：在调用构建回调前拒绝，源文件字节保持。
- 来源仍打开且有已提交WAL内容：备份包含WAL里的最新值，源主文件不被checkpoint改写，目标为DELETE journal模式且不依赖sidecar。

`scripts/check_backup_cleanup_gate.py`在云端执行三次真实Rust测试：正常实现通过；临时替换清理函数后，指定测试必须因临时文件泄漏而失败；恢复原始源码字节后再次通过。只接受退出101、唯一指定测试FAILED、0通过/1失败/0跳过及对应断言消息；编译失败、零测试、无关panic、重复记录都不算成功拦截。日志和源码前后SHA256均保留，故意损坏的实现不提交到产品。

## 验收中遇到的问题与处理

首次有效运行[42243173361](https://github.com/hututuo/codex-token-bar/actions/runs/42243173361)中，macOS通过1793项和清理负控；Windows实际通过1737项、跳过14项、进程退出0，但日志门禁报“Rust execution records do not match the summary”。原Windows日志全部为CRLF，旧Python逐行正则只识别了14条带附加说明的ignored记录，没识别普通ok行。

修复在解析入口把成对CRLF规范为LF，原始日志字节和hash保持；裸CR不会被随意删除。补LF/CRLF的成功、条数错误、失败、重复、必跑项缺失/跳过等对照，本机31项门禁脚本测试通过。原始失败报告未覆盖。新解析器可从原日志精确恢复1737通过/14跳过，但仍重新运行云端，不将离线重解析当成新的完整执行。

修复后的基线[42248193883](https://github.com/hututuo/codex-token-bar/actions/runs/42248193883)最终全部成功。macOS1793通过、Windows1737通过，两端各14项既有opt-in未运行；两端真实生产入口和清理负控通过。首attempt的macOS任务未分配到runner，GitHub注释明确为ARM容量不足；仅重试未完成任务后通过，未修改产品来处理排队故障。

更早的运行42243045990因人工填写了错误source_sha立即取消，不计入验收。之后调度从`git rev-parse HEAD`读取完整提交号。

## 拆分后验证

拆分后的云端运行[42257586290](https://github.com/hututuo/codex-token-bar/actions/runs/42257586290)已全部成功，绑定源码`d27617019cfef52c20efa2010b6f402f1ce1fcc9`。首attempt只有macOS native因ARM runner容量不足而未执行；重试后同一源码通过，其他已成功任务保留。

| 验证范围 | 结果 |
| --- | --- |
| macOS完整Rust库 | 1795通过、0失败、14项既有opt-in未执行 |
| Windows完整Rust库 | 1739通过、0失败、14项既有opt-in未执行 |
| 两端非test生产fixture | 各16场景通过；下载后用完整报告检查器再次核对，包括真实路由、旧数据保全和中断恢复 |
| 两端清理负控 | 都在新`backup.rs`上执行：原实现PASS → 关闭清理FAIL → 恢复PASS；源码前后hash相同 |
| Swift完整库 | 2361通过、37跳过；沿用原opt-in界限，不把跳过算通过 |
| 其他工作流 | 前端、Windows更新器及最终源码身份封存均成功 |

对比基线时逐项核对测试名和结果：每个平台的全部原测试均保留，新增的恰好是同源拒绝和活跃WAL两项，跳过数未变。库日志hash与execution报告一致，云端被测源码均无tracked变化或未登记输入。负控的原始/损坏/恢复三份日志hash和指定泄漏断言均核对通过。

本地整文件核对已通过：由`6fbcc435`提取方法及辅助函数，重建新模块和删减后的父文件，再与实际文本相等比较；仅允许显式导入、模块声明、两处`pub(super)`及两项新增边界测试。原测试代码保持。

本机证据位于：

- `scratch/storage-backup-step0-20261106/`：首轮及重试报告、Windows CRLF失败日志、macOS和Windows负控日志、源身份和调度记录。
- `scratch/storage-backup-split-20261107/`：`verify.mjs`、`equivalence.json`、云端下载材料、最终核对器`validate-cloud.mjs`及`final-validation.json`；Swift日志和`ci-passed/checked-source.json`也保留。

当前没有执行0.9.7–0.9.11全历史producer矩阵或安装版UI验收。这批是备份职责归位的正确性验证，不构成新稳定版发布，也没有性能提速声明。

本批到此收束。三个实现/门禁提交已推送任务分支，未合并到主分支。原有Windows报告修改及其他未跟踪资料保持原状。下一批是已规划的分区导入/导出/复制分离，尚未开始。
