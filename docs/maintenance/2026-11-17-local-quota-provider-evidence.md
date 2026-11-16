# 本地额度来源取证与组织隔离

状态：2026-11-17，build 1022已安装；本文件记录后续兼容补充，不把调查结论冒充新增额度来源。

## Claude Desktop

实际本地`plan-usage-history.json`为version2、80条样本，存在org字段，本次只有一个组织。HTTP Simple Cache的官方usage地址也包含组织标识。解析这些已读取字节即可提取身份，不读凭据、不启动客户端查询。

新读取按`客户端 + 原来源 + 组织SHA256 + 窗口`保留历史，复用原source列，不迁移schema；组织原文不进入Token Bar账本。Swift/Rust共用fixture验证相同哈希。组织不是已验证登录账号，界面继续保留“未验证当前账号”；历史来源显示“独立组织”或“身份未验证”。旧行不回填，不重写。新组织没有有效样本时不借用旧组织余额。组织变化会重读现有本地历史文件，新旧组织不会合并成连续额度。

局限：同一组织内多个用户可能共享组织标识，单凭org不能证明用户身份；只按确有证据的组织边界隔离。Claude CLI statusLine及Antigravity的当前额度响应没有在既有契约中提供稳定用户身份，仍保留未验证状态，不能虚称完成用户级隔离。

## 其他三个客户端

| 客户端 | 本机与源码证据 | 本次结论 |
| --- | --- | --- |
| Gemini CLI | 本机未发现gemini可执行文件或`.gemini/tmp`、`.cache/.gemini/tmp`会话路径。官方源码`4fa64e71b9b4e1bb65a86cc2863574f561b82340`中`config.ts`的lastRetrievedQuota/modelQuotas为进程内状态；refreshUserQuota调用CodeAssistServer.retrieveUserQuota，server.ts通过requestPost向服务获取 | 尚未找到符合离线边界的官方磁盘缓存。保留用量解析器，额度显示缺少来源；不自动调用远端或启动CLI |
| DeepSeek DSH | 本机`@deepseek-ai/dsh`版本0.2.1-rc.5。dsh-deepseek-account定义CNY/USD钱包余额；account-platform的getBalance调用getDetail，details.ts/js通过`/api/v0/users/get_user_summary`发起账户请求 | 余额不是5h/7d订阅额度。未找到已落盘、带时间与周期的额度缓存，不把钱包余额或Token换算成百分比 |
| OpenCode | 本机`~/.local/share/opencode/opencode.db`存在，schema含会话、消息、part、账号等表，没有额度/余额字段；本次message/part表没有可用样本。官方源码`7745079647b65036fe142e09ccd8623b25be1878`的`packages/schema/src/session.ts`及`v1/session.ts`提供用量/费用结构；没有核实到通用的本地订阅额度契约 | 软件可连接不同provider，不能假定同一种限额。保持用量入口，额度显示无本地提供者；已有云端用量/旧库样例继续覆盖 |

这些是“本次没有找到可靠来源”，并非证明所有版本或插件永远不支持。新增来源需要真实脱敏样本、时点/重置含义、身份边界和macOS/Windows路径证据；不通过联网补历史，也不由调用数猜余额。

## 可复查源码

- [Gemini配置与额度缓存](https://github.com/google-gemini/gemini-cli/blob/4fa64e71b9b4e1bb65a86cc2863574f561b82340/packages/core/src/config/config.ts)
- [Gemini额度请求](https://github.com/google-gemini/gemini-cli/blob/4fa64e71b9b4e1bb65a86cc2863574f561b82340/packages/core/src/code_assist/server.ts)
- [OpenCode会话数据结构](https://github.com/anomalyco/opencode/blob/7745079647b65036fe142e09ccd8623b25be1878/packages/schema/src/session.ts)
- DeepSeek实际安装源码：`/opt/homebrew/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-deepseek-account-platform/lib/types/details.js`；原仓库[deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)。

原始代码取证和来源SHA保存在`~/Library/Application Support/CodexTokenBar-Maintenance/2026-11-17-quota-source-identity/provider-evidence/`，未保存用户凭据、对话内容和组织原文。
