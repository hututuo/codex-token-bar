# 多客户端 Token 分支验证回执

范围：`codex/multi-client-tokens` 独立 worktree；测试和浏览器预览，不含安装、正式应用运行验收或 Windows 原生构建。

| 检查 | 状态 | 证据 |
|---|---|---|
| Swift 全量 | PASS | 1913项，20项显式 opt-in 跳过，0失败；新增27项覆盖本地额度、五客户端解析、压缩帧、会话身份、账本与增量断点 |
| React/UI 全量 | PASS | 1237项，0失败 |
| TypeScript | PASS | `tsc --noEmit` 退出0 |
| Rust 全库业务单测 | PASS（串行） | 1384项：1373通过、11忽略、0失败；新增多客户端14项通过 |
| 浏览器预览 | PASS | 实际渲染设置及用量表；Claude额度显示开关刷新后保留；预览样本明确标注为合成数据 |
| Mac 正式安装/运行 | NOT_RUN | 按用户要求未安装、未替换、未重启正式应用 |
| Windows EXE/双屏/托盘实机 | NOT_RUN | 本分支只同步源码；未构建或替换 EXE |
| Anthropic/claude.ai 联网 | NOT_RUN | 本分支未实现联网额度获取；未向这些服务发测试请求 |
| 真实用户多客户端历史覆盖 | NOT_RUN | 使用隔离夹具，没有把合成样本当作本机真实用量 |

Swift的20项跳过是既有套件中需显式启用的真实请求、真实本地库、旧发布库或原生截图/性能夹具。本次没有为通过测试而跳过新增用例。

发现并修复的问题：OpenCode分页查询拼接缺少换行；Claude本地 synthetic 提示被误当用量；网页桥接返回空对象时崩溃；跨平台浮点毫秒时间戳；日志部分尾行/尾帧断点；DSH同名文件与跨增量批次的会话身份；数据库分页期间源变更；同一请求多次更新或历史重放重复计数。

## 复现

```sh
# 在本 worktree 根目录
swift test --build-system native --skip-update -Xswiftc -gnone -j 3
./tauri-app/node_modules/.bin/tsc --noEmit --project tauri-app/tsconfig.json
# UI：枚举 tauri-app/src 下所有 *.test.mjs，再执行 node --test --test-concurrency=2
cd tauri-app/src-tauri
cargo test --lib -j2 -- --test-threads=1
```

Rust补充：原始 `cargo test -j2` 在静态库归档时因磁盘不足退出101，未进入测试；本次没有将它记为通过。主包业务测试都在 library target，`main.rs` 没有单测，`tests/sidebar-windows-api` 是单独的 Windows API 编译检查工程，本次未进行 Windows 目标验证。`cargo test --lib -j2` 并行运行曾在未改动的 `core::live_rate::live_rate_tests::floating_snapshot_uses_precise_token_summary_when_cached` 出现一次缓存断言失败（预期40、实际0）；该测试单独重跑和全库串行均通过，存在测试共享状态干扰迹象，未修改测速源码。

日志保存在 `scratch/multi-client-validation/`。截图：`scratch/multi-client-review/settings-preview.png`。
浏览器样例源：`tauri-app/dev-previews/multi-client-usage.html`；通过本 worktree 的 Vite 开发服务器访问。

磁盘空间接近下限后，已删除本 worktree 的 `.build/arm64-apple-macosx` 编译缓存以继续 Rust 检查；测试日志、源码和截图保留，正式 App、原工作目录和用户数据库未清理。

后续还清理了仅本 worktree 的 Rust `target/debug/incremental` 缓存以解除空间阻塞；没有清理原线程缓存或用户数据。完整 Cargo 归档失败、并行单测失败、单项重跑和串行通过日志均保留。
