import { useLayoutEffect, useMemo, useRef, useState, type CSSProperties, type MouseEvent } from "react";
import {
  codexRadarDiagnosticLabel,
  displayRadarNumber,
  percentText,
  primaryModelRow,
  secondaryModelRows,
  type CodexRadarSnapshot,
} from "../domain/codexRadar/model";
import { formatLiveRateValue, rateFillStyle, sanitizeRateFullScale } from "../components/liveRate/rateDisplay";
import type { FloatingContentGroup, FloatingPanelSnapshot, FloatingUnreadEffect, FloatingWindowSettings } from "../types/dashboard";
import { embedsUsageStatusInRateRow, layoutFloatingContentGroups } from "./floatingContent";
import { floatingRateBarStatusText, floatingStandaloneStatusText } from "./floatingPanelLabels";
import { floatingTextPaletteForGroup } from "./floatingTextPalette";

interface FloatingPanelSurfaceProps {
  settings: FloatingWindowSettings;
  snapshot: FloatingPanelSnapshot;
  radarSnapshot?: CodexRadarSnapshot | null;
  unreadEffect?: FloatingUnreadEffect;
  onClose?: () => void;
  onDragStart?: (event: MouseEvent<HTMLElement>) => void;
  onOpenDashboard?: () => void;
}

function clampPercent(value: number): number {
  if (!Number.isFinite(value)) {
    return 0;
  }
  return Math.min(100, Math.max(0, value * 100));
}

function FloatingQuotaBar({
  availability,
  label,
  remainingPercent,
}: {
  availability: "measured" | "unavailable";
  label: string;
  remainingPercent: number | null;
}) {
  if (availability !== "measured" || typeof remainingPercent !== "number" || !Number.isFinite(remainingPercent)) {
    return (
      <span className="floating-quota-bar floating-quota-bar--unavailable" role="status" aria-label={`${label}，额度待读取`}>
        <span className="floating-quota-track" aria-hidden="true" />
        <span className="floating-quota-label">{label}</span>
      </span>
    );
  }
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
  const scaleLimit = sanitizeRateFullScale(fullScale || snapshot.maxTokensPerSecond || 200);
  const hasStatusText = typeof statusText === "string" && statusText.length > 0;

  return (
    <span
      className={`floating-rate-meter ${hasStatusText ? "floating-rate-meter--with-status" : "floating-rate-meter--solo"}`}
      role="meter"
      aria-label={`实时速率 ${formatLiveRateValue(snapshot.tokensPerSecond)} tok/s，满格 ${Math.round(scaleLimit)} tok/s`}
      aria-valuemin={0}
      aria-valuemax={Math.round(scaleLimit)}
      aria-valuenow={Number(formatLiveRateValue(snapshot.tokensPerSecond))}
      style={rateFillStyle(snapshot.tokensPerSecond, scaleLimit)}
    >
      {hasStatusText ? <FloatingStatusText text={statusText} /> : null}
      <span className="floating-rate-track" aria-hidden="true">
        <i className="rate-fill" />
      </span>
    </span>
  );
}

