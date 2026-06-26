import { useEffect, useRef } from "react";
import type { CSSProperties } from "react";
import {
  displayRadarNumber,
  percentText,
  primaryModelRow,
  secondaryModelRows,
  type CodexRadarSnapshot,
} from "../components/codexRadar/model";
import type { FloatingContentGroup, FloatingPanelSnapshot, FloatingUnreadEffect, FloatingWindowSettings } from "../types/dashboard";
import { embedsUsageStatusInRateRow, layoutFloatingContentGroups } from "./floatingContent";
import { floatingTextPaletteForGroup } from "./floatingTextPalette";

interface FloatingPanelSurfaceProps {
  settings: FloatingWindowSettings;
  snapshot: FloatingPanelSnapshot;
  radarSnapshot?: CodexRadarSnapshot | null;
  unreadEffect?: FloatingUnreadEffect;
  onClose?: () => void;
  onDragStart?: () => void;
}

function clampPercent(value: number): number {
  if (!Number.isFinite(value)) {
    return 0;
  }
  return Math.min(100, Math.max(0, value * 100));
}

function rateFillPercent(tokensPerSecond: number, maxTokensPerSecond: number): number {
  const maxValue = Number.isFinite(maxTokensPerSecond) && maxTokensPerSecond > 0 ? maxTokensPerSecond : 200;
  if (!Number.isFinite(tokensPerSecond) || tokensPerSecond <= 0) {
    return 0;
  }
  return Math.min(100, Math.max(0, (tokensPerSecond / maxValue) * 100));
}

function FloatingQuotaBar({ label, remainingPercent }: { label: string; remainingPercent: number }) {
  const fillPercent = clampPercent(remainingPercent);

  return (
    <span
      className="floating-quota-bar"
      role="meter"
      aria-label={`${label}，剩余 ${Math.round(fillPercent)}%`}
      aria-valuemin={0}
      aria-valuemax={100}
      aria-valuenow={Math.round(fillPercent)}
      style={{ "--quota-fill": `${fillPercent}%` } as CSSProperties}
    >
      <span className="floating-quota-track" aria-hidden="true">
        <span className="floating-quota-fill" />
      </span>
      <span className="floating-quota-label">{label}</span>
    </span>
  );
}

function FloatingRateMeter({
  fullScale,
  snapshot,
  statusText,
}: {
  fullScale: number;
  snapshot: FloatingPanelSnapshot;
  statusText?: string;
}) {
  const scaleLimit = Number.isFinite(fullScale) && fullScale > 0 ? fullScale : snapshot.maxTokensPerSecond || 200;
  const fillPercent = rateFillPercent(snapshot.tokensPerSecond, scaleLimit);
  const visibleFillPercent = fillPercent > 0 ? Math.max(3, fillPercent) : 0;
  const hasStatusText = typeof statusText === "string" && statusText.length > 0;

  return (
    <span
      className={`floating-rate-meter ${hasStatusText ? "floating-rate-meter--with-status" : "floating-rate-meter--solo"}`}
      role="meter"
      aria-label={`实时速率 ${snapshot.tokensPerSecond.toFixed(1)} tok/s，满格 ${Math.round(scaleLimit)} tok/s`}
      aria-valuemin={0}
      aria-valuemax={Math.round(scaleLimit)}
      aria-valuenow={Number(snapshot.tokensPerSecond.toFixed(1))}
      style={{ "--rate-fill": `${visibleFillPercent}%` } as CSSProperties}
    >
      {hasStatusText ? <em>{statusText}</em> : null}
      <span className="floating-rate-track" aria-hidden="true">
        <i />
      </span>
    </span>
  );
}

