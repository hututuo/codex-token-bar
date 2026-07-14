import { useLayoutEffect, useRef, useState, type CSSProperties, type ReactNode, type RefObject } from "react";
import {
  FLOATING_CONTENT_LABELS,
  FLOATING_CONTENT_GROUPS,
  moveFloatingContent,
  sanitizeFloatingContentVisibility,
} from "../../floating/floatingContent";
import type { FloatingWindowSettings } from "../../floating/floatingSettings";
import type { FloatingContentGroup, FloatingContentVisibility, FloatingPalettePatch, FloatingUnreadEffect, PlatformCapabilities } from "../../types/dashboard";
import { computeBoundedSettingsCalloutFrame, type CalloutFrame } from "./calloutPlacement";

const UNREAD_EFFECT_OPTIONS: Array<{ value: FloatingUnreadEffect; label: string }> = [
  { value: "off", label: "关" },
  { value: "ripple", label: "涟漪" },
  { value: "shimmer", label: "扫光" },
];

const UNREAD_EFFECT_DETAILS: Record<FloatingUnreadEffect, { title: string; subtitle: string }> = {
  off: { title: "关", subtitle: "不显示动效" },
  ripple: { title: "涟漪", subtitle: "有未读会话时显示圆形水波" },
  shimmer: { title: "扫光", subtitle: "有未读会话时显示柔和光带" },
};

type SettingsCallout = "palette" | "unread" | "content";
const CALLOUT_DIMENSIONS: Record<SettingsCallout, { width: number; estimatedHeight: number }> = {
  palette: { width: 340, estimatedHeight: 430 },
  unread: { width: 332, estimatedHeight: 260 },
  content: { width: 340, estimatedHeight: 390 },
};

interface LiveRateSettingsPanelProps {
  floatingSettings: FloatingWindowSettings;
  floatingEnabled: boolean;
  onFloatingGradientChange: (patch: FloatingPalettePatch) => void;
  onFloatingOpacityChange: (opacity: number) => void;
  onFloatingScaleChange: (scale: number) => void;
  onFloatingTextToneChange: (textTone: number) => void;
  onFloatingContentVisibilityChange: (contentVisibility: FloatingContentVisibility) => void;
  onFloatingUnreadEffectChange: (effect: FloatingUnreadEffect) => void;
  onToggleFloating: () => void;
  onToggleStatusTray: () => void;
  platform: PlatformCapabilities;
  statusTrayLiveTextEnabled: boolean;
}

