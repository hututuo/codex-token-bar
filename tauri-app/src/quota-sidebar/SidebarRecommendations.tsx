import { useEffect, useState } from "react";
import type { SidebarRadar } from "./radarModel";

export const SIDEBAR_RECOMMENDATION_INTERVAL_MS = 4_000;
const PAGE_SIZE = 3;
type Recommendation = SidebarRadar["crowd"]["rows"][number];

export function SidebarRecommendations({ rows, visible, onOpen }: {
  rows: readonly Recommendation[]; visible: boolean; onOpen: () => void;
}) {
  // A new ordering starts at the top; ordinary countdown/snapshot ticks do not.
  const rankingKey = JSON.stringify(rows.map(row => [row.rank, row.model, row.effort]));
  return <RecommendationPages key={rankingKey} rows={rows} visible={visible} onOpen={onOpen} />;
}

function RecommendationPages({ rows, visible, onOpen }: {
  rows: readonly Recommendation[]; visible: boolean; onOpen: () => void;
}) {
  const pageCount = Math.ceil(rows.length / PAGE_SIZE);
  const [frame, setFrame] = useState({ index: 0, previous: null as number | null, revision: 0 });
  const [hovered, setHovered] = useState(false);
  const [focused, setFocused] = useState(false);
  useEffect(() => {
    if (!visible || hovered || focused || pageCount < 2) return;
    let timer: ReturnType<typeof setInterval> | undefined;
    const stop = () => { clearInterval(timer); timer = undefined; };
    const start = () => {
      stop();
      if (document.hidden) return;
      timer = setInterval(() => setFrame(current => ({
        index: (current.index + 1) % pageCount, previous: current.index, revision: current.revision + 1,
      })), SIDEBAR_RECOMMENDATION_INTERVAL_MS);
    };
    start();
    document.addEventListener("visibilitychange", start);
    return () => { stop(); document.removeEventListener("visibilitychange", start); };
  }, [visible, hovered, focused, pageCount]);

  const page = (index: number, outgoing: boolean) => <span
    key={`${outgoing ? "old" : "new"}-${frame.revision}`}
    className={`qs-recommendation-page${outgoing ? " qs-recommendation-out" : frame.previous !== null ? " qs-recommendation-in" : ""}`}
    aria-hidden={outgoing || undefined}
    onAnimationEnd={outgoing ? undefined : () => setFrame(current => current.revision === frame.revision ? { ...current, previous: null } : current)}
  >{rows.slice(index * PAGE_SIZE, (index + 1) * PAGE_SIZE).map(row => <span
    className="qs-recommendation-row" key={row.rank}
    title={`第 ${row.rank} 名 · ${row.model} ${row.effort} · IQ ${row.iq.toFixed(1)}`}
  ><b>{row.rank}</b><span>{row.model.replace(/^gpt-[\d.]+-/, "")} {row.effort}</span></span>)}</span>;

  return <button className="qs-recommendations" onClick={onOpen}
    aria-label={`众测推荐${pageCount > 1 ? `，第 ${frame.index + 1}/${pageCount} 页` : ""}，点击查看完整排行榜`}
    onPointerEnter={() => setHovered(true)} onPointerLeave={() => setHovered(false)}
    onFocus={() => setFocused(true)} onBlur={() => setFocused(false)}>
    <small className="qs-recommendation-heading" title="每 5 分钟刷新；每 4 秒翻页，悬停或键盘聚焦暂停；缓存标记表示来源服务器返回缓存">
      众测推荐{pageCount > 1 && <small aria-hidden="true">{frame.index + 1}/{pageCount}</small>}
    </small>
    <span className="qs-recommendation-viewport">
      {frame.previous !== null && page(frame.previous, true)}
      {rows.length ? page(frame.index, false) : <span className="qs-recommendation-empty">待读取</span>}
    </span>
  </button>;
}