export function FloatingPanelSurface({
  settings,
  snapshot,
  radarSnapshot,
  unreadEffect = "ripple",
  onClose,
  onDragStart,
}: FloatingPanelSurfaceProps) {
  const shouldShowUnreadEffect = snapshot.unreadSummary.active && unreadEffect !== "off";
  const groups = layoutFloatingContentGroups(settings.contentVisibility);
  const attachedUsageStatus = embedsUsageStatusInRateRow(settings.contentVisibility);
  const rootPalette = floatingTextPaletteForGroup(settings, groups[0] ?? "rateAndBar", 0, Math.max(groups.length, 1));
  const rootStyle = {
    "--floating-primary": rootPalette.primary,
    "--floating-secondary": rootPalette.secondary,
    "--floating-muted": rootPalette.muted,
    "--floating-divider": rootPalette.divider,
  } as CSSProperties;

  return (
    <aside
      className="floating-panel-surface"
      aria-label={`悬浮窗，${snapshot.unreadSummary.label}`}
      onMouseDown={onDragStart}
      style={rootStyle}
      title={snapshot.unreadSummary.detail}
    >
      {shouldShowUnreadEffect ? <UnreadEffect effect={unreadEffect} /> : null}
      <button
        className="floating-close-button"
        type="button"
        aria-label="关闭悬浮窗"
        onMouseDown={(event) => event.stopPropagation()}
        onClick={onClose}
      >
        ×
      </button>
      <div className="floating-content">
        {groups.map((group, index) => (
          <FloatingContentRow
            attachedUsageStatus={attachedUsageStatus}
            group={group}
            index={index}
            key={group}
            radarSnapshot={radarSnapshot}
            settings={settings}
            snapshot={snapshot}
            total={groups.length}
          />
        ))}
      </div>
    </aside>
  );
}

interface FloatingContentRowProps {
  attachedUsageStatus: boolean;
  group: FloatingContentGroup;
  index: number;
  radarSnapshot?: CodexRadarSnapshot | null;
  settings: FloatingWindowSettings;
  snapshot: FloatingPanelSnapshot;
  total: number;
}

function FloatingContentRow({
  attachedUsageStatus,
  group,
  index,
  radarSnapshot,
  settings,
  snapshot,
  total,
}: FloatingContentRowProps) {
  const palette = floatingTextPaletteForGroup(settings, group, index, total);
  const style = {
    "--floating-primary": palette.primary,
    "--floating-secondary": palette.secondary,
    "--floating-muted": palette.muted,
    "--floating-divider": palette.divider,
  } as CSSProperties;

  switch (group) {
    case "rateAndBar":
      return (
        <div className="floating-row floating-topline" style={style}>
          <span className="floating-rate-readout" aria-label={`${snapshot.tokensPerSecond.toFixed(1)} tok/s`}>
            <strong>{snapshot.tokensPerSecond.toFixed(1)}</strong>
            <span>tok/s</span>
          </span>
          <FloatingRateMeter
            fullScale={settings.tokenRateFullScale}
            snapshot={snapshot}
            statusText={attachedUsageStatus ? snapshot.trendLabel : undefined}
          />
        </div>
      );
    case "usageStatus":
      return (
        <div className="floating-row floating-usage-status" style={style}>
          <span className="floating-usage-status-card">{snapshot.trendLabel || "节奏待读取"}</span>
        </div>
      );
    case "metrics":
      return (
        <div className="floating-row floating-metrics" style={style}>
          <span>{snapshot.totalTokensLabel}</span>
          <span>{snapshot.todayTokensLabel}</span>
          <span>{snapshot.requestsLabel}</span>
        </div>
      );
    case "radar":
      return <FloatingRadarRow snapshot={radarSnapshot} style={style} />;
    case "quota":
      return (
        <div className="floating-row floating-quota" style={style}>
          <FloatingQuotaBar label={snapshot.fiveHourLabel} remainingPercent={snapshot.fiveHourRemainingPercent} />
          <FloatingQuotaBar label={snapshot.sevenDayLabel} remainingPercent={snapshot.sevenDayRemainingPercent} />
        </div>
      );
  }
}