export function LiveRateSettingsPanel({
  floatingEnabled,
  floatingSettings,
  onFloatingGradientChange,
  onFloatingOpacityChange,
  onFloatingScaleChange,
  onFloatingTextToneChange,
  onFloatingContentVisibilityChange,
  onFloatingUnreadEffectChange,
  onToggleFloating,
  onToggleStatusTray,
  platform,
  statusTrayLiveTextEnabled,
}: LiveRateSettingsPanelProps) {
  const [openCallout, setOpenCallout] = useState<SettingsCallout | null>(null);
  const [calloutFrame, setCalloutFrame] = useState<CalloutFrame | null>(null);
  const calloutRef = useRef<HTMLDivElement | null>(null);
  const paletteButtonRef = useRef<HTMLButtonElement | null>(null);
  const unreadButtonRef = useRef<HTMLButtonElement | null>(null);
  const contentButtonRef = useRef<HTMLButtonElement | null>(null);
  const opacityPercent = Math.round(floatingSettings.opacity * 100);
  const scalePercent = Math.round(floatingSettings.scale * 100);
  const opacityFill = ((opacityPercent - 40) / 60) * 100;
  const scaleFill = ((scalePercent - 90) / 48) * 100;
  const textToneValue = Math.round(floatingSettings.textTone * 100);
  const textToneFill = (textToneValue + 100) / 2;
  const textToneLabel = textToneValue < 0 ? "自动" : `${textToneValue}%`;
  const contentVisibility = sanitizeFloatingContentVisibility(floatingSettings.contentVisibility);
  const floatingAvailable = platform.floatingWindow.available;
  const floatingButtonLabel = floatingAvailable
    ? `悬浮窗：${floatingEnabled ? "开" : "关"}`
    : "悬浮窗待接入";
  const statusTrayLiveTextAvailable =
    platform.statusTray.available && platform.statusTrayLiveText.available;
  const statusTrayButtonLabel = statusTrayLiveTextAvailable
    ? `状态栏数字：${statusTrayLiveTextEnabled ? "开" : "关"}`
    : platform.statusTray.available
      ? "托盘图标已启用"
      : "状态栏待接入";
  const calloutStyle = calloutFrame ? {
    left: `${calloutFrame.left}px`,
    right: "auto",
    top: `${calloutFrame.top}px`,
    width: `${calloutFrame.width}px`,
    maxHeight: `${calloutFrame.maxHeight}px`,
  } as CSSProperties : undefined;

  useLayoutEffect(() => {
    if (!openCallout) {
      setCalloutFrame(null);
      return undefined;
    }

    const anchor =
      openCallout === "palette"
        ? paletteButtonRef.current
        : openCallout === "unread"
          ? unreadButtonRef.current
          : contentButtonRef.current;
    if (!anchor) {
      return undefined;
    }

    const updateFrame = () => {
      const rect = anchor.getBoundingClientRect();
      setCalloutFrame(computeBoundedSettingsCalloutFrame(
        rect,
        { width: window.innerWidth, height: window.innerHeight },
        CALLOUT_DIMENSIONS[openCallout],
      ));
    };

    updateFrame();
    window.addEventListener("resize", updateFrame);
    return () => window.removeEventListener("resize", updateFrame);
  }, [openCallout]);

  useLayoutEffect(() => {
    if (!openCallout) {
      return undefined;
    }

    const isInsideOpenCallout = (target: EventTarget | null) => {
      if (!(target instanceof Node)) {
        return false;
      }
      return Boolean(
        calloutRef.current?.contains(target)
          || paletteButtonRef.current?.contains(target)
          || unreadButtonRef.current?.contains(target)
          || contentButtonRef.current?.contains(target),
      );
    };

    const closeForOutsidePointer = (event: PointerEvent) => {
      if (!isInsideOpenCallout(event.target)) {
        setOpenCallout(null);
      }
    };
    const closeForOutsideFocus = (event: FocusEvent) => {
      if (!isInsideOpenCallout(event.target)) {
        setOpenCallout(null);
      }
    };
    const closeForEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        setOpenCallout(null);
      }
    };
    const closeForWindowBlur = () => {
      setOpenCallout(null);
    };

    window.addEventListener("pointerdown", closeForOutsidePointer, true);
    window.addEventListener("focusin", closeForOutsideFocus, true);
    window.addEventListener("keydown", closeForEscape, true);
    window.addEventListener("blur", closeForWindowBlur);
    return () => {
      window.removeEventListener("pointerdown", closeForOutsidePointer, true);
      window.removeEventListener("focusin", closeForOutsideFocus, true);
      window.removeEventListener("keydown", closeForEscape, true);
      window.removeEventListener("blur", closeForWindowBlur);
    };
  }, [openCallout]);

  return (
    <div className="settings-panel">
      <div className="settings-topline">
        <span className="settings-label">显示设置</span>
        <div className="settings-actions">
          <button
            className="live-toggle-button"
            disabled={!floatingAvailable}
            onClick={onToggleFloating}
            title={platform.floatingWindow.note}
            type="button"
          >
            {floatingButtonLabel}
          </button>
          <button
            className="live-toggle-button"
            disabled={!statusTrayLiveTextAvailable}
            onClick={onToggleStatusTray}
            title={
              statusTrayLiveTextAvailable
                ? platform.statusTrayLiveText.note
                : platform.statusTray.note
            }
            type="button"
          >
            {statusTrayButtonLabel}
          </button>
        </div>
      </div>
      <div className="floating-appearance-compact">
        <div className="floating-popup-buttons" aria-label="悬浮窗更多设置">
          <button
            ref={paletteButtonRef}
            aria-expanded={openCallout === "palette"}
            className={openCallout === "palette" ? "is-active" : ""}
            onClick={() => setOpenCallout((current) => current === "palette" ? null : "palette")}
            type="button"
          >
            调色盘 <span>⌄</span>
          </button>
          <button
            ref={unreadButtonRef}
            aria-expanded={openCallout === "unread"}
            className={openCallout === "unread" ? "is-active" : ""}
            onClick={() => setOpenCallout((current) => current === "unread" ? null : "unread")}
            type="button"
          >
            提醒 <span>⌄</span>
          </button>
          <button
            ref={contentButtonRef}
            aria-expanded={openCallout === "content"}
            className={openCallout === "content" ? "is-active" : ""}
            onClick={() => setOpenCallout((current) => current === "content" ? null : "content")}
            type="button"
          >
            内容 <span>⌄</span>
          </button>
        </div>
        <div className="floating-appearance-sliders">
          <label className="setting-slider">
            <span>透明度</span>
            <input
              max="100"
              min="40"
              onChange={(event) => onFloatingOpacityChange(Number(event.currentTarget.value) / 100)}
              style={{ "--range-fill": `${opacityFill}%` } as CSSProperties}
              type="range"
              value={opacityPercent}
            />
            <strong>{opacityPercent}%</strong>
          </label>
          <label className="setting-slider">
            <span>大小</span>
            <input
              max="138"
              min="90"
              onChange={(event) => onFloatingScaleChange(Number(event.currentTarget.value) / 100)}
              style={{ "--range-fill": `${scaleFill}%` } as CSSProperties}
              type="range"
              value={scalePercent}
            />
            <strong>{scalePercent}%</strong>
          </label>
        </div>
      </div>
      {openCallout === "palette" ? (
        <PaletteSettingsCallout
          calloutRef={calloutRef}
          calloutStyle={calloutStyle}
          floatingSettings={floatingSettings}
          onClose={() => setOpenCallout(null)}
          onFloatingGradientChange={onFloatingGradientChange}
        />
      ) : null}
      {openCallout === "unread" ? (
        <UnreadEffectCallout
          calloutRef={calloutRef}
          calloutStyle={calloutStyle}
          selected={floatingSettings.unreadEffect}
          onChange={(effect) => {
            onFloatingUnreadEffectChange(effect);
            setOpenCallout(null);
          }}
          onClose={() => setOpenCallout(null)}
        />
      ) : null}
      {openCallout === "content" ? (
        <ContentSettingsCallout
          calloutRef={calloutRef}
          calloutStyle={calloutStyle}
          contentVisibility={contentVisibility}
          textToneFill={textToneFill}
          textToneLabel={textToneLabel}
          textToneValue={textToneValue}
          onClose={() => setOpenCallout(null)}
          onFloatingContentVisibilityChange={onFloatingContentVisibilityChange}
          onFloatingTextToneChange={onFloatingTextToneChange}
        />
      ) : null}
    </div>
  );
}

