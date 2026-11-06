# 第一批存储职责拆分

用户要求在当前修复基础上做一部分容易验证的解耦。本批基于 `92e85f8f`，分支为 `codex/storage-responsibility-split-20261106`。只做职责归位，不改变数据格式、数据库版本、SQL、错误条件、调用顺序、事务边界或公开调用接口；没有运行正式库迁移、安装或发布。

## 拆了什么

| 原先混在一起的职责 | 现在的位置 | 维护上的变化 |
| --- | --- | --- |
| 通用数据库连接与 Exact 暂存挂载、迁移保留、发布回执 | `business_store_connection.rs` 保留连接、SQL绑定和事务适配；专用行为移到 `business_store_connection/exact.rs` | 连接实现不再夹着约248行Exact业务；以后查看暂存发布合同有单一入口，方法仍使用同一 `StoreConnection` |
| 通用容器中的Rust池身份和版本常量 | 同样移到 `business_store_connection/exact.rs` | 池自身和发布桥接从同一专用模块引用；不复制版本判断，不改变v1/v2兼容或Store ID |
| 容器导入/导出流程与结构、带类型行值、空间摘要计算 | `business_store_container/proof.rs` | 405行只读校验独立，三项入口限父模块可见；不在校验中开连接或管理事务 |

实际新文件为 `tauri-app/src-tauri/src/core/business_store_connection/exact.rs`（271行）及 `tauri-app/src-tauri/src/core/business_store_container/proof.rs`（417行）。原连接文件1112→865行，原容器文件3773→3364行；搬迁248行专用方法、405行proof及6行池合同，共659行，新增文字主要为模块说明和显式导入。

这是模块职责分离，尚未把所有方法改为独立服务，也没有声称所有循环依赖已消除。近2万行的 `exact_usage_index.rs` 中，解析、代次发布和旧schema迁移仍相互关联；本批没有改其调度或事务状态机。这样以后能单独审查连接适配、Exact桥接和proof，而不同时触碰这些更大的执行链。

## 行为保持检查

本轮脚本从固定基线 `92e85f8f` 提取原方法和proof段，与新文件逐字比较。专用方法、SQL、池身份/版本常量、摘要编码、排序和校验分支相同；proof仅三个入口由私有改为 `pub(super)`，供父容器调用。其余父文件内容只允许删除搬迁段、调整导入及模块声明；stage_pool只改变共享合同的导入路径。

新模块显式列出依赖，没有 `use super::*`；未新增全局缓存、writer、trait、动态分派、包装事务、数据库或schema迁移。原测试名称与调用入口保持，不为搬文件增加重复业务测试，使用既有保全与恢复测试核对真实行为。

## 实际验证

- 重新编译当前完整Rust库。首轮1790通过、1失败、14项既有opt-in未执行；唯一失败在未改动的额度进程测试 `quota_stdout_eof_before_response_returns_immediately_with_exit_details`，错误信息未包含预期退出码17。存储、proof、v1/v2及回滚测试均通过。
- 保留旧测试二进制及新二进制各单独交替运行该额度测试10次，20次通过。当前实现收到EOF后先 `try_wait` 再cleanup，静态上允许暂时读不到退出状态；本轮没有进一步证明首轮的具体调度原因，不把单独通过写成额度竞态已修复，也未放宽断言。
- 相同新源码、相同新测试二进制重新执行完整库：**1791通过、0失败、14项原有opt-in未执行**。两轮完整日志均保留，未覆盖首轮FAIL。14项含在线操作及指定历史输入，不能当作已通过。
- 重新构建非test生产fixture，执行原检查器要求的**16个生产场景**全部通过，包含当前版8处中断各3次恢复、旧账保全、只读路由、A/B及真实发布桥接。源文件和二进制hash在运行前后相同。
- 另由保留的 `6101769e` 旧v1二进制制造**8种中断状态**，以本次新构建恢复：24次新版独立重启、8次旧版拒绝v2均通过。job身份、已封存事实、唯一消费回执和134的合成发布结果保持；重复重启及旧版拒绝前后全库所有表行值和结构摘要一致。
- `git diff --check`通过，原有Windows报告修改的hash保持不变。未修改Swift或前端产品代码。

库测试构建使用既有依赖，当前crate设 `profile.test.package."codex-token-bar".debug=0`、`incremental=false`；生产fixture构建对应设 `profile.dev.package."codex-token-bar"` 两项。这些构建用于正确性验证，不与之前正常dev耗时作性能比较。库测试二进制SHA256为 `74e35b5ca8890bbe964dcbfeb6e7922eaca90689156cb42324b2562250c84082`，生产fixture为 `3e0195c21af32bd2fb5a20c69e39acb32609d42887fcc29dbcd2259af1bc48d0`。

本轮新生成的 `.a`/`.rlib` 共576610512字节，在无打开句柄并逐文件SHA256校验后归档成164825677字节的 `rebuilt-libraries.tar.gz`，随后移除这两份中间库；可按归档清单恢复或重编译。可执行文件和全部测试证据保留。只运行小型正确性fixture，空间保护线为512MiB，实际最低约790MiB；没有清理用户数据库、历史材料或其他会话缓存。

## 证据与剩余边界

本机 `scratch/storage-responsibility-split-20261106/`：

- `static-equivalence.json`、`verify.py`：逐段相等、仅搬迁与导入变化的核对。
- `library.log/.execution.json`、`library-retry.log/.execution.json`：首次失败及最终完整库通过。
- `quota-control.json`及20份独立日志：额度单项的旧/新对照，不作为产品修复。
- `production-build.log`、`core/product-core.producer.json/.validation.json`：当前实际生产构建和16场景。
- `cross-version.json`及各阶段日志：旧v1→当前v2中断接续。
- `rebuilt-libraries.archive.json`、`rebuilt-libraries.tar.gz`：两份本轮中间库的可恢复归档。
- `final-verification.json`：最终源码、结果和证据hash。

当前Windows、完整App与安装包未执行；不沿用前版结果冒充本次验收。本次是完成验证的本地结构改进，未证明零bug，也未改变[兼容性复核](2026-11-06-compatibility-chain-review.md)里“池v2不能直接退回旧二进制”和历史producer矩阵的边界。