function FloatingRadarRow({ snapshot, style }: { snapshot?: CodexRadarSnapshot | null; style: CSSProperties }) {
  if (!snapshot) {
    return (
      <div className="floating-row floating-radar" style={style}>
        <span>Radar 待读取</span>
        <strong>--</strong>
      </div>
    );
  }

  const primary = primaryModelRow(snapshot.modelIq);
  const secondary = secondaryModelRows(snapshot.modelIq).slice(0, 3);
  const probability = snapshot.prediction.probability24H ?? snapshot.prediction.probability24h;
  const probability48 = snapshot.prediction.probability48H ?? snapshot.prediction.probability48h;

  return (
    <div className="floating-row floating-radar" style={style}>
      <div className="floating-radar-action">
        <span>动作 {snapshot.recommendedAction || "--"}</span>
        <em>24h {percentText(probability)} · 48h {percentText(probability48)}</em>
      </div>
      <div className="floating-radar-iq">
        <strong>
          IQ {displayRadarNumber(primary.point.score, 1)}
          <em>{compactModelName(primary.label)}</em>
        </strong>
        <p className="floating-radar-models">
          {secondary.length > 0
            ? secondary.map((row) => (
                <span key={row.label}>
                  {compactModelName(row.label)} {displayRadarNumber(row.point.score, 1)}
                </span>
              ))
            : (
                <span>
                  {primary.point.passed}/{primary.point.tasks} · {compactRadarTokens(primary.point.totalTokens)}
                </span>
              )}
        </p>
      </div>
    </div>
  );
}

function compactModelName(label: string): string {
  return label
    .replace(/^GPT-/, "")
    .replace(/\bmedium\b/i, "med")
    .replace(/\bxhigh\b/i, "xh")
    .replace(/\bhigh\b/i, "high")
    .trim();
}

function compactRadarTokens(value: number): string {
  if (!Number.isFinite(value) || value <= 0) {
    return "--";
  }
  if (value >= 100_000_000) {
    return `${displayRadarNumber(value / 100_000_000, 1)}亿`;
  }
  if (value >= 10_000) {
    return `${displayRadarNumber(value / 10_000, 1)}万`;
  }
  return `${Math.round(value)}`;
}

function UnreadEffect({ effect }: { effect: FloatingUnreadEffect }) {
  if (effect === "ripple") {
    return (
      <span className="unread-effect unread-effect--ripple" aria-hidden="true">
        <FloatingUnreadRippleCanvas />
      </span>
    );
  }

  return <span className={`unread-effect unread-effect--${effect}`} aria-hidden="true" />;
}

function FloatingUnreadRippleCanvas() {
  const canvasRef = useRef<HTMLCanvasElement | null>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) {
      return undefined;
    }

    const cycleDurationMs = 3_250;
    const targetFrameIntervalMs = 1_000 / 30;
    let renderState = refreshUnreadRippleLayout(canvas);
    const startedAt = performance.now();

    const paint = () => {
      if (!renderState) {
        return;
      }
      const elapsed = performance.now() - startedAt;
      drawUnreadRippleCanvasFrame(renderState, (elapsed % cycleDurationMs) / cycleDurationMs);
    };

    paint();
    const tickTimer = window.setInterval(paint, targetFrameIntervalMs);
    const colorTimer = window.setInterval(() => {
      if (renderState) {
        renderState.color = readFloatingEffectColor(canvas);
      }
    }, 500);

    const resizeObserver = new ResizeObserver(() => {
      renderState = refreshUnreadRippleLayout(canvas, renderState);
      paint();
    });
    resizeObserver.observe(canvas);

    return () => {
      window.clearInterval(tickTimer);
      window.clearInterval(colorTimer);
      resizeObserver.disconnect();
    };
  }, []);

  return <canvas className="unread-ripple-canvas" ref={canvasRef} />;
}

