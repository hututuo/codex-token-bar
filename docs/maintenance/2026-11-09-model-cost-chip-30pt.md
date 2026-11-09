# 主页模型费用条恢复单行 30pt

用户反馈 build 1002 费用芯片仍为双行；本轮按 `d4977531` 的单行布局恢复。产品源码 `82d06be1f0692dd202aa8cc25082dfcf98865fa7`，0.9.11 / build 1003 已于 2026-11-09 10:27（北京时间）备份替换安装并启动，三页实机截图与单行校验通过。

## 改动边界

Swift `DashboardModelCostChip` 改回 `HStack(spacing: 5)`：圆点、单行短模型名、Spacer、Token、占比、右侧金额；仅水平 padding 8，固定 height 30。保留 build 1002 的 `.help(description)`、原始来源悬浮说明、未知模型参考金额、背景颜色和描边。

Tauri 仅删除 CSS 末尾的双行覆盖规则及 `grid-row: 2` 子项定位，恢复原有五列网格、height 30px 和 padding 0 8px。未改模型身份、费用计算、未知汇总、Token 账本、数据读取或任务侧栏。

现有 Swift 实际布局用例改为检查 204/208/280pt 宽度下每条固定 30pt，并输出云端截图；现有前端已知/未知费用用例加载完整实际 CSS，检查两种费用条均为单行五列、30px、无垂直 padding，保留 title。全部编译、测试与打包在云端，本机只读检查、使用系统截图和运行下载/安装产物。

## 验收状态

[CI 42546553083](https://github.com/hututuo/codex-token-bar/actions/runs/42546553083) 和 [Packaging 42546576498](https://github.com/hututuo/codex-token-bar/actions/runs/42546576498) 均为 `completed/success`，不重复触发构建。macOS arm64 App/DMG、Windows x64/ARM64 安装包均已下载，并通过 artifact digest、源码 SHA、manifest 与逐文件哈希校验。

最终源码的 Swift XCTest 2,425 通过、38 既有跳过，Swift Testing 676 通过；macOS Rust 1,824、Windows Rust 1,767 通过，各 14 既有 ignored；前端 1,450 通过、0 跳过，云端脚本 18 通过，发布脚本 112 通过、1 既有跳过。双端各 16 个生产场景、备份清理负控和物理 A 替换保护检查均通过。

本轮固定 30pt 布局用例 `testLongModelIdentitiesKeepCompactCostCardExtent` 已实际通过，并生成 `visual-previews/model-identity-compact-cards.png`。前端用例 `one anonymous model cannot hide the known cycle prices or total` 加载完整 CSS，实际检查主/次两类费用条的五列单行及 30px 属性，并保留已知/未知金额断言；全量测试通过。未重跑可选历史矩阵/规模门禁，未在本机编译。

## 安装与实机截图

`/Applications/Codex Token Bar.app` 实际为 build 1003，启动 PID 3801。完整备份 build 1002 后再进行替换，旧备份未覆盖；候选与安装后 App 文件清单一致，深度严格 codesign 验证通过，bundle ID、designated requirement、Sparkle 公钥/feed 均保持一致。沿用 ad-hoc 签名，未 notarize、未发布 Release/tag/appcast。

| 产物 | SHA256 |
|---|---|
| macOS App ZIP | `ec2987037f5526c4ad1650fd66fb7306c530982766e3759dbd1b4f4aee5915c7` |
| 已安装可执行文件 | `49c56ae2f9a4a3f198659c2b2d9dfd09ebd46c0675bedf03697fbc81b63c5ec2` |
| Windows x64 安装包 | `65df1a63666da22e7aa98f5d8f02cbdaa78a42d543a116e17964e5ecb84b05ed` |
| Windows ARM64 安装包 | `e98fd3184808912332c2df559b2fe827b8f6c3da26db8d1b0ad93763c0e0dc0c` |

启动后首次过早检查尚无 refresh 确认，未据此宣称成功；等待正常刷新完成后，安装后的独立诊断导出通过（1.515 秒、主进程不变），startup/refresh ready 与本次 attempt 对应的 updater.confirmed 均成立。没有重新编译或改动业务数据库来促成验收。

`capture_ui.py` 验证当前选择范围后，捕获实际 1512×897pt 窗口（3024×1794px）下的累计、近 7 天、今日。`verify_ui.py` 使用系统 OCR 的同一纵坐标带匹配模型名、Token、占比和金额，三页均 PASS，并人工复核图片：

| 范围 | 同一行的实机文字示例 |
|---|---|
| 累计 | `Astra6 56.2亿 5.8% $10777` |
| 近 7 天 | `Astra6 24.3亿 41% $5950` |
| 今日 | `Astra6 4.9亿 68% $683` |

这些是截图瞬间的真实数据，不冻结仍在增长的记录。三页均无“价格未知”、内部路由后缀卡或 Fable 空卡；未知模型仍在末尾参考分组，其金额不混入已知费用。费用条恢复单行 30pt 后，狭窄网格中的较长参考标签/Auto Review 可按老样式截断，完整标签、来源和参考计价说明仍通过悬停保留；没有为容纳长文字再次改成两行。截图证明单行排布，固定高度另由真实 Swift 布局测量和完整 CSS 计算样式测试证明。本轮不宣称 Windows 桌面实机截图验收。

## 本机证据与回滚

本轮证据目录为工作区 `scratch/model-chip-30pt-20261109/`：

- `82d06be1/final-validation.json`：PASS，绑定最终源码与两条全绿工作流。
- `82d06be1/app-validation.json`：包哈希、签名、架构及资源校验。
- `build1002-lifetime.png`：改动前同窗口基线。
- `build1003-lifetime.png`、`build1003-sevenDay.png`、`build1003-today.png`：安装后的实际窗口；对应 capture/OCR JSON 与 `build1003-ui-validation.json`（PASS）均保留。
- `local-install-1003-5ho6ogeg/installation.json`：安装及回滚记录；同目录保留完整 `rollback-build1002/Codex Token Bar.app` 和首次刷新确认的 `helper-validation.json`。

回滚时退出新版本，保留 build 1003 后将备份 App 复制回 `/Applications/` 并校验签名；不回写或替换业务数据。无关工作树改动及之前的 build 1001 备份均保留。