interface SettingsCalloutShellProps {
  children: ReactNode;
  calloutRef: RefObject<HTMLDivElement | null>;
  calloutStyle?: CSSProperties;
  title: string;
  subtitle?: string;
  onClose: () => void;
}

function SettingsCalloutShell({ children, calloutRef, calloutStyle, title, subtitle, onClose }: SettingsCalloutShellProps) {
  return (
    <div className="settings-callout" role="dialog" aria-label={title} ref={calloutRef} style={calloutStyle}>
      <div className="settings-callout-head">
        <div>
          <strong>{title}</strong>
          {subtitle ? <span>{subtitle}</span> : null}
        </div>
        <button aria-label="关闭" onClick={onClose} type="button">×</button>
      </div>
      {children}
    </div>
  );
}

function PaletteSettingsCallout({
  calloutRef,
  floatingSettings,
  calloutStyle,
  onClose,
  onFloatingGradientChange,
}: {
  calloutRef: RefObject<HTMLDivElement | null>;
  floatingSettings: FloatingWindowSettings;
  calloutStyle?: CSSProperties;
  onClose: () => void;
  onFloatingGradientChange: LiveRateSettingsPanelProps["onFloatingGradientChange"];
}) {
  return (
    <SettingsCalloutShell calloutRef={calloutRef} calloutStyle={calloutStyle} title="悬浮窗样式" onClose={onClose}>
      <div className="settings-callout-section">
        <span>颜色</span>
        <label className="settings-callout-row">
          <span>起始色</span>
          <input
            aria-label="渐变起始颜色"
            onChange={(event) => onFloatingGradientChange({ gradientStart: event.currentTarget.value })}
            type="color"
            value={floatingSettings.gradientStart}
          />
        </label>
        <label className="settings-callout-row">
          <span>结束色</span>
          <input
            aria-label="渐变结束颜色"
            onChange={(event) => onFloatingGradientChange({ gradientEnd: event.currentTarget.value })}
            type="color"
            value={floatingSettings.gradientEnd}
          />
        </label>
      </div>
      <div className="settings-callout-section">
        <span>渐变</span>
        <label className="settings-callout-row">
          <span>方向</span>
          <select
            aria-label="渐变方向"
            onChange={(event) => onFloatingGradientChange({ gradientDirection: event.currentTarget.value as FloatingWindowSettings["gradientDirection"] })}
            value={floatingSettings.gradientDirection}
          >
            <option value="135deg">斜向</option>
            <option value="90deg">横向</option>
            <option value="180deg">纵向</option>
            <option value="45deg">反斜</option>
          </select>
        </label>
        <label className="settings-callout-row">
          <span>类型</span>
          <select
            aria-label="渐变类型"
            onChange={(event) => onFloatingGradientChange({ gradientType: event.currentTarget.value as FloatingWindowSettings["gradientType"] })}
            value={floatingSettings.gradientType}
          >
            <option value="linear">线性</option>
            <option value="radial">柔光</option>
            <option value="conic">环向</option>
          </select>
        </label>
      </div>
      <div className="settings-callout-section">
        <span>额度条</span>
        <div className="segmented floating-quota-color-modes" aria-label="额度条配色">
          {([
            ["adaptive", "随百分比"],
            ["fixed", "固定色"],
            ["panelGradient", "面板渐变"],
          ] as const).map(([mode, label]) => (
            <button
              aria-pressed={floatingSettings.quotaColorMode === mode}
              className={floatingSettings.quotaColorMode === mode ? "active" : ""}
              key={mode}
              onClick={() => onFloatingGradientChange({ quotaColorMode: mode })}
              type="button"
            >
              {label}
            </button>
          ))}
        </div>
        {floatingSettings.quotaColorMode === "fixed" ? (
          <label className="settings-callout-row">
            <span>固定颜色</span>
            <input
              aria-label="额度条固定颜色"
              onChange={(event) => onFloatingGradientChange({ quotaFixedColor: event.currentTarget.value })}
              type="color"
              value={floatingSettings.quotaFixedColor}
            />
          </label>
        ) : null}
      </div>
      <button
        className="settings-callout-reset"
        onClick={() => onFloatingGradientChange({
          gradientStart: "#ffffff",
          gradientEnd: "#daefff",
          gradientDirection: "135deg",
          gradientType: "linear",
          quotaColorMode: "adaptive",
          quotaFixedColor: "#1469cc",
        })}
        type="button"
      >
        恢复默认
      </button>
    </SettingsCalloutShell>
  );
}