function FloatingStatusText({ text }: { text: string }) {
  return (
    <span className="floating-status-text">
      <em>{text}</em>
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
  onOpenDashboard,
}: FloatingPanelSurfaceProps) {
  const shouldShowUnreadEffect = snapshot.unreadSummary.active && unreadEffect !== "off";
  const groups = layoutFloatingContentGroups(settings.contentVisibility);
  const attachedUsageStatus = embedsUsageStatusInRateRow(settings.contentVisibility);
  const rootPalette = floatingTextPaletteForGroup(settings, groups[0] ?? "rateAndBar", 0, Math.max(groups.length, 1));
  const effectRgb = useMemo(
    () => effectRgbFromGradient(settings.gradientStart, settings.gradientEnd),
    [settings.gradientStart, settings.gradientEnd],
  );
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
      onDoubleClick={onOpenDashboard}
      style={rootStyle}
      title={snapshot.unreadSummary.detail}
    >
      {shouldShowUnreadEffect ? <UnreadEffect effect={unreadEffect} effectRgb={effectRgb} /> : null}
      <button
        className="floating-close-button"
        type="button"
        aria-label="关闭悬浮窗"
        onMouseDown={(event) => event.stopPropagation()}
        onDoubleClick={(event) => event.stopPropagation()}
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
          <span className="floating-rate-readout" aria-label={`${formatLiveRateValue(snapshot.tokensPerSecond)} tok/s`}>
            <strong>{formatLiveRateValue(snapshot.tokensPerSecond)}</strong>
            <span>tok/s</span>
          </span>
          <FloatingRateMeter
            fullScale={settings.tokenRateFullScale}
            snapshot={snapshot}
            statusText={attachedUsageStatus ? floatingRateBarStatusText(snapshot) : undefined}
          />
        </div>
      );
    case "usageStatus":
      return (
        <div className="floating-row floating-usage-status" style={style}>
          <span className="floating-usage-status-card">
            <FloatingStatusText
              text={floatingStandaloneStatusText(snapshot)}
            />
          </span>
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
          <FloatingQuotaBar
            availability={snapshot.fiveHourAvailability}
            label={snapshot.fiveHourLabel}
            remainingPercent={snapshot.fiveHourRemainingPercent}
          />
          <FloatingQuotaBar
            availability={snapshot.sevenDayAvailability}
            label={snapshot.sevenDayLabel}
            remainingPercent={snapshot.sevenDayRemainingPercent}
          />
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
  const secondaryText = floatingRadarSecondaryIQText(snapshot);
  const diagnosticLabel = codexRadarDiagnosticLabel(snapshot);
  const probability = snapshot.prediction.probability24H ?? snapshot.prediction.probability24h;
  const probability48 = snapshot.prediction.probability48H ?? snapshot.prediction.probability48h;

  return (
    <div className="floating-row floating-radar" style={style}>
      <div className="floating-radar-action">
        <span>{diagnosticLabel ? `${diagnosticLabel} · ` : ""}动作 {snapshot.recommendedAction || "--"}</span>
        <em>24h {percentText(probability)} · 48h {percentText(probability48)}</em>
      </div>
      <div className="floating-radar-iq">
        <strong>
          IQ {displayRadarNumber(primary.point.score, 1)}
          <em>{floatingRadarPrimaryModelLabel(primary.label)}</em>
        </strong>
        <p className="floating-radar-models">{secondaryText}</p>
      </div>
    </div>
  );
}

function floatingRadarSecondaryIQText(snapshot: CodexRadarSnapshot): string {
  const rows = uniqueFloatingRadarRows(secondaryModelRows(snapshot.modelIq), 2);
  if (rows.length === 0) {
    const primary = primaryModelRow(snapshot.modelIq);
    return `${primary.point.passed}/${primary.point.tasks} 通过`;
  }
  return rows
    .map((row) => `${floatingRadarShortModelLabel(row.label)} ${displayRadarNumber(row.point.score, 1)}`)
    .join("  ");
}

function uniqueFloatingRadarRows(rows: ReturnType<typeof secondaryModelRows>, limit: number): ReturnType<typeof secondaryModelRows> {
  const seen = new Set<string>();
  const result: ReturnType<typeof secondaryModelRows> = [];
  for (const row of rows) {
    const key = `${floatingRadarShortModelLabel(row.label)}:${row.point.model ?? ""}:${row.point.reasoningEffort ?? ""}`;
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);
    result.push(row);
    if (result.length >= limit) {
      break;
    }
  }
  return result;
}

function floatingRadarPrimaryModelLabel(label: string): string {
  return label
    .replace(/\bxhigh\b/i, "X high")
    .trim();
}

function floatingRadarShortModelLabel(label: string): string {
  return label
    .replace(/^GPT-5\.5\s+/i, "")
    .replace(/^GPT-5\.4\s+/i, "5.4 ")
    .replace(/\bxhigh\b/i, "X high")
    .trim();
}

const RIPPLE_CYCLE_SECONDS = 3.25;
const RIPPLE_ACTIVE_FRACTION = 0.92;
const RIPPLE_TARGET_FPS = 30;
const RIPPLE_MAX_FRAME_SEQUENCE_BYTES = 48 * 1024 * 1024;
const RIPPLE_MIN_BACKING_SCALE = 1;
const RIPPLE_MAX_BACKING_SCALE = 2;