interface UnreadRippleRenderState {
  context: CanvasRenderingContext2D;
  width: number;
  height: number;
  scale: number;
  color: [number, number, number];
  clipRadius: number;
}

function refreshUnreadRippleLayout(
  canvas: HTMLCanvasElement,
  previous?: UnreadRippleRenderState,
): UnreadRippleRenderState | undefined {
  const rect = canvas.getBoundingClientRect();
  const width = Math.max(1, rect.width);
  const height = Math.max(1, rect.height);
  const scale = Math.max(1, Math.min(2, window.devicePixelRatio || 1));

  const pixelWidth = Math.ceil(width * scale);
  const pixelHeight = Math.ceil(height * scale);
  if (canvas.width !== pixelWidth || canvas.height !== pixelHeight) {
    canvas.width = pixelWidth;
    canvas.height = pixelHeight;
  }
  canvas.style.width = `${width}px`;
  canvas.style.height = `${height}px`;

  const context = previous?.context ?? canvas.getContext("2d");
  if (!context) {
    return undefined;
  }

  return {
    context,
    width,
    height,
    scale,
    color: readFloatingEffectColor(canvas),
    clipRadius: readCanvasBorderRadius(canvas, width, height),
  };
}

function drawUnreadRippleCanvasFrame(state: UnreadRippleRenderState, phase: number) {
  const { color, context, height, scale, width } = state;

  context.save();
  context.setTransform(scale, 0, 0, scale, 0, 0);
  context.clearRect(0, 0, width, height);
  roundedRectPath(context, 0, 0, width, height, state.clipRadius);
  context.clip();

  const pulse = (Math.sin(phase * Math.PI * 2) + 1) / 2;
  context.fillStyle = rgba(color, 0.06 + 0.048 * pulse);
  context.fillRect(0, 0, width, height);

  const activeFraction = 0.92;
  if (phase < activeFraction) {
    drawCircularRippleReflections(context, width, height, color, phase / activeFraction);
  }

  context.restore();
}

function drawCircularRippleReflections(
  context: CanvasRenderingContext2D,
  width: number,
  height: number,
  color: [number, number, number],
  phase: number,
) {
  const fadeOut = smoothPulseFade(phase);
  const center = { x: width / 2, y: height / 2 };
  const maxRadius = Math.max(Math.max(width, height) * 1.08, height * 2.65);
  const baseRadius = maxRadius * easeOutSine(phase);
  const waveAlpha = fadeOut * (1.04 - 0.26 * phase);
  const scale = Math.max(0.65, Math.min(1.4, width / 292));
  const rings = [
    { offset: 0, alpha: 1, thickness: 2.4 },
    { offset: -8.4 * scale, alpha: 0.66, thickness: 2.08 },
    { offset: -16.8 * scale, alpha: 0.46, thickness: 1.82 },
    { offset: -25.2 * scale, alpha: 0.34, thickness: 1.58 },
    { offset: -33.6 * scale, alpha: 0.24, thickness: 1.36 },
  ];
  const sources = rippleSources(width, height, center);

  for (const ring of rings) {
    const radius = baseRadius + ring.offset;
    if (radius <= 1.4 * scale) {
      continue;
    }

    for (const source of sources) {
      const reflectionFade = source.isDirect
        ? 1
        : smoothStep((radius - source.arrivalDistance) / Math.max(12 * scale, 1));
      if (reflectionFade <= 0.01) {
        continue;
      }
      const alpha = waveAlpha * ring.alpha * source.strength * reflectionFade;
      drawCircularRing(context, color, source.x, source.y, radius, ring.thickness * scale, alpha);
    }
  }
}