function UnreadEffectCallout({
  calloutRef,
  calloutStyle,
  selected,
  onChange,
  onClose,
}: {
  calloutRef: RefObject<HTMLDivElement | null>;
  calloutStyle?: CSSProperties;
  selected: FloatingUnreadEffect;
  onChange: (effect: FloatingUnreadEffect) => void;
  onClose: () => void;
}) {
  return (
    <SettingsCalloutShell
      calloutRef={calloutRef}
      calloutStyle={calloutStyle}
      title="提醒样式"
      subtitle="有完成的会话还没点开时，悬浮窗用选中的样式提醒。"
      onClose={onClose}
    >
      <div className="settings-callout-options">
        {UNREAD_EFFECT_OPTIONS.map((option) => {
          const details = UNREAD_EFFECT_DETAILS[option.value];
          const active = selected === option.value;
          return (
            <button
              className={active ? "is-active" : ""}
              key={option.value}
              onClick={() => onChange(option.value)}
              type="button"
            >
              <span>{details.title}</span>
              <em>{details.subtitle}</em>
            </button>
          );
        })}
      </div>
    </SettingsCalloutShell>
  );
}

function ContentSettingsCallout({
  calloutRef,
  calloutStyle,
  contentVisibility,
  textToneFill,
  textToneLabel,
  textToneValue,
  onClose,
  onFloatingContentVisibilityChange,
  onFloatingTextToneChange,
}: {
  calloutRef: RefObject<HTMLDivElement | null>;
  calloutStyle?: CSSProperties;
  contentVisibility: FloatingContentVisibility;
  textToneFill: number;
  textToneLabel: string;
  textToneValue: number;
  onClose: () => void;
  onFloatingContentVisibilityChange: (contentVisibility: FloatingContentVisibility) => void;
  onFloatingTextToneChange: (textTone: number) => void;
}) {
  const [movedInfo, setMovedInfo] = useState<{ group: FloatingContentGroup; direction: "up" | "down" } | null>(null);

  function handleContentVisibilityChange(next: FloatingContentVisibility, moved?: { group: FloatingContentGroup; direction: "up" | "down" }) {
    onFloatingContentVisibilityChange(next);
    if (!moved) {
      return;
    }
    setMovedInfo(moved);
    window.setTimeout(() => {
      setMovedInfo((current) => (
        current?.group === moved.group && current.direction === moved.direction ? null : current
      ));
    }, 900);
  }

  return (
    <SettingsCalloutShell calloutRef={calloutRef} calloutStyle={calloutStyle} title="显示内容" subtitle="选择悬浮窗里显示哪些信息，并调整顺序。" onClose={onClose}>
      <label className="setting-slider settings-callout-slider">
        <span>字体颜色</span>
        <input
          max="100"
          min="-100"
          onChange={(event) => onFloatingTextToneChange(Number(event.currentTarget.value) / 100)}
          style={{ "--range-fill": `${textToneFill}%` } as CSSProperties}
          type="range"
          value={textToneValue}
        />
        <strong>{textToneLabel}</strong>
      </label>
      <div className="floating-content-settings" aria-label="悬浮窗显示内容">
        {contentVisibility.order.map((group, index) => (
          <ContentSettingRow
            group={group}
            index={index}
            key={group}
            movedInfo={movedInfo}
            visibility={contentVisibility}
            onChange={handleContentVisibilityChange}
          />
        ))}
      </div>
      <span className="settings-content-feedback" aria-live="polite">
        {movedInfo
          ? `${FLOATING_CONTENT_LABELS[movedInfo.group].title} 已${movedInfo.direction === "up" ? "上移" : "下移"} · 相邻的趣味话和速率会合并显示`
          : "相邻的趣味话和速率会合并显示"}
      </span>
    </SettingsCalloutShell>
  );
}

