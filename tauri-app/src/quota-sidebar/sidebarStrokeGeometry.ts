/** Ring sides keep the same bottom-to-top order while squeezing together.
 * Keep this mapping aligned with ClientQuotaMorphGeometry (macOS). */
export type StrokePoint = { x: number; y: number };
export type StrokeRect = { x: number; y: number; width: number; height: number };
export type StrokeSegment = { id: string; start: number; end: number; color: string };
export type SidebarStrokeSpec = {
  id: string; half?: number; shape?: "ring" | "strip"; fraction: number | null; color: string;
  expected?: number | null; segments?: StrokeSegment[]; trackColor?: string; trackOpacity?: number; fillOpacity?: number; width?: number;
};
export type SidebarStroke = {
  id: string; group: string; source: StrokePoint[]; target: StrokePoint[]; color: string;
  sourceWidth: number; targetWidth: number; opacity: number; foreground?: boolean;
  sourcePath?: StrokePoint[]; targetPath?: StrokePoint[];
  sourceRange?: [number, number]; targetRange?: [number, number];
};
const clamp = (value: number) => Math.min(1, Math.max(0, value));
export function squeezePoints(ring: StrokeRect, bar: StrokeRect, half: number, progress: number): StrokePoint[] {
  const p = clamp(progress), gap = Math.abs(half) === 2 ? 0 : .006 * 2 * Math.PI;
  const start = half === 0 ? -Math.PI / 2 : Math.PI / 2 + (half < 0 ? gap : -gap);
  const sweep = half === 0 ? 2 * Math.PI : (Math.PI - 2 * gap) * (half < 0 ? 1 : -1);
  return Array.from({ length: 33 }, (_, index) => {
    const t = index / 32, angle = start + sweep * t;
    const x = ring.x + ring.width / 2 + ring.width / 2 * Math.cos(angle);
    const y = ring.y + ring.height / 2 + ring.height / 2 * Math.sin(angle);
    // Affine ellipse squeeze; do not re-space the arc vertices during motion.
    const endY = half === 0 ? bar.y + bar.height - 2 - Math.max(0, bar.height - 4) * t
      : bar.y + bar.height / 2 + Math.sin(angle) / Math.cos(gap) * Math.max(0, bar.height - 4) / 2;
    return { x: x + (bar.x + bar.width / 2 - x) * p, y: y + (endY - y) * p };
  });
}
export function strokeInterval(half: number, lower: number, upper: number, collapsed: boolean): [number, number] {
  if (collapsed && Math.abs(half) === 2) return [lower, upper];
  if (half === 2) return [1 - Math.min(1, upper * 2), 1 - Math.min(1, lower * 2)];
  if (half === -2) return [Math.max(0, lower * 2 - 1), Math.max(0, upper * 2 - 1)];
  return half > 0 && !collapsed ? [1 - upper, 1 - lower] : [lower, upper];
}
function trim(points: StrokePoint[], lower: number, upper: number): StrokePoint[] {
  const lengths = [0];
  for (let i = 1; i < points.length; i++) lengths.push(lengths[i - 1] + Math.hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y));
  const total = lengths[lengths.length - 1];
  return Array.from({ length: 33 }, (_, index) => {
    const distance = clamp(lower + (upper - lower) * index / 32) * total;
    let b = 1;
    while (b < lengths.length - 1 && lengths[b] < distance) b++;
    const a = b - 1, length = lengths[b] - lengths[a];
    const t = length > 0 ? (distance - lengths[a]) / length : 0;
    return { x: points[a].x + (points[b].x - points[a].x) * t, y: points[a].y + (points[b].y - points[a].y) * t };
  });
}
export function sidebarStrokes(spec: SidebarStrokeSpec, source: StrokeRect, target: StrokeRect): SidebarStroke[] {
  if (![source, target].every(r => r.width > 0 && r.height > 0 && Object.values(r).every(Number.isFinite))) return [];
  const q = clamp(spec.fraction ?? 0), strip = spec.shape === "strip", half = spec.half ?? 0;
  const barFraction = strip ? q : clamp((q * target.height - 4) / Math.max(1, target.height - 4));
  const parts = strip ? [0] : half === 0 ? [-2, 2] : [half];
  const strokes = parts.flatMap(part => {
    const a = strip ? [{ x: source.x + 2, y: source.y + source.height / 2 }, { x: source.x + source.width - 2, y: source.y + source.height / 2 }] : squeezePoints(source, target, part, 0);
    const b = strip ? [{ x: target.x + target.width / 2, y: target.y + 2 }, { x: target.x + target.width / 2, y: target.y + target.height - 2 }] : squeezePoints(source, target, part, 1);
    const make = (id: string, color: string, range: [number, number], end: [number, number], opacity: number): SidebarStroke => ({
      id: `${spec.id}:${part}:${id}`, group: `${spec.id}:${id}`, source: trim(a, ...range), target: trim(b, ...end), color,
      sourcePath: a, targetPath: b, sourceRange: range, targetRange: end,
      sourceWidth: spec.width ?? (strip ? 4 : 3), targetWidth: 4, opacity,
    });
    const strokes = [make("track", spec.trackColor ?? "#ffffff", [0, 1], [0, 1], spec.trackOpacity ?? .12)];
    if (q <= 0) return strokes;
    for (const segment of spec.segments ?? [{ id: "fill", start: 0, end: 1, color: spec.color }]) {
      const lo = clamp(segment.start), hi = Math.max(lo, clamp(segment.end));
      const range: [number, number] = strip ? [lo * q, hi * q] : strokeInterval(part, lo * q, hi * q, false);
      const end: [number, number] = strip ? [lo * q, hi * q] : strokeInterval(part, lo * barFraction, hi * barFraction, true);
      if (spec.segments && range[0] === range[1] && end[0] === end[1]) continue;
      strokes.push(make(segment.id, segment.color, range, end, spec.fillOpacity ?? 1));
    }
    return strokes;
  });
  if (!strip && typeof spec.expected === "number" && Number.isFinite(spec.expected)) {
    const expected=clamp(spec.expected),radius=source.width/2;
    const angle=half===0?-Math.PI/2+expected*2*Math.PI:(half<0?Math.PI/2:-Math.PI/2)+expected*Math.PI;
    const radial=(r:number)=>({x:source.x+source.width/2+Math.cos(angle)*r,y:source.y+source.height/2+Math.sin(angle)*r});
    const y=target.y+target.height*(1-expected),x=target.x+target.width/2;
    strokes.push({id:spec.id+":pace",group:spec.id+":pace",source:trim([radial(radius-3.5),radial(radius+3.5)],0,1),
      target:trim([{x:x-2.5,y},{x:x+2.5,y}],0,1),color:"#ffffff",sourceWidth:1.5,targetWidth:1.5,opacity:1,foreground:true});
  }
  return strokes;
}
export function strokePath(points: StrokePoint[]): string {
  return points.map((p, index) => `${index ? "L" : "M"}${p.x.toFixed(4)} ${p.y.toFixed(4)}`).join(" ");
}
