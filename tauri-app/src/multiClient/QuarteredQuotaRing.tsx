import { useId } from "react";
import { clientTitle, value } from "./useClientScope";
import { clientBrand, compactQuotaValue, quotaQuarterLayout as layout, type QuotaItem } from "./integratedClientModel";

/** Four independent windows in one outline, in the same positions as macOS. */
export function QuarteredQuotaRing({items, colors = {}}: {items: QuotaItem[]; colors?: Record<string, string>}) {
  const clipID = `quota-quarter-${useId().replace(/:/g, "")}`;
  if (items.length !== 4) return null;
  const color = (item: QuotaItem) => colors[item.id] ?? (item.id.endsWith("-5h") ? "#B6EF75" : "#B4ACFF");
  const label = (item: QuotaItem) => `${clientTitle(item.client)} ${item.window} 剩余 ${item.remaining === null ? item.status : value(item)}`;
  const pool = (item: QuotaItem) => item.window.split(" · ").slice(0,-1).join(" · ").replace(/^第三方模型$/, "第三方");
  return <div className="integrated-quartered-ring" data-mode="quartered" role="img"
    aria-label={items.map(label).join("；")}
    title={items.map(item => label(item) + "\n" + item.source).join("\n")}>
    <div className="integrated-quarter-outline">
      <svg viewBox="0 0 60 60" aria-hidden="true">
        {items.map((item, index) => <g key={item.id} transform={`rotate(${layout.rotations[index]} 30 30)`}
          data-sidebar-stroke-source="" data-stroke-inset={layout.inset / layout.size}
          data-stroke-spec={JSON.stringify([{id:item.id,quarter:index,fraction:item.remaining === null ? null : item.remaining / 100,
            color:color(item),trackColor:"#ffffff",trackOpacity:.15,width:3}])}>
          <defs><mask id={`${clipID}-${index}`} maskUnits="userSpaceOnUse" x="0" y="0" width="60" height="60">
            <circle cx="30" cy="30" r="27" fill="none" stroke="white" strokeWidth="12" strokeLinecap="butt"
              pathLength="1" strokeDasharray={`${layout.sweep} 1`} strokeDashoffset={-layout.gap}/>
          </mask></defs>
          <circle cx="30" cy="30" r="27" fill="none" stroke="white" strokeOpacity=".15" strokeWidth="3"
            pathLength="1" strokeDasharray={`${layout.sweep} 1`} strokeDashoffset={-layout.gap}/>
          <circle cx="30" cy="30" r="27" fill="none" stroke={color(item)} strokeWidth="3" strokeLinecap="round"
            pathLength="1" strokeDasharray={`${layout.sweep * (item.remaining ?? 0) / 100} 1`} strokeDashoffset={-layout.gap}
            opacity={(item.remaining ?? 0) > 0 ? 1 : 0} mask={`url(#${clipID}-${index})`}/>
        </g>)}
      </svg>
      <div className="integrated-quarter-values" aria-hidden="true">
        {items.map(item => <span key={item.id} data-quota-id={item.id} data-digits={compactQuotaValue(item).length}
          style={{color:color(item)}}>{compactQuotaValue(item)}</span>)}
      </div>
    </div>
    <div className="integrated-quarter-pools"><span>{pool(items[0])}</span><span>{pool(items[2])}</span></div>
    <small>上 5h · 下 7d</small>
    <span className="integrated-ring-legend"><i data-quota-marker-end={items.map(item => item.id).join(" ")}
      style={{background:clientBrand[items[0].client]}}/>{clientTitle(items[0].client)}</span>
  </div>;
}
