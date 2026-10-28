import { SpeedLeaderboardMovie } from "./SpeedLeaderboardMovie";
export const newFeaturesKey="product.newFeatures.localClientsSpeed.v1";
export function HarnessNewFeatures({offerLeaderboard,localClient,localEnabled=false,busy=false,error="",onEnableLocal,onJoin,onDismiss}: {
 offerLeaderboard:boolean;localClient:string|null;localEnabled?:boolean;busy?:boolean;error?:string;
 onEnableLocal:()=>void;onJoin:()=>void;onDismiss:()=>void;
}) {
 return <aside className="speed-report-invitation harness-new-features" role="dialog" aria-modal="true" aria-label="本次更新的新特性">
  <header className="speed-report-heading"><div><h2>本次更新</h2><p>新特性，由你选择开启</p></div><button type="button" aria-label="稍后了解新特性" onClick={onDismiss}>×</button></header>
  {offerLeaderboard&&<><SpeedLeaderboardMovie/><section className="harness-feature"><h3>参加速蹬排行榜</h3><p>可选择上报速度、Token、模型等统计。不上传对话、文件路径或账号凭据，可随时关闭。</p><button className="speed-report-primary" disabled={busy} onClick={onJoin}>了解并参加</button></section></>}
  {localClient&&<section className="harness-feature"><h3>识别到 {localClient} 客户端</h3><p>是否启用本地 Token 用量统计？仅读取本地，不产生任何网络请求。不会自动参加排行榜，可随时关闭。</p><button className="speed-report-primary" disabled={busy||localEnabled} onClick={onEnableLocal}>{localEnabled?"已启用":busy?"正在保存…":"启用本地统计"}</button></section>}
  {error&&<p role="alert">{error}</p>}
  <footer><span>{offerLeaderboard&&localClient?"两个选项独立，":""}稍后也可在设置中调整。</span><button disabled={busy} onClick={onDismiss}>知道了</button></footer>
 </aside>;
}
