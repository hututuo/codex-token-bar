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
      <circle className="rig-endpoint rig-start-point" cx="65" cy="74" r="3"/>
      <circle className="rig-endpoint rig-end-point" cx="187" cy="53" r="3"/>
      <g className="rig-cursor"><path d="M0 -40V15" className="rig-crosshair"/><circle className="rig-click" r="11"/><path d="M0 0v21l6-5 4 8 4-2-4-8 8-1Z" className="rig-pointer"/></g>
      <g className="rig-bubble"><rect x="0" y="0" width="144" height="23" rx="5"/><text className="rig-reading rig-reading-a" x="72" y="15">单点 3.2万 Token</text><text className="rig-reading rig-reading-b" x="72" y="15">区间 8.4万 Token</text><text className="rig-reading rig-reading-c" x="72" y="15">区间 12.6万 Token</text></g>
      <text className="rig-demo-caption" x="110" y="102">演示数据 · 移动 → 点起点 → 点终点</text>
    </svg></div><div className="rig-instructions"><p><strong>移上去预览：</strong>鼠标移到图上，查看当前点的时间和用量。</p><p><strong>点选计算：</strong>点一下定起点，移动选择区间，再点一下定终点，弹出用量与反推额度；再点可重选。</p></div></div>}
  </details>;
}