interface RippleAtlas {
  descriptor: string;
  frameCount: number;
  frameShiftPercent: number;
  url: string;
}

interface RippleRGB {
  red: number;
  green: number;
  blue: number;
}

interface RippleRenderRequest {
  backingScale: number;
  color: RippleRGB;
  cornerRadius: number;
  height: number;
  scale: number;
  width: number;
}

interface RippleSource {
  arrivalDistance: number;
  isDirect: boolean;
  point: { x: number; y: number };
  strength: number;
}

function UnreadEffect({ effect, effectRgb }: { effect: FloatingUnreadEffect; effectRgb: RippleRGB }) {
  if (effect === "ripple") {
    return (
      <span className="unread-effect unread-effect--ripple" aria-hidden="true">
        <FloatingUnreadRippleSprite effectRgb={effectRgb} />
      </span>
    );
  }

  return <span className={`unread-effect unread-effect--${effect}`} aria-hidden="true" />;
}

function FloatingUnreadRippleSprite({ effectRgb }: { effectRgb: RippleRGB }) {
  const spriteRef = useRef<HTMLSpanElement | null>(null);
  const atlasUrlRef = useRef<string | null>(null);
  const descriptorRef = useRef("");
  const pendingDescriptorRef = useRef("");
  const renderGenerationRef = useRef(0);
  const [atlas, setAtlas] = useState<RippleAtlas | null>(null);
  const normalizedEffectRgb = useMemo(() => normalizeRippleRGB(effectRgb), [effectRgb]);

  useLayoutEffect(() => () => {
    if (atlasUrlRef.current) {
      URL.revokeObjectURL(atlasUrlRef.current);
      atlasUrlRef.current = null;
    }
  }, []);

  useLayoutEffect(() => {
    const element = spriteRef.current;
    if (!element) {
      return undefined;
    }

    let disposed = false;
    const renderIfNeeded = async () => {
      const request = readRippleRenderRequest(element, normalizedEffectRgb);
      if (!request) {
        return;
      }
      const descriptor = rippleDescriptor(request);
      if (descriptor === descriptorRef.current || descriptor === pendingDescriptorRef.current) {
        return;
      }
      pendingDescriptorRef.current = descriptor;
      const generation = renderGenerationRef.current + 1;
      renderGenerationRef.current = generation;
      const nextAtlas = await renderRippleAtlas(request, descriptor);
      if (pendingDescriptorRef.current === descriptor) {
        pendingDescriptorRef.current = "";
      }
      if (disposed || !nextAtlas || renderGenerationRef.current !== generation) {
        if (nextAtlas) {
          URL.revokeObjectURL(nextAtlas.url);
        }
        return;
      }
      descriptorRef.current = descriptor;
      if (atlasUrlRef.current) {
        URL.revokeObjectURL(atlasUrlRef.current);
      }
      atlasUrlRef.current = nextAtlas.url;
      setAtlas(nextAtlas);
    };

    void renderIfNeeded();
    const resizeObserver = new ResizeObserver(() => {
      void renderIfNeeded();
    });
    resizeObserver.observe(element);
    return () => {
      disposed = true;
      resizeObserver.disconnect();
    };
  }, [normalizedEffectRgb]);

  return (
    <span
      className="unread-ripple-sprite"
      ref={spriteRef}
      style={
        atlas
          ? ({
              "--ripple-frame-count": atlas.frameCount,
              "--ripple-frame-shift": `${atlas.frameShiftPercent}%`,
            } as CSSProperties)
          : undefined
      }
    >
      {atlas ? (
        <img
          alt=""
          aria-hidden="true"
          className="unread-ripple-image"
          draggable={false}
          src={atlas.url}
          style={{ animationTimingFunction: `steps(${Math.max(1, atlas.frameCount - 1)})` } as CSSProperties}
        />
      ) : null}
    </span>
  );
}

