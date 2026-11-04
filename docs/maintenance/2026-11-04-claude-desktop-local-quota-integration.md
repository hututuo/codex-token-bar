# Claude Desktop 本地历史额度接入

## 范围

接入官方 Desktop 已写入的 `plan-usage-history.json`，不添加额度请求、后台唤醒、菜单点击、隐藏网页、CLI `/usage` 或 `get_usage` 调用。不读凭据，不修改 Claude 配置。Claude CLI 原有 statusLine 采集保持独立，仍需用户自己启用；本次不自动安装采集脚本。

Swift 与 Rust 使用同样的解析与过期规则，跨平台 UI 沿用现有额度组件。没有数据库文件、表、字段、schema 或账目迁移变化；不改变用量、计价、测速或上报。

## 本地读取

- Mac：`~/Library/Application Support/Claude/plan-usage-history.json`。
- Windows：`%APPDATA%/Claude/plan-usage-history.json`，没有 APPDATA 时退到当前用户 AppData/Roaming。
- Rust/Linux：只尝试已有的 `~/.config/Claude/plan-usage-history.json`，不声称存在官方 Linux 客户端。
- 仅读取这些已知位置的普通文件；拒绝符号链接，大小上限 4 MiB，样本数上限 50,000。
- 复用现有每分钟的额度探测。Swift 在原有后台任务内读取两份独立来源；Rust 复用有 60 秒缓存的本地探测方式，不新增轮询定时器。

## 数据规则

- 只接受明确声明的 version 1、2：v2 为 samples[].{t,org,u.{fh,sd}}；v1 为 samples[].{t,fh,sd}。不猜测未知版本。
- t 为原采样的 Unix 毫秒时间，不使用文件修改时间冒充采样时间。
- 选择最新数值时间戳的完整“行”；乱序文件仍可读取。相同时间戳取后到行。
- fh/sd 为 5h/7d 已用百分比，分别要求有限数值且在 0…100 内；布尔、字符串或越界值不作百分比。
- 新行缺少某个窗口时保持缺少，不能从旧行、另一组织或 CLI 拼字段。最新行没有窗口时也不退回更老的有效值。
- 最新采样比当前时间超前超过 60 秒则无效；超过 20 分钟则过期。20 分钟是本产品的显示策略，为正常 15 分钟轮询保留余量，并非官方实时性保证。
- 源文件没有重置时间，窗口 resetsAt 保持空；不根据下降、固定星期或旧 HTTP 缓存推算重置时刻。
- org 标识仅随原 JSON 解析存在于内存，不输出到 provider、界面、日志、IPC、数据库或上报；也不声称最新行已经验证为当前账号。

## 展示与兼容

- Desktop provider 使用 `claudeDesktop` 和 `local-desktop-history`；CLI 继续使用 `claudeCode` 和 `local-statusline`。
- 两个客户端有不同的额度项 ID，不把 CLI 额度冒充 Desktop，也不合并或相加账号额度。
- 新增可选 capturedAt，详情显示采样时间，过期显示明确提示；既有快照没有该字段仍能读取。
- 只把有效读数放进现有额度环/条和客户端范围；没有数据时沿用未接入/不可用行为，不新增独立大卡。
- 额度读取不要求启用会话用量收集；不会因发现额度就打开 Token 扫描。用量库读取失败时，两个独立的只读额度命令仍可返回数据。
- 原来将 CLI 的额度在 Desktop 范围中复用的显示别名已取消。Windows provider 的窗口标签统一为现有 UI 所需的 5h/7d，与 Swift 一致。
- 本次没有连接 HTTP 磁盘缓存作为另一套 provider，避免未经账号证明地把它的重置时间混入历史采样。

## 验证

- 相关前端三份文件 22 项测试通过，TypeScript 类型检查通过。
- 实际 Swift 额度源文件及 provider 提取到独立最小测试包后，Desktop 历史和旧 CLI 本地额度 10 项测试通过；这不替代完整应用编译。
- 新增双端用例覆盖：v1/v2、乱序/同时间戳、组织切换后部分字段、空/损坏/过大文件、未来时间、20 分钟边界、布尔/非法百分比、未知版本、符号链接，以及源文件不被改写。
- 前端覆盖 Desktop 独立身份、缺少重置时间、采样时间展示、过期不显示百分比、索引不可用时仍能读取两个额度来源。
- Swift store 覆盖用量库不可用/收集未启用时仍显示 Desktop 额度，且不冒充 CLI、不产生重复探测。
- 完整模块定向云端检查结果待记录。不运行全量升级、规模或安装包测试；不安装、不替换正式版。

更新触发机制和证据见 [额度更新核查](2026-11-04-claude-quota-refresh-investigation.md)。