interface ContentSettingRowProps {
  group: FloatingContentGroup;
  index: number;
  movedInfo: { group: FloatingContentGroup; direction: "up" | "down" } | null;
  visibility: FloatingContentVisibility;
  onChange: (contentVisibility: FloatingContentVisibility, moved?: { group: FloatingContentGroup; direction: "up" | "down" }) => void;
}

function ContentSettingRow({ group, index, movedInfo, visibility, onChange }: ContentSettingRowProps) {
  const label = FLOATING_CONTENT_LABELS[group];
  const checked = isFloatingGroupVisible(visibility, group);
  const moveDirection = movedInfo?.group === group ? movedInfo.direction : undefined;

  function updateVisibility(visible: boolean) {
    onChange(sanitizeFloatingContentVisibility({
      ...visibility,
      [visibilityKey(group)]: visible,
    }));
  }

  function move(delta: number) {
    if (delta !== -1 && delta !== 1) {
      return;
    }
    onChange(sanitizeFloatingContentVisibility({
      ...visibility,
      order: moveFloatingContent(visibility.order, group, delta),
    }), { group, direction: delta === -1 ? "up" : "down" });
  }

  return (
    <div
      className={moveDirection ? "floating-content-row is-recently-moved" : "floating-content-row"}
      data-move-direction={moveDirection}
    >
      <label>
        <input
          checked={checked}
          onChange={(event) => updateVisibility(event.currentTarget.checked)}
          type="checkbox"
        />
        <span>
          <strong>{label.title}</strong>
          {label.subtitle ? <em>{label.subtitle}</em> : null}
        </span>
      </label>
      <div>
        <button
          aria-label={`向上移动${label.title}`}
          title={`向上移动 ${label.title}`}
          disabled={index === 0}
          onClick={() => move(-1)}
          type="button"
        >
          ↑
        </button>
        <button
          aria-label={`向下移动${label.title}`}
          title={`向下移动 ${label.title}`}
          disabled={index === FLOATING_CONTENT_GROUPS.length - 1}
          onClick={() => move(1)}
          type="button"
        >
          ↓
        </button>
      </div>
    </div>
  );
}

function isFloatingGroupVisible(visibility: FloatingContentVisibility, group: FloatingContentGroup): boolean {
  return Boolean(visibility[visibilityKey(group)]);
}

function visibilityKey(group: FloatingContentGroup): keyof Omit<FloatingContentVisibility, "order"> {
  switch (group) {
    case "rateAndBar":
      return "showRateAndBar";
    case "usageStatus":
      return "showUsageStatus";
    case "metrics":
      return "showMetrics";
    case "quota":
      return "showQuota";
    case "radar":
      return "showRadar";
  }
}
