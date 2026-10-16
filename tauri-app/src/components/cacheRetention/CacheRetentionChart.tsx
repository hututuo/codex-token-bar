import { useEffect, useRef, useState } from "react";
import type { CacheRetentionAnalysis, CacheRetentionPoint } from "../../domain/cacheRetention/types";
import { formatRetentionMinutes } from "../../domain/cacheRetention/analysis";
import { retentionAxis, retentionDensity } from "./geometry";

export function CacheRetentionChart({ points, analysis }: { points: CacheRetentionPoint[]; analysis: CacheRetentionAnalysis }) {
  const canvas = useRef<HTMLCanvasElement>(null);
  const [size, setSize] = useState(900);
  const [hover, setHover] = useState<string | null>(null);
  const usable = analysis.p95State === "range_too_large" ? [] : points;
  const axis = retentionAxis(usable.reduce((max, point) => Math.max(max, point.gapMicroseconds / 60_000_000), 80));
  const density = retentionDensity(usable);
  const height = 380;
  const left = 54, right = 22, top = 28, bottom = 58;
  const width = Math.max(740, size);
  const plotWidth = width - left - right, plotHeight = height - top - bottom;
  const px = (gap: number) => left + axis.x(gap / 60_000_000) * plotWidth;
  const py = (rate: number) => top + (1 - rate) * plotHeight;

  useEffect(() => {
    const element = canvas.current;
    if (!element?.parentElement) return;
    const observer = new ResizeObserver(entries => setSize(entries[0]?.contentRect.width ?? 900));
    observer.observe(element.parentElement);
    return () => observer.disconnect();
  }, []);

  useEffect(() => {
    const element = canvas.current, context = element?.getContext("2d");
    if (!element || !context) return;
    const scale = window.devicePixelRatio || 1;
    element.width = width * scale; element.height = height * scale;
    context.scale(scale, scale);
    const dark = window.matchMedia("(prefers-color-scheme: dark)").matches;
    const text = dark ? "#b8c4d5" : "#64748b";
    context.font = "11px system-ui"; context.lineWidth = 1;
    for (let i = 0; i <= 5; i++) {
      const rate = i / 5, y = py(rate);
      context.strokeStyle = dark ? "#ffffff15" : "#18243a12";
      context.beginPath(); context.moveTo(left, y); context.lineTo(width - right, y); context.stroke();
      context.fillStyle = text; context.textAlign = "right"; context.fillText(`${i * 20}%`, left - 10, y + 4);
    }
    for (const minute of axis.ticks) {
      const x = px(minute * 60_000_000);
      context.fillStyle = text; context.textAlign = "center";
      const label = minute >= 1440 ? `${Math.round(minute / 1440)}天` : `${Math.round(minute)}`;
      context.fillText(label, x, height - bottom + 22);
    }
    for (const point of usable) {
      const intensity = Math.log1p(density.count(point)) / Math.log1p(density.max);
      context.fillStyle = `rgba(${dark ? "111,176,255" : "34,112,201"},${0.19 + intensity * 0.61})`;
      context.beginPath(); context.arc(px(point.gapMicroseconds), py(point.cached / point.input), 2.05, 0, Math.PI * 2); context.fill();
    }
    for (const [gap, color] of [[analysis.earlierDecline?.microseconds, "#9366db"], [analysis.dropMicroseconds, "#db9247"]] as const) {
      if (gap === null || gap === undefined) continue;
      context.strokeStyle = color; context.lineWidth = 2; context.setLineDash([5, 4]);
      context.beginPath(); context.moveTo(px(gap), top - 5); context.lineTo(px(gap), height - bottom); context.stroke();
    }
    context.setLineDash([]); context.fillStyle = text; context.textAlign = "center";
    context.fillText("两轮之间的空闲时间（分钟）", left + plotWidth / 2, height - 10);
    if (axis.hasTail) {
      const x = left + 0.831 * plotWidth;
      context.fillText("//", x, height - bottom + 3);
      context.font = "10px system-ui"; context.fillText("压缩长尾", left + 0.92 * plotWidth, top - 10);
    }
  }, [points, analysis, width]);

  return <div className="retention-plot-wrap">
    <canvas ref={canvas} style={{ width, height }} role="img" aria-label={`${usable.length} 轮续问：横轴为空闲时间，纵轴为下一轮首个请求的缓存命中率，颜色越深附近轮次越多。`} onMouseLeave={() => setHover(null)} onMouseMove={event => {
      const rect = event.currentTarget.getBoundingClientRect();
      const x = event.clientX - rect.left, y = event.clientY - rect.top;
      let nearest: CacheRetentionPoint | undefined, distance = 100;
      for (const point of usable) {
        const d = (px(point.gapMicroseconds) - x) ** 2 + (py(point.cached / point.input) - y) ** 2;
        if (d < distance) { distance = d; nearest = point; }
      }
      setHover(nearest ? `${nearest.model} · 间隔 ${formatRetentionMinutes(nearest.gapMicroseconds)} · 命中 ${(nearest.cached / nearest.input * 100).toFixed(1)}% · 附近 ${density.count(nearest)} 轮` : null);
    }} />
    <div className="retention-plot-caption" aria-live="polite">{hover ?? `颜色越深，附近轮次越多 · 按 10 秒 × 5% 统计密度 · 最密集处 ${density.max} 轮`}</div>
  </div>;
}