function rippleSources(width: number, height: number, center: { x: number; y: number }) {
  return [
    { x: center.x, y: center.y, arrivalDistance: 0, strength: 1, isDirect: true },
    { x: center.x, y: -center.y, arrivalDistance: center.y, strength: 0.84, isDirect: false },
    { x: center.x, y: height + (height - center.y), arrivalDistance: height - center.y, strength: 0.84, isDirect: false },
    { x: center.x, y: center.y - 2 * height, arrivalDistance: 2 * height - center.y, strength: 0.52, isDirect: false },
    { x: center.x, y: center.y + 2 * height, arrivalDistance: height + center.y, strength: 0.52, isDirect: false },
    { x: -center.x, y: center.y, arrivalDistance: center.x, strength: 0.66, isDirect: false },
    { x: width + (width - center.x), y: center.y, arrivalDistance: width - center.x, strength: 0.66, isDirect: false },
  ];
}

function drawCircularRing(
  context: CanvasRenderingContext2D,
  color: [number, number, number],
  x: number,
  y: number,
  radius: number,
  thickness: number,
  alpha: number,
) {
  if (alpha <= 0.006) {
    return;
  }
  context.save();
  context.beginPath();
  context.arc(x, y, Math.max(radius + thickness / 2, 0.2), 0, Math.PI * 2);
  context.arc(x, y, Math.max(radius - thickness / 2, 0.1), 0, Math.PI * 2, true);
  context.fillStyle = rgba(color, alpha * 1.12);
  context.fill("evenodd");

  context.beginPath();
  context.arc(x, y, radius, 0, Math.PI * 2);
  context.strokeStyle = `rgba(255, 255, 255, ${alpha * 0.34})`;
  context.lineWidth = Math.max(0.18, 0.24 * thickness);
  context.stroke();
  context.restore();
}

function roundedRectPath(
  context: CanvasRenderingContext2D,
  x: number,
  y: number,
  width: number,
  height: number,
  radius: number,
) {
  const corner = Math.min(radius, width / 2, height / 2);
  context.beginPath();
  context.moveTo(x + corner, y);
  context.lineTo(x + width - corner, y);
  context.quadraticCurveTo(x + width, y, x + width, y + corner);
  context.lineTo(x + width, y + height - corner);
  context.quadraticCurveTo(x + width, y + height, x + width - corner, y + height);
  context.lineTo(x + corner, y + height);
  context.quadraticCurveTo(x, y + height, x, y + height - corner);
  context.lineTo(x, y + corner);
  context.quadraticCurveTo(x, y, x + corner, y);
  context.closePath();
}

function readFloatingEffectColor(element: HTMLElement): [number, number, number] {
  const computed = getComputedStyle(element);
  const raw = computed.getPropertyValue("--floating-effect-rgb").trim();
  const values = raw
    .split(",")
    .map((part) => Number(part.trim()))
    .filter((part) => Number.isFinite(part));
  if (values.length >= 3) {
    return [values[0], values[1], values[2]];
  }
  return [31, 110, 210];
}

function readCanvasBorderRadius(canvas: HTMLCanvasElement, width: number, height: number) {
  const fallback = Math.max(8, Math.min(width, height) * 0.08);
  const rawRadius = getComputedStyle(canvas).borderTopLeftRadius;
  const radius = Number.parseFloat(rawRadius);
  if (!Number.isFinite(radius)) {
    return fallback;
  }
  return Math.max(0, Math.min(radius, width / 2, height / 2));
}

function rgba([red, green, blue]: [number, number, number], alpha: number) {
  return `rgba(${red}, ${green}, ${blue}, ${Math.max(0, Math.min(1, alpha))})`;
}

function easeOutSine(value: number) {
  return Math.sin(Math.max(0, Math.min(1, value)) * Math.PI / 2);
}

function smoothStep(value: number) {
  const clamped = Math.max(0, Math.min(1, value));
  return clamped * clamped * (3 - 2 * clamped);
}

function smoothPulseFade(value: number) {
  const fadeStart = 0.88;
  if (value <= fadeStart) {
    return 1;
  }
  const t = Math.max(0, Math.min(1, (value - fadeStart) / (1 - fadeStart)));
  return 1 - smoothStep(t);
}
