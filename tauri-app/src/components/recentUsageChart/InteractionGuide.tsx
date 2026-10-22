import { useEffect, useRef, useState } from "react";

/** Native CSS animation; no sampling timer and no requests. */
export function RecentChartInteractionGuide() {
  const [expanded, setExpanded] = useState(true);
  const [active, setActive] = useState(false);
  const root = useRef<HTMLDetailsElement>(null);
  useEffect(() => {
    const element = root.current; if (!element || !expanded || typeof IntersectionObserver === "undefined") return;
    let visible = false;
    const update = () => setActive(visible && !document.hidden);
    const observer = new IntersectionObserver(entries => { visible = entries[0]?.isIntersecting ?? false; update(); });
    observer.observe(element); document.addEventListener("visibilitychange", update);
    return () => { observer.disconnect(); document.removeEventListener("visibilitychange", update); };
  }, [expanded]);
  return <details ref={root} className="recent-interaction-guide" open={expanded} onToggle={event => setExpanded(event.currentTarget.open)} data-active={active}>
    <summary><strong>↖ 图表怎么用</strong><span>{expanded ? "收起演示" : "展开演示"}</span></summary>
    {expanded && <div className="rig-content"><div className="rig-demo" aria-hidden="true"><svg viewBox="0 0 220 108">
      <path d="M14 88H207M14 56H207" className="rig-grid"/>
      <rect className="rig-selection" x="65" y="37" width="122" height="51"/>
      <path d="M14 80 35 67 65 74 95 49 125 61 155 44 187 53 207 39" className="rig-line"/>
      <g className="rig-cursor"><path d="M0 -40V15" className="rig-crosshair"/><circle className="rig-click" r="11"/><path d="M0 0v21l6-5 4 8 4-2-4-8 8-1Z" className="rig-pointer"/></g>
      <g className="rig-bubble"><rect x="0" y="0" width="144" height="23" rx="5"/><text className="rig-reading rig-reading-a" x="72" y="15">单点 3.2万 Token</text><text className="rig-reading rig-reading-b" x="72" y="15">区间 8.4万 Token</text><text className="rig-reading rig-reading-c" x="72" y="15">区间 12.6万 Token</text></g>
      <text className="rig-demo-caption" x="110" y="102">左右移动 → 点击起点 → 点击终点</text>
    </svg></div><div className="rig-instructions"><strong>移动鼠标，跟着看时间和用量</strong><p>① 点一下定起点　② 移动看区间　③ 再点一下固定终点</p><p>固定后弹出区间数据；第三次点击重新选。下图可直接操作。</p><small>左侧为演示数据</small></div></div>}
  </details>;
}
