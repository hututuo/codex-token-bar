# v0.9.7 升级兼容与性能复验

状态：源码验证完成，测试冻结 SHA 为 `ddd2a350891da9b44e95e17cd7adb093de3e8dc7`。只推代码，不发布安装包、不安装或重启正式版。上一正式发布基线为 `v0.9.7` / `0219554ce444b0013987da7b82e3c2e891f4afdb`。

## 数据门槛

- A 保留 Codex 历史与原有模块，B 保留新客户端与测速；不增加第三个业务库。
- 实际正式版代码生成 schema14 输入，不把当前空库改版本号冒充旧版。
- 对每个来源单独核对旧字段、类型、数值、键、逻辑证明和备份；两个 Home 使用重复会话 UUID 仍必须独立。
- 迁移可重试、硬退出后恢复已提交 WAL、源消失不删旧账、已激活 A 丢失时拒绝用旧输入偷偷重建空账。
- 失败优先保留证据及原文件，不用删除数据库或冷建掩盖失败。

## 本轮修复

1. 最后一格价格：按已闭合桶截止点统一模型和用量，并绑定已发布快照。详见 `2026-10-31-last-bucket-price-jump.md`。
2. B 未来版本：读取现存文件时先只读检查版本及当前版本所需字段，确认兼容后才启用 WAL。未来 DELETE 库、版本号正确但结构不符的库拒绝时保持原字节，不新增 WAL。Rust 原路径已先验版本/表结构，Swift 对齐该规则。
3. 目录别名：发现使用物理路径、所有权使用配置逻辑路径。注册路由按稳定 module/source ID 复用既有 catalog，保留旧路径拼写，不建立另一份 namespace。删除旧文件并改用同根物理拼写重启后仍读 A。
4. 归因连接：现有 owner 锁内的一次同步归因共用短连接，结束关闭。没有跨刷新连接池、没有跨 await 或外包长事务；每次复用验证路由和文件 inode，替换或消失立即拒绝。恢复 gate、IMMEDIATE 事务、FULL 提交及提交后通知不变。
5. 元数据：来源代际、模型补全与覆盖证书放到同一次短只读事务，避免三次 schema 解析，也避免决策搭配不同代际。
6. 首页费用：使用冻结数值输入在 utility 线程派生。单飞执行，仅保留最新待算请求；源/客户端/日期/时区及真实输入修订校验后发布。没有上一客户端的数值占位，也不在主线程内重算终身和近7天价格。

## 可重复测试

`release-upgrade-compatibility.yml` 固定公开 tag，从原代码产生合成的真实旧库格式。测试内容没有用户正文、账号凭据或生产库。

|层|本轮执行内容|完成要求|
|---|---|---|
|Swift|真实旧 schema14 双 Home、quota 完整证明/备份、增量与缺源、中断与变源重试、缺 A、空间不足、硬退出 WAL、旧 JSON→B 幂等|专用 lane 8 项实际通过、0 skip|
|Windows/Rust|真实旧版库生成、3 项导入/恢复测试|专用 lane 显式运行 ignored 输入用例、验证执行计数|
|Windows 生产路径|临时候选副本中注入 feature-gated 探针，非 cfg(test) 运行真实 A/B 路由、crash/resume/reopen/missing-A|固定独占 OS-temp 根，5 个路径覆盖及所有衍生路径开库前验证，不回退默认用户目录|
|通用当前回归|完整 Swift、双平台 Rust、前端、更新器和压力回归|冻结 SHA 云端 CI 全绿|

普通 Rust `cfg(test)` 对 Exact/BodySpeed 路由有绕过，因此没有把普通单测当成生产路径验收。注入仅发生在 CI 临时候选副本，正式 lib/Cargo 入口不改。

新增当前回归还覆盖：未来 B 的字节/sidecar 保留、B 当前版本字段不符、别名+删源+重新启动、连接嵌套/异常清理/不同线程隔离/替换文件拒绝/独立提交，以及费用后台执行、输入合并和旧结果不发布。较早 v0.9.1 验证的当前目标断言从过时的 13 更正为实际 14，未移除历史数据证明。

## 本机只读与有界测量

本机 A 约 655 MiB、15,541 表；B 约 96 MiB、24 表，SQLite `quick_check` 均为 `ok`（分别约6.226、0.988秒）。只读查询，未改生产数据；本机详细结果保留在忽略的 scratch，不上传数据库。