function readRippleRenderRequest(element: HTMLElement, effectRgb?: RippleRGB): RippleRenderRequest | null {
  const rect = element.getBoundingClientRect();
  const width = Math.max(1, rect.width);
  const height = Math.max(1, rect.height);
  const frameCount = rippleBaseFrameCount();
  const preferredScale = window.devicePixelRatio || RIPPLE_MAX_BACKING_SCALE;
  const backingScale = cappedRippleBackingScale(width, height, preferredScale, frameCount);
  if (!backingScale) {
    return null;
  }
  const computed = getComputedStyle(element);
  const containerComputed = element.parentElement ? getComputedStyle(element.parentElement) : computed;
  return {
    backingScale,
    color: effectRgb ?? readFloatingEffectRGB(computed),
    cornerRadius: readRippleCornerRadius(containerComputed, width, height),
    height,
    scale: readFloatingScale(computed),
    width,
  };
}

async function renderRippleAtlas(request: RippleRenderRequest, descriptor: string): Promise<RippleAtlas | null> {
  const baseFrameCount = rippleBaseFrameCount();
  const frameCount = baseFrameCount + 1;
  const pixelWidth = Math.max(1, Math.ceil(request.width * request.backingScale));
  const pixelHeight = Math.max(1, Math.ceil(request.height * request.backingScale));
  const canvas = document.createElement("canvas");
  canvas.width = pixelWidth;
  canvas.height = pixelHeight * frameCount;
  const context = canvas.getContext("2d");
  if (!context) {
    return null;
  }

  for (let index = 0; index < frameCount; index += 1) {
    const phase = index === baseFrameCount ? 0 : index / baseFrameCount;
    context.save();
    context.translate(0, index * pixelHeight);
    context.scale(request.backingScale, request.backingScale);
    drawRippleFrame(context, request, phase);
    context.restore();
  }

  const url = await canvasToObjectURL(canvas);
  if (!url) {
    return null;
  }

  return {
    descriptor,
    frameCount,
    frameShiftPercent: -((frameCount - 1) / frameCount) * 100,
    url,
  };
}

function canvasToObjectURL(canvas: HTMLCanvasElement): Promise<string | null> {
  return new Promise((resolve) => {
    canvas.toBlob((blob) => {
      resolve(blob ? URL.createObjectURL(blob) : null);
    }, "image/png");
  });
}

function drawRippleFrame(context: CanvasRenderingContext2D, request: RippleRenderRequest, phase: number) {
  context.save();
  roundedRectPath(context, 0, 0, request.width, request.height, request.cornerRadius);
  context.clip();

  const pulse = (Math.sin(phase * Math.PI * 2) + 1) / 2;
  context.fillStyle = rgba(request.color, 0.020 + 0.014 * pulse);
  context.fillRect(0, 0, request.width, request.height);

  if (phase < RIPPLE_ACTIVE_FRACTION) {
    drawCircularRippleReflections(context, request, phase / RIPPLE_ACTIVE_FRACTION);
  }
  context.restore();
}

function drawCircularRippleReflections(context: CanvasRenderingContext2D, request: RippleRenderRequest, phase: number) {
  const fadeOut = smoothPulseFade(phase);
  const center = { x: request.width / 2, y: request.height / 2 };
  const maxRadius = Math.max(Math.max(request.width, request.height) * 0.82, request.height * 2.25);
  const baseRadius = maxRadius * easeOutSine(phase);
  const waveAlpha = fadeOut * (1.04 - 0.26 * phase);
  const rings = [
    { offset: 0 * request.scale, alpha: 1.00, thickness: 2.40 },
    { offset: -6.2 * request.scale, alpha: 0.66, thickness: 2.08 },
    { offset: -12.4 * request.scale, alpha: 0.46, thickness: 1.82 },
    { offset: -18.6 * request.scale, alpha: 0.34, thickness: 1.58 },
    { offset: -24.8 * request.scale, alpha: 0.24, thickness: 1.36 },
  ];
  const sources = rippleSources(request, center);

  for (const ring of rings) {
    const radius = baseRadius + ring.offset;
    if (radius <= 1.4 * request.scale) {
      continue;
    }
    const thickness = ring.thickness * request.scale;
    for (const source of sources) {
      const reflectionFade = source.isDirect
        ? 1
        : smoothStep((radius - source.arrivalDistance) / Math.max(12 * request.scale, 1));
      if (reflectionFade <= 0.01) {
        continue;
      }
      const alpha = waveAlpha * ring.alpha * source.strength * reflectionFade;
      drawCircularRing(context, request.color, request.scale, source.point, radius, thickness, alpha);
    }
  }

}

