# 速蹬需要反复手动重连：空闲窗口误判

用户反馈每次需要手动点重连。此前实际在978界面看到“报告来源无法确认，已停止上报”；979重启后已能重新上报，但不代表根因已修。

## 根因与复现

HTTP在build/send/签名前检查来源。原检查把live中的所有非零数值（包括agents.active）和窗口peak都当作“当前必须有source行”。SDK的ReportBody.SourceEntries故意不因agents.active或过去峰值生成当前来源行：当前速率、生成/工具数量、窗口增量均为0时，sources/models都可以为空，但窗口peak仍保留前几秒合法来源的真实峰值。

用现有AgentSpeedCore实际ReportWindow/ReportBody本地无网络复现：live.outputTokS=0，live.agents.active=1，peak.outputTokS=40，delta全0，sources=[]，models=[]。原校验返回false，controller.fail不安排重试，终止监视器；点击重连重置窗口，于是暂时恢复。Windows同一判断也会把该合法包变成终止错误。

## 修复边界

- 来源检查默认保持严格。新增内部filteredWindow参数，仅在已按允许来源过滤的监视器/窗口生成路径使用，允许过去峰值及空闲active数量缺少当前source行。
- 非零当前输出/总速率、generating/tools仍要求来源，非零Token增量仍要求source/model归属；所有明确的Claude Code/Desktop及未知来源ID始终拒绝。
- 没有把未知数据改成Codex，没有把真实峰值清成0，没有无限重连来绕过隐私检查，没有改设备身份/授权或上游版本、协议。
- Mac收包先reportableSample过滤所有来源及聚合，窗口只观测过滤结果；Windows监视器创建时即使用排除Claude的ReportableSources，HTTP/WS/fallback均取该监视器。

## 验证

- scratch/20261030-report-idle-recovery/：实际SDK复现体、旧/新检查的独立Swift6验证，无网络调用。
- Swift新增实际SDK空闲峰值/active-only、拒绝案例，以及活动→空闲→再次活动三次上报保持同一监视器和设备的回归。
- Windows self-test新增实际ReportWindow/ReportBody空闲窗口与拒绝案例。
- 禁止来源策略独立复核，未发现未过滤数据路径调用该内部例外。

云端结果、本机替换与数据核对在完成后补记。修改仅在现有工作分支；当前正式版仍979。