build985 的非受控活跃现场样本确认主线程安全账本开库和费用派生热点。合成576份基础 schema 的三次读基准，逐次重开约123.287ms、同操作共用连接约40.334ms；这是隔离微基准，不是整机加速比例或候选滚动 FPS。新生产 driver 的临时小探针已验证嵌套复用、退出关闭、文件替换拒绝和下一轮新连接。

正式版未替换，未测候选实机滚动/空闲功耗。已知后续项：图表旧 builder 合作取消、隐藏 Windows renderer 轮询、超过60秒的多客户端扫描单飞。这些没有作为本次数据库兼容已过的证据，也没有以降低实际采集量来掩盖开销。

## 云端首轮与修正

`b46a85a9` / `41101247885`：前端1376通过，最后一格的3项原生功能回归通过。Swift唯一失败为旧源码断言仍要求直接调用旧选区入口，现改为要求已发布快照入口。双平台 Rust 唯一失败来自夹具把每条聚合行当作一次请求；现在按原聚合调用数合成确定性数据包，保持所有 Token 和请求数，时间戳明确只用于解析测试，不用作真实速度证据。全部仍须在新的冻结源码下重跑，不把修正未复验写成全绿。

### 5937117b 云端结果

[完整项目检查 41107433402](https://github.com/hututuo/codex-token-bar/actions/runs/41107433402) 已成功，包括新增数据库保护和后台费用派生回归。独立 Sol Max 复审未见可确认 P0/P1，作用域连接的 owner/recovery 锁、独立 IMMEDIATE/FULL 提交、路由/inode 校验和异步发布门均保留。

[正式版升级流程 41107433352](https://github.com/hututuo/codex-token-bar/actions/runs/41107433352)：Mac 8/8、Windows 3/3及非 cfg(test) crash/resume/reopen/missing-A/reopen 全部成功；整个 workflow 最终因 upload-artifact 不能跨 C/D 盘合并证据失败，不能将其写成完整门禁已过。现改为校验独占 temp marker 后将合成证据复制到 workspace 同盘再上传，并对生产探针实际衍生 A/B/Exact 路径补充开库前 containment 检查；需用新 SHA 复验到整个 workflow 成功。

当前生产驱动原文编译的独立7轮合成大库基准：三读分别开连接平均157.885ms，单次操作共用平均40.867ms。数据无用户行、无模块绑定器或应用锁，仅证明驱动路径减少重复 schema 解析；不宣称整体耗电或滚动改善比例。

## 最终验证与交付

冻结 `ddd2a350891da9b44e95e17cd7adb093de3e8dc7`：

- [完整项目 CI 41109771931](https://github.com/hututuo/codex-token-bar/actions/runs/41109771931) 成功。前端1376通过；Swift XCTest 2218项、36项跳过、0失败，Swift Testing665通过；Mac与Windows Rust完整回归及Windows更新器全部成功，Windows Rust1498通过、14项ignored。
- [真实正式版升级 41109771914](https://github.com/hututuo/codex-token-bar/actions/runs/41109771914) 整体成功，双端证据已上传。Mac8项实际执行、0跳过；Windows3个输入依赖用例显式运行、0 ignored；非 cfg(test) 生产探针的 resume/reopen/missing-A/reopen 四阶段全部PASS。普通CI中的这8项/3项输入用例跳过不代替本专用lane结果。
- 根代理已下载双端证据并核对：固定候选/正式版SHA、8项名称及0失败、Windows真实生产路径、两个Home的162/310保留值、B中的旧正文测速、原输入哈希不变、崩溃WAL保留。私有本机核验摘要在 `scratch/release-097-compatibility/verified-cloud-upgrade-evidence.json`，只含合成证明与数值。

代码推送到 `codex/dashboard-header-client-identity`；最终文档提交不修改已测试生产源码。没有更新main、创建tag/GitHub Release、发布appcast、构建安装包或替换正式应用；本机正式版仍是有末格计价问题的build985，修复需后续另行替换才生效。A/B生产库只做了只读检查，没有在本机执行本轮迁移。

实机滚动FPS、空闲功耗和正式安装/回退验收保持未执行，不用本次CI替代。没有用AXScrollToTop/Bottom触发已知macOS27懒列表辅助功能问题，该既有问题不在本轮关闭范围。
