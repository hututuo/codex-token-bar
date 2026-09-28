# Luna Reserve 只读额度：延期记录

> 后续：已在独立分支实现[普通响应中的被动储备展示](2026-09-27-cpa-reserve-passive-display.md)。不发送 supportsLunaReserve、不执行 fallback；下文保留的是 2026-09-24 上线排除范围，不能解读为后续分支仍完全没有解析代码。主动 opt-in 方案继续延期。

状态：`DEFERRED_NOT_IN_RELEASE`

本次上线不包含 Luna Reserve 读取功能，也不包含任何自动切换或 Reserve fallback。

## 延期范围

- `account/rateLimits/read` 的 `supportsLunaReserve` 请求参数
- `gpt-reserve` / `base_model_inference` 的解析与额度展示
- Reserve 状态字段、跨 Swift/Rust/Tauri 的实时数据传递
- Reserve 相关的侧栏、浮窗、紧凑面板和测试

这些改动已放到独立分支 `codex/luna-reserve-read-only`，后续完善后再单独评审和合并。

## 重新启用前的约束

1. 只把后端返回的 Reserve 数据作为事实，不根据 5h/7d 百分比本地推断。
2. 继续保持“只读”目标时，不实现模型切换、turn 改写或 Reserve 消耗。
3. 明确处理 `available`、`unavailable`、`unsupported`、`error` 四种读取状态。
4. 核对当前 Codex app-server 版本的 `supportsLunaReserve` 契约后，再决定是否保留该能力声明。