function rippleSources(request: RippleRenderRequest, center: { x: number; y: number }): RippleSource[] {
  return [
    { point: center, arrivalDistance: 0, strength: 1.00, isDirect: true },
    { point: { x: center.x, y: -center.y }, arrivalDistance: center.y, strength: 0.84, isDirect: false },
    {
      point: { x: center.x, y: request.height + (request.height - center.y) },
      arrivalDistance: request.height - center.y,
      strength: 0.84,
      isDirect: false,
    },
    {
      point: { x: center.x, y: center.y - 2 * request.height },
      arrivalDistance: 2 * request.height - center.y,
      strength: 0.52,
      isDirect: false,
    },
    {
      point: { x: center.x, y: center.y + 2 * request.height },
      arrivalDistance: request.height + center.y,
      strength: 0.52,
      isDirect: false,
    },
    { point: { x: -center.x, y: center.y }, arrivalDistance: center.x, strength: 0.66, isDirect: false },
    {
      point: { x: request.width + (request.width - center.x), y: center.y },
      arrivalDistance: request.width - center.x,
      strength: 0.66,
      isDirect: false,
    },
  ];
}

function drawCircularRing(
  context: CanvasRenderingContext2D,
  color: RippleRGB,
  scale: number,
  center: { x: number; y: number },
  radius: number,
  thickness: number,
  alpha: number,
) {
  if (alpha <= 0.006) {
    return;
  }
  const outerRadius = Math.max(radius + thickness / 2, 0.2);
  const innerRadius = Math.max(radius - thickness / 2, 0.1);

  context.save();
  context.beginPath();
  context.arc(center.x, center.y, outerRadius, 0, Math.PI * 2);
  context.arc(center.x, center.y, innerRadius, 0, Math.PI * 2, true);
  context.fillStyle = rgba(color, alpha * 0.54);
  context.fill("evenodd");

  context.beginPath();
  context.arc(center.x, center.y, radius, 0, Math.PI * 2);
  context.strokeStyle = `rgba(255, 255, 255, ${alpha * 0.17})`;
  context.lineWidth = Math.max(0.18, 0.24 * scale);
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

function rippleBaseFrameCount(): number {
  return Math.max(1, Math.ceil(RIPPLE_CYCLE_SECONDS * RIPPLE_TARGET_FPS));
}

function cappedRippleBackingScale(width: number, height: number, preferredScale: number, frameCount: number): number | null {
  const clampedPreferred = Math.min(Math.max(preferredScale, RIPPLE_MIN_BACKING_SCALE), RIPPLE_MAX_BACKING_SCALE);
  if (estimatedRippleBytes(width, height, clampedPreferred, frameCount) <= RIPPLE_MAX_FRAME_SEQUENCE_BYTES) {
    return clampedPreferred;
  }

  const logicalPixels = Math.max(width * height, 1);
  let cappedScale = Math.min(
    clampedPreferred,
    Math.sqrt(RIPPLE_MAX_FRAME_SEQUENCE_BYTES / (logicalPixels * 4 * Math.max(frameCount, 1))),
  ) * 0.99;
  while (
    cappedScale >= RIPPLE_MIN_BACKING_SCALE
    && estimatedRippleBytes(width, height, cappedScale, frameCount) > RIPPLE_MAX_FRAME_SEQUENCE_BYTES
  ) {
    cappedScale -= 0.01;
  }
  if (
    cappedScale >= RIPPLE_MIN_BACKING_SCALE
    && estimatedRippleBytes(width, height, cappedScale, frameCount) <= RIPPLE_MAX_FRAME_SEQUENCE_BYTES
  ) {
    return cappedScale;
  }
  return null;
}

function estimatedRippleBytes(width: number, height: number, backingScale: number, frameCount: number): number {
  const pixelWidth = Math.max(1, Math.ceil(width * backingScale));
  const pixelHeight = Math.max(1, Math.ceil(height * backingScale));
  return pixelWidth * pixelHeight * 4 * Math.max(1, frameCount);
}

function rippleDescriptor(request: RippleRenderRequest): string {
  const color = request.color;
  return [
    Math.ceil(request.width * request.backingScale),
    Math.ceil(request.height * request.backingScale),
    Math.round(color.red),
    Math.round(color.green),
    Math.round(color.blue),
    Math.round(request.cornerRadius * 100),
    Math.round(request.scale * 100),
  ].join(":");
}

function readFloatingEffectRGB(computed: CSSStyleDeclaration): RippleRGB {
  const raw = computed.getPropertyValue("--floating-effect-rgb").trim();
  const values = raw.split(",").map((value) => Number(value.trim()));
  return {
    red: Number.isFinite(values[0]) ? values[0] : 31,
    green: Number.isFinite(values[1]) ? values[1] : 110,
    blue: Number.isFinite(values[2]) ? values[2] : 210,
  };
}

function readFloatingScale(computed: CSSStyleDeclaration): number {
  const raw = Number(computed.getPropertyValue("--floating-scale").trim());
  return Number.isFinite(raw) && raw > 0 ? raw : 1;
}

function effectRgbFromGradient(start: string, end: string): RippleRGB {
  const mixed = mixRippleRGB(parseRippleHexColor(start), parseRippleHexColor(end), 0.58);
  return normalizeRippleRGB({
    red: Math.max(0, Math.round(mixed.red * 0.72)),
    green: Math.max(0, Math.round(mixed.green * 0.82)),
    blue: Math.min(255, Math.round(mixed.blue * 1.08 + 18)),
  });
}

function parseRippleHexColor(value: string): RippleRGB {
  const match = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(value.trim());
  if (!match) {
    return { red: 31, green: 110, blue: 210 };
  }
  return {
    red: Number.parseInt(match[1], 16),
    green: Number.parseInt(match[2], 16),
    blue: Number.parseInt(match[3], 16),
  };
}

function mixRippleRGB(start: RippleRGB, end: RippleRGB, endWeight: number): RippleRGB {
  const startWeight = 1 - endWeight;
  return {
    red: start.red * startWeight + end.red * endWeight,
    green: start.green * startWeight + end.green * endWeight,
    blue: start.blue * startWeight + end.blue * endWeight,
  };
}

function normalizeRippleRGB(color: RippleRGB): RippleRGB {
  return {
    red: clampColorChannel(color.red),
    green: clampColorChannel(color.green),
    blue: clampColorChannel(color.blue),
  };
}

function clampColorChannel(value: number): number {
  if (!Number.isFinite(value)) {
    return 0;
  }
  return Math.min(255, Math.max(0, Math.round(value)));
}

function readRippleCornerRadius(computed: CSSStyleDeclaration, width: number, height: number): number {
  const raw = Number.parseFloat(computed.borderTopLeftRadius);
  if (Number.isFinite(raw) && raw > 0) {
    return Math.min(raw, width / 2, height / 2);
  }
  return Math.min(14, width / 2, height / 2);
}

function rgba(color: RippleRGB, alpha: number): string {
  return `rgba(${color.red}, ${color.green}, ${color.blue}, ${Math.min(Math.max(alpha, 0), 1)})`;
}

function easeOutSine(value: number): number {
  const clamped = Math.min(Math.max(value, 0), 1);
  return Math.sin(clamped * Math.PI / 2);
}

function smoothStep(value: number): number {
  const clamped = Math.min(Math.max(value, 0), 1);
  return clamped * clamped * (3 - 2 * clamped);
}

function smoothPulseFade(value: number): number {
  const fadeStart = 0.80;
  if (value <= fadeStart) {
    return 1;
  }
  const t = Math.min(Math.max((value - fadeStart) / (1 - fadeStart), 0), 1);
  return 1 - smoothStep(t);
}
