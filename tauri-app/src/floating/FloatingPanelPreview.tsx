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
                <span>{primary.point.passed}/{primary.point.tasks} 通过</span>
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

const RIPPLE_RINGS = [
  { offset: 0, alpha: 1, thickness: 2.4 },
  { offset: -8.4, alpha: 0.66, thickness: 2.08 },
  { offset: -16.8, alpha: 0.46, thickness: 1.82 },
  { offset: -25.2, alpha: 0.34, thickness: 1.58 },
  { offset: -33.6, alpha: 0.24, thickness: 1.36 },
];

const RIPPLE_SOURCES = [
  { x: 50, y: 50, strength: 1, delay: 0 },
  { x: 50, y: -50, strength: 0.84, delay: 0.24 },
  { x: 50, y: 150, strength: 0.84, delay: 0.24 },
  { x: 50, y: -150, strength: 0.52, delay: 0.48 },
  { x: 50, y: 250, strength: 0.52, delay: 0.48 },
  { x: -50, y: 50, strength: 0.66, delay: 0.34 },
  { x: 150, y: 50, strength: 0.66, delay: 0.34 },
];

function UnreadEffect({ effect }: { effect: FloatingUnreadEffect }) {
  if (effect === "ripple") {
    return (
      <span className="unread-effect unread-effect--ripple" aria-hidden="true">
        <FloatingUnreadRippleLayers />
      </span>
    );
  }

  return <span className={`unread-effect unread-effect--${effect}`} aria-hidden="true" />;
}

function FloatingUnreadRippleLayers() {
  return (
    <>
      {RIPPLE_SOURCES.map((source, sourceIndex) => (
        <span
          className="unread-ripple-source"
          data-ripple-source={sourceIndex}
          key={`${source.x}-${source.y}-${sourceIndex}`}
          style={
            {
              "--ripple-source-x": `${source.x}%`,
              "--ripple-source-y": `${source.y}%`,
              "--ripple-source-strength": source.strength,
              "--ripple-source-delay": `${source.delay}s`,
            } as CSSProperties
          }
        >
          {RIPPLE_RINGS.map((ring, ringIndex) => (
            <span
              className={`unread-ripple-ring unread-ripple-ring--${ringIndex}`}
              key={ringIndex}
              style={
                {
                  "--ripple-ring-offset": `${ring.offset}px`,
                  "--ripple-ring-alpha": ring.alpha,
                  "--ripple-ring-thickness": `${ring.thickness}px`,
                } as CSSProperties
              }
            />
          ))}
        </span>
      ))}
    </>
  );
}
