import {
  useEffect,
  useRef,
  useState,
  type CSSProperties,
  type KeyboardEvent as ReactKeyboardEvent,
  type ReactNode,
} from "react";
import type { ThreadDeleteBridgeStatus } from "../../api/threadDeleteClient";
import {
  FLOATING_CONTENT_LABELS,
  moveFloatingContent,
  sanitizeFloatingContentVisibility,
} from "../../floating/floatingContent";
import type { FloatingWindowSettings } from "../../floating/floatingSettings";
import { floatingGradientBackground } from "../../floating/floatingSettings";
import { floatingTextPaletteForGroup } from "../../floating/floatingTextPalette";
import { QUOTA_REFRESH_CADENCE_OPTIONS } from "../../settings/quotaRefreshCadence";
import type {
  AutostartStatus,
  CodexHomeStatus,
  DisplaySurfaceSettings,
  FloatingContentGroup,
  FloatingContentVisibility,
  FloatingPalettePatch,
  FloatingUnreadEffect,
  PlatformCapabilities,
} from "../../types/dashboard";
import { CodexHomeEditor } from "../dashboardHeader/CodexHomeEditor";

type SettingsCategory =
  | "general"
  | "surfaces"
  | "monitoring"
  | "floating"
  | "content"
  | "alerts"
  | "data";

interface SettingsCategoryDefinition {
  id: SettingsCategory;
  label: string;
  description: string;
}

const SETTINGS_CATEGORIES: SettingsCategoryDefinition[] = [
  { id: "general", label: "常规", description: "启动与基础偏好" },
  { id: "surfaces", label: "显示面", description: "主窗口、悬浮窗与状态栏" },
  { id: "monitoring", label: "监控与额度", description: "实时速率与额度刷新" },
  { id: "floating", label: "悬浮窗", description: "尺寸、颜色与额度条" },
  { id: "content", label: "内容与排序", description: "显示项目与排列顺序" },
  { id: "alerts", label: "提醒与更新", description: "未读提示与版本更新" },
  { id: "data", label: "数据与维护", description: "目录、修复与连接状态" },
];

interface AppUpdateViewState {
  kind: "idle" | "checking" | "available" | "installing" | "error";
  message: string;
}

interface AppSettingsDialogProps {
  appUpdateState: AppUpdateViewState;
  autostartStatus: AutostartStatus;
  codexHome: CodexHomeStatus;
  displaySurfaces: DisplaySurfaceSettings;
  floatingSettings: FloatingWindowSettings;
  liveRateEnabled: boolean;
  open: boolean;
  platform: PlatformCapabilities;
  quotaRefreshIntervalMs: number;
  threadDeleteBridgeStatus: ThreadDeleteBridgeStatus;
  onCheckForUpdate: () => Promise<void>;
  onClose: () => void;
  onCodexHomeChange: (path: string) => Promise<void>;
  onCodexHomeReset: () => Promise<void>;
  onFloatingContentVisibilityChange: (contentVisibility: FloatingContentVisibility) => void;
  onFloatingGradientChange: (patch: FloatingPalettePatch) => void;
  onFloatingOpacityChange: (opacity: number) => void;
  onFloatingScaleChange: (scale: number) => void;
  onFloatingTextToneChange: (textTone: number) => void;
  onFloatingUnreadEffectChange: (effect: FloatingUnreadEffect) => void;
  onOpenProviderRepair: () => void;
  onQuotaRefreshIntervalChange: (intervalMs: number) => Promise<void>;
  onReconnectThreadDelete: () => Promise<void>;
  onTokenRateFullScaleChange: (fullScale: number) => void;
  onToggleAutostart: () => void;
  onToggleFloating: () => void;
  onToggleLiveRate: () => void;
  onToggleStatusTray: () => void;
}

export function AppSettingsDialog({
  appUpdateState,
  autostartStatus,
  codexHome,
  displaySurfaces,
  floatingSettings,
  liveRateEnabled,
  open,
  platform,
  quotaRefreshIntervalMs,
  threadDeleteBridgeStatus,
  onCheckForUpdate,
  onClose,
  onCodexHomeChange,
  onCodexHomeReset,
  onFloatingContentVisibilityChange,
  onFloatingGradientChange,
  onFloatingOpacityChange,
  onFloatingScaleChange,
  onFloatingTextToneChange,
  onFloatingUnreadEffectChange,
  onOpenProviderRepair,
  onQuotaRefreshIntervalChange,
  onReconnectThreadDelete,
  onTokenRateFullScaleChange,
  onToggleAutostart,
  onToggleFloating,
  onToggleLiveRate,
  onToggleStatusTray,
}: AppSettingsDialogProps) {
  const [selectedCategory, setSelectedCategory] = useState<SettingsCategory>("general");
  const closeButtonRef = useRef<HTMLButtonElement>(null);
  const dialogRef = useRef<HTMLElement>(null);
  const previousFocusRef = useRef<HTMLElement | null>(null);
  const selectedDefinition = SETTINGS_CATEGORIES.find((category) => category.id === selectedCategory)
    ?? SETTINGS_CATEGORIES[0];

  useEffect(() => {
    if (!open) return undefined;
    previousFocusRef.current = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    closeButtonRef.current?.focus();
    const closeForEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") onClose();
    };
    window.addEventListener("keydown", closeForEscape);
    return () => {
      window.removeEventListener("keydown", closeForEscape);
      previousFocusRef.current?.focus();
    };
  }, [onClose, open]);

  if (!open) return null;

  function handleTabKeyDown(event: ReactKeyboardEvent<HTMLButtonElement>, index: number) {
    let nextIndex: number | null = null;
    if (event.key === "ArrowDown" || event.key === "ArrowRight") {
      nextIndex = (index + 1) % SETTINGS_CATEGORIES.length;
    } else if (event.key === "ArrowUp" || event.key === "ArrowLeft") {
      nextIndex = (index - 1 + SETTINGS_CATEGORIES.length) % SETTINGS_CATEGORIES.length;
    } else if (event.key === "Home") {
      nextIndex = 0;
    } else if (event.key === "End") {
      nextIndex = SETTINGS_CATEGORIES.length - 1;
    }
    if (nextIndex === null) return;
    event.preventDefault();
    const nextCategory = SETTINGS_CATEGORIES[nextIndex];
    setSelectedCategory(nextCategory.id);
    window.requestAnimationFrame(() => {
      dialogRef.current?.querySelector<HTMLButtonElement>(`#app-settings-tab-${nextCategory.id}`)?.focus();
    });
  }

  return (
    <div
      className="app-settings-overlay"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) onClose();
      }}
    >
      <section
        aria-label="总体设置"
        aria-modal="true"
        className="app-settings-dialog"
        onKeyDown={(event) => {
          if (event.key !== "Tab") return;
          const focusable = [...(dialogRef.current?.querySelectorAll<HTMLElement>(
            "button:not(:disabled), input:not(:disabled), select:not(:disabled), [tabindex]:not([tabindex=\"-1\"])",
          ) ?? [])];
          if (focusable.length === 0) return;
          const currentIndex = focusable.indexOf(document.activeElement as HTMLElement);
          if (event.shiftKey && currentIndex <= 0) {
            event.preventDefault();
            focusable.at(-1)?.focus();
          } else if (!event.shiftKey && currentIndex === focusable.length - 1) {
            event.preventDefault();
            focusable[0]?.focus();
          }
        }}
        ref={dialogRef}
        role="dialog"
      >
        <div className="app-settings-layout">
          <aside className="app-settings-sidebar">
            <div className="app-settings-sidebar-title">
              <strong>总体设置</strong>
              <span>Codex Token Bar</span>
            </div>
            <nav aria-label="设置分类" className="app-settings-tabs" role="tablist" aria-orientation="vertical">
              {SETTINGS_CATEGORIES.map((category, index) => (
                <button
                  aria-controls={`app-settings-panel-${category.id}`}
                  aria-selected={selectedCategory === category.id}
                  className={selectedCategory === category.id ? "is-active" : ""}
                  id={`app-settings-tab-${category.id}`}
                  key={category.id}
                  onClick={() => setSelectedCategory(category.id)}
                  onKeyDown={(event) => handleTabKeyDown(event, index)}
                  role="tab"
                  tabIndex={selectedCategory === category.id ? 0 : -1}
                  type="button"
                >
                  <strong>{category.label}</strong>
                  <span>{category.description}</span>
                </button>
              ))}
            </nav>
            <p>主界面的刷新、导出和维护快捷入口会继续保留。</p>
          </aside>

          <div className="app-settings-content">
            <header className="app-settings-page-head">
              <div>
                <strong>{selectedDefinition.label}</strong>
                <span>{selectedDefinition.description}</span>
              </div>
              <button aria-label="关闭总体设置" onClick={onClose} ref={closeButtonRef} type="button">关闭</button>
            </header>
            <div
              aria-labelledby={`app-settings-tab-${selectedCategory}`}
              className="app-settings-page"
              id={`app-settings-panel-${selectedCategory}`}
              role="tabpanel"
              tabIndex={0}
            >
              {selectedCategory === "general" ? (
                <GeneralSettings
                  autostartStatus={autostartStatus}
                  onToggleAutostart={onToggleAutostart}
                />
              ) : null}
              {selectedCategory === "surfaces" ? (
                <SurfaceSettings
                  displaySurfaces={displaySurfaces}
                  onToggleFloating={onToggleFloating}
                  onToggleStatusTray={onToggleStatusTray}
                  platform={platform}
                />
              ) : null}
              {selectedCategory === "monitoring" ? (
                <MonitoringSettings
                  floatingSettings={floatingSettings}
                  liveRateEnabled={liveRateEnabled}
                  onQuotaRefreshIntervalChange={onQuotaRefreshIntervalChange}
                  onTokenRateFullScaleChange={onTokenRateFullScaleChange}
                  onToggleLiveRate={onToggleLiveRate}
                  quotaRefreshIntervalMs={quotaRefreshIntervalMs}
                />
              ) : null}
              {selectedCategory === "floating" ? (
                <FloatingAppearanceSettings
                  floatingSettings={floatingSettings}
                  onFloatingGradientChange={onFloatingGradientChange}
                  onFloatingOpacityChange={onFloatingOpacityChange}
                  onFloatingScaleChange={onFloatingScaleChange}
                  onFloatingTextToneChange={onFloatingTextToneChange}
                />
              ) : null}
              {selectedCategory === "content" ? (
                <ContentSettings
                  floatingSettings={floatingSettings}
                  onFloatingContentVisibilityChange={onFloatingContentVisibilityChange}
                />
              ) : null}
              {selectedCategory === "alerts" ? (
                <AlertAndUpdateSettings
                  appUpdateState={appUpdateState}
                  onCheckForUpdate={onCheckForUpdate}
                  onFloatingUnreadEffectChange={onFloatingUnreadEffectChange}
                  unreadEffect={floatingSettings.unreadEffect}
                />
              ) : null}
              {selectedCategory === "data" ? (
                <DataAndMaintenanceSettings
                  codexHome={codexHome}
                  onClose={onClose}
                  onCodexHomeChange={onCodexHomeChange}
                  onCodexHomeReset={onCodexHomeReset}
                  onOpenProviderRepair={onOpenProviderRepair}
                  onReconnectThreadDelete={onReconnectThreadDelete}
                  threadDeleteBridgeStatus={threadDeleteBridgeStatus}
                />
              ) : null}
            </div>
          </div>
        </div>
      </section>
    </div>
  );
}

function GeneralSettings({
  autostartStatus,
  onToggleAutostart,
}: Pick<AppSettingsDialogProps, "autostartStatus" | "onToggleAutostart">) {
  return (
    <SettingsGroup title="启动" description="控制应用随系统启动的行为。">
      <SettingRow title="开机自启" description={autostartStatus.message || "登录系统后自动打开 Token Bar。"}>
        <ToggleButton
          active={autostartStatus.enabled}
          disabled={!autostartStatus.available}
          label="开机自启"
          onClick={onToggleAutostart}
        />
      </SettingRow>
      <div className="app-settings-note">
        设置会在当前设备上即时保存；无需额外点击“应用”或“保存”。
      </div>
    </SettingsGroup>
  );
}

function SurfaceSettings({
  displaySurfaces,
  onToggleFloating,
  onToggleStatusTray,
  platform,
}: Pick<AppSettingsDialogProps, "displaySurfaces" | "onToggleFloating" | "onToggleStatusTray" | "platform">) {
  const floatingAvailable = platform.floatingWindow.available;
  const statusLiveTextAvailable = platform.statusTray.available && platform.statusTrayLiveText.available;
  return (
    <SettingsGroup title="可见位置" description="选择速率与额度信息出现在哪些显示面。">
      <SettingRow title="桌面悬浮窗" description={platform.floatingWindow.note}>
        <ToggleButton
          active={displaySurfaces.floatingWindowEnabled}
          disabled={!floatingAvailable}
          label="桌面悬浮窗"
          onClick={onToggleFloating}
        />
      </SettingRow>
      <SettingRow
        title="状态栏实时数字"
        description={statusLiveTextAvailable ? platform.statusTrayLiveText.note : platform.statusTray.note}
      >
        <ToggleButton
          active={displaySurfaces.statusTrayLiveTextEnabled}
          disabled={!statusLiveTextAvailable}
          label="状态栏实时数字"
          onClick={onToggleStatusTray}
        />
      </SettingRow>
      <div className="app-settings-note">
        跨平台版会按当前系统能力开放显示面；主窗口缩放由系统窗口尺寸自动适配。
      </div>
    </SettingsGroup>
  );
}

function MonitoringSettings({
  floatingSettings,
  liveRateEnabled,
  onQuotaRefreshIntervalChange,
  onTokenRateFullScaleChange,
  onToggleLiveRate,
  quotaRefreshIntervalMs,
}: Pick<AppSettingsDialogProps,
  | "floatingSettings"
  | "liveRateEnabled"
  | "onQuotaRefreshIntervalChange"
  | "onTokenRateFullScaleChange"
  | "onToggleLiveRate"
  | "quotaRefreshIntervalMs"
>) {
  const fullScale = Math.round(floatingSettings.tokenRateFullScale);
  return (
    <>
      <SettingsGroup title="实时速率" description="调整本地速率采样与图形标尺。">
        <SettingRow title="实时速率监控" description="读取本地会话增量，并同步到主窗口、状态栏和悬浮窗。">
          <ToggleButton active={liveRateEnabled} label="实时速率监控" onClick={onToggleLiveRate} />
        </SettingRow>
        <label className="app-setting-range">
          <span>
            <strong>速率满格</strong>
            <em>进度条达到满格时对应的 tok/s；不会改变实际统计。</em>
          </span>
          <input
            aria-label="速率条满量程"
            max="400"
            min="50"
            onChange={(event) => onTokenRateFullScaleChange(Number(event.currentTarget.value))}
            style={{ "--range-fill": `${((fullScale - 50) / 350) * 100}%` } as CSSProperties}
            type="range"
            value={fullScale}
          />
          <output>{fullScale} tok/s</output>
        </label>
      </SettingsGroup>
      <SettingsGroup title="额度刷新" description="控制当前可用额度窗口自动重读的频率。">
        <SettingRow title="自动刷新频率" description="额度仍可在主界面随时手动刷新。">
          <select
            aria-label="额度刷新频率"
            className="app-settings-select"
            onChange={(event) => void onQuotaRefreshIntervalChange(Number(event.currentTarget.value))}
            value={quotaRefreshIntervalMs}
          >
            {QUOTA_REFRESH_CADENCE_OPTIONS.map((option) => (
              <option key={option.valueMs} value={option.valueMs}>{option.label}</option>
            ))}
          </select>
        </SettingRow>
        <div className="app-settings-note">跨平台版会自动使用精确的本地会话统计，无需单独开启。</div>
      </SettingsGroup>
    </>
  );
}

function FloatingAppearanceSettings({
  floatingSettings,
  onFloatingGradientChange,
  onFloatingOpacityChange,
  onFloatingScaleChange,
  onFloatingTextToneChange,
}: Pick<AppSettingsDialogProps,
  | "floatingSettings"
  | "onFloatingGradientChange"
  | "onFloatingOpacityChange"
  | "onFloatingScaleChange"
  | "onFloatingTextToneChange"
>) {
  const opacityPercent = Math.round(floatingSettings.opacity * 100);
  const scalePercent = Math.round(floatingSettings.scale * 100);
  const textToneValue = Math.round(floatingSettings.textTone * 100);
  const textToneLabel = textToneValue < 0 ? `自动 ${Math.abs(textToneValue)}%` : `手动 ${textToneValue}%`;
  const previewPalette = floatingTextPaletteForGroup(floatingSettings, "rateAndBar", 0, 1);
  const previewStyle = {
    background: floatingGradientBackground(floatingSettings),
    color: previewPalette.primary,
    opacity: floatingSettings.opacity,
    transform: `scale(${Math.min(1.08, Math.max(0.92, floatingSettings.scale))})`,
    "--preview-secondary": previewPalette.secondary,
    "--preview-muted": previewPalette.muted,
  } as CSSProperties;

  return (
    <>
      <SettingsGroup title="尺寸与文字" description="调整悬浮窗的密度与文字对比度。">
        <label className="app-setting-range">
          <span><strong>透明度</strong><em>降低后可以减少对桌面内容的遮挡。</em></span>
          <input
            aria-label="悬浮窗透明度"
            max="100"
            min="40"
            onChange={(event) => onFloatingOpacityChange(Number(event.currentTarget.value) / 100)}
            style={{ "--range-fill": `${((opacityPercent - 40) / 60) * 100}%` } as CSSProperties}
            type="range"
            value={opacityPercent}
          />
          <output>{opacityPercent}%</output>
        </label>
        <label className="app-setting-range">
          <span><strong>大小</strong><em>同步改变悬浮窗尺寸和内部内容密度。</em></span>
          <input
            aria-label="悬浮窗大小"
            max="138"
            min="90"
            onChange={(event) => onFloatingScaleChange(Number(event.currentTarget.value) / 100)}
            style={{ "--range-fill": `${((scalePercent - 90) / 48) * 100}%` } as CSSProperties}
            type="range"
            value={scalePercent}
          />
          <output>{scalePercent}%</output>
        </label>
        <label className="app-setting-range">
          <span><strong>字体颜色</strong><em>自动会根据背景明暗选择清晰文字。</em></span>
          <input
            aria-label="悬浮窗字体颜色"
            max="100"
            min="-100"
            onChange={(event) => onFloatingTextToneChange(Number(event.currentTarget.value) / 100)}
            style={{ "--range-fill": `${(textToneValue + 100) / 2}%` } as CSSProperties}
            type="range"
            value={textToneValue}
          />
          <output>{textToneLabel}</output>
        </label>
      </SettingsGroup>

      <SettingsGroup title="颜色与额度条" description="统一设置面板渐变和额度条配色。">
        <div className="app-settings-color-grid">
          <label><span>起始色</span><input aria-label="渐变起始颜色" onChange={(event) => onFloatingGradientChange({ gradientStart: event.currentTarget.value })} type="color" value={floatingSettings.gradientStart} /></label>
          <label><span>结束色</span><input aria-label="渐变结束颜色" onChange={(event) => onFloatingGradientChange({ gradientEnd: event.currentTarget.value })} type="color" value={floatingSettings.gradientEnd} /></label>
          <label>
            <span>渐变方向</span>
            <select aria-label="渐变方向" onChange={(event) => onFloatingGradientChange({ gradientDirection: event.currentTarget.value as FloatingWindowSettings["gradientDirection"] })} value={floatingSettings.gradientDirection}>
              <option value="135deg">斜向</option><option value="90deg">横向</option><option value="180deg">纵向</option><option value="45deg">反斜</option>
            </select>
          </label>
          <label>
            <span>渐变类型</span>
            <select aria-label="渐变类型" onChange={(event) => onFloatingGradientChange({ gradientType: event.currentTarget.value as FloatingWindowSettings["gradientType"] })} value={floatingSettings.gradientType}>
              <option value="linear">线性</option><option value="radial">柔光</option><option value="conic">环向</option>
            </select>
          </label>
        </div>
        <div className="app-setting-choice" role="group" aria-label="额度条配色">
          {([
            ["adaptive", "随均速"],
            ["fixed", "固定色"],
            ["panelGradient", "面板渐变"],
          ] as const).map(([mode, label]) => (
            <button
              aria-pressed={floatingSettings.quotaColorMode === mode}
              className={floatingSettings.quotaColorMode === mode ? "is-active" : ""}
              key={mode}
              onClick={() => onFloatingGradientChange({ quotaColorMode: mode })}
              type="button"
            >
              {label}
            </button>
          ))}
        </div>
        {floatingSettings.quotaColorMode === "fixed" ? (
          <label className="app-setting-inline-color">
            <span>额度条固定颜色</span>
            <input aria-label="额度条固定颜色" onChange={(event) => onFloatingGradientChange({ quotaFixedColor: event.currentTarget.value })} type="color" value={floatingSettings.quotaFixedColor} />
          </label>
        ) : null}
        <div className="app-settings-group-footer">
          <button
            className="app-settings-action"
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
            恢复默认配色
          </button>
        </div>
      </SettingsGroup>

      <div className="app-settings-preview-wrap" aria-label="悬浮窗外观预览">
        <span>实时预览</span>
        <div className="app-settings-preview" style={previewStyle}>
          <strong>Codex Token Bar</strong>
          <span>128 tok/s</span>
          <i><b /></i>
          <small>7d 61% · 均速正常</small>
        </div>
      </div>
    </>
  );
}

function ContentSettings({
  floatingSettings,
  onFloatingContentVisibilityChange,
}: Pick<AppSettingsDialogProps, "floatingSettings" | "onFloatingContentVisibilityChange">) {
  const visibility = sanitizeFloatingContentVisibility(floatingSettings.contentVisibility);
  return (
    <SettingsGroup title="悬浮窗显示内容" description="打开需要的信息，并用箭头调整从上到下的顺序。">
      <div className="app-settings-content-list">
        {visibility.order.map((group, index) => {
          const label = FLOATING_CONTENT_LABELS[group];
          const visible = isFloatingGroupVisible(visibility, group);
          const updateVisibility = (checked: boolean) => {
            onFloatingContentVisibilityChange(sanitizeFloatingContentVisibility({
              ...visibility,
              [visibilityKey(group)]: checked,
            }));
          };
          const move = (delta: -1 | 1) => {
            onFloatingContentVisibilityChange(sanitizeFloatingContentVisibility({
              ...visibility,
              order: moveFloatingContent(visibility.order, group, delta),
            }));
          };
          return (
            <div className="app-settings-content-row" key={group}>
              <label>
                <input checked={visible} onChange={(event) => updateVisibility(event.currentTarget.checked)} type="checkbox" />
                <span><strong>{label.title}</strong>{label.subtitle ? <em>{label.subtitle}</em> : null}</span>
              </label>
              <div>
                <button aria-label={`向上移动${label.title}`} disabled={index === 0} onClick={() => move(-1)} type="button">上移</button>
                <button aria-label={`向下移动${label.title}`} disabled={index === visibility.order.length - 1} onClick={() => move(1)} type="button">下移</button>
              </div>
            </div>
          );
        })}
      </div>
      <div className="app-settings-note">趣味话与速率相邻时会自动合并成一行，减少悬浮窗高度。</div>
    </SettingsGroup>
  );
}

function AlertAndUpdateSettings({
  appUpdateState,
  onCheckForUpdate,
  onFloatingUnreadEffectChange,
  unreadEffect,
}: Pick<AppSettingsDialogProps, "appUpdateState" | "onCheckForUpdate" | "onFloatingUnreadEffectChange"> & {
  unreadEffect: FloatingUnreadEffect;
}) {
  const updateBusy = appUpdateState.kind === "checking" || appUpdateState.kind === "installing";
  const updateButtonLabel = appUpdateState.kind === "checking"
    ? "检查中…"
    : appUpdateState.kind === "installing"
      ? "安装中…"
      : appUpdateState.kind === "available"
        ? "安装更新"
        : appUpdateState.kind === "error"
          ? "重试检查"
          : "检查更新";
  return (
    <>
      <SettingsGroup title="未读提醒" description="有完成的会话还没点开时，在悬浮窗显示提示。">
        <div className="app-settings-option-grid" role="radiogroup" aria-label="未读提醒样式">
          {([
            ["off", "关", "不显示动效"],
            ["ripple", "涟漪", "显示柔和水波"],
            ["shimmer", "扫光", "显示横向光带"],
          ] as const).map(([effect, label, description]) => (
            <button
              aria-checked={unreadEffect === effect}
              className={unreadEffect === effect ? "is-active" : ""}
              key={effect}
              onClick={() => onFloatingUnreadEffectChange(effect)}
              role="radio"
              type="button"
            >
              <strong>{label}</strong><span>{description}</span>
            </button>
          ))}
        </div>
      </SettingsGroup>
      <SettingsGroup title="应用更新" description="手动检查当前平台可用的新版本。">
        <SettingRow title="版本更新" description={appUpdateState.message || "保持应用与兼容修复处于最新状态。"}>
          <button className="app-settings-action" disabled={updateBusy} onClick={() => void onCheckForUpdate()} type="button">
            {updateButtonLabel}
          </button>
        </SettingRow>
      </SettingsGroup>
    </>
  );
}

function DataAndMaintenanceSettings({
  codexHome,
  onClose,
  onCodexHomeChange,
  onCodexHomeReset,
  onOpenProviderRepair,
  onReconnectThreadDelete,
  threadDeleteBridgeStatus,
}: Pick<AppSettingsDialogProps,
  | "codexHome"
  | "onClose"
  | "onCodexHomeChange"
  | "onCodexHomeReset"
  | "onOpenProviderRepair"
  | "onReconnectThreadDelete"
  | "threadDeleteBridgeStatus"
>) {
  const sourceLabel = codexHome.source === "manual" ? "手动目录" : codexHome.exists ? "自动发现" : "等待选择";
  const canReconnectThreadDelete = threadDeleteBridgeStatus.debugPort !== null;
  const threadDeleteTitle = threadDeleteBridgeStatus.connected ? "侧栏删除已连接" : "侧栏删除未连接";
  const threadDeleteDescription = canReconnectThreadDelete
    ? threadDeleteBridgeStatus.message
    : `${threadDeleteBridgeStatus.message}。如需启用，请回到主界面顶部使用“启用侧栏删除”，那里会先说明重启影响。`;
  return (
    <>
      <SettingsGroup title="Codex 数据目录" description={`${sourceLabel} · ${codexHome.exists ? "目录可用" : "目录待读取"}`}>
        <CodexHomeEditor
          codexHome={codexHome}
          onCodexHomeChange={onCodexHomeChange}
          onCodexHomeReset={onCodexHomeReset}
          onDone={() => undefined}
        />
      </SettingsGroup>
      <SettingsGroup title="维护工具" description="用于修复本地会话显示与侧栏连接。">
        <SettingRow title="会话消失修复" description="扫描 Provider 数据，找回历史列表里消失的会话。">
          <button
            className="app-settings-action"
            onClick={() => {
              onClose();
              window.requestAnimationFrame(onOpenProviderRepair);
            }}
            type="button"
          >
            打开修复工具
          </button>
        </SettingRow>
        <SettingRow title={threadDeleteTitle} description={threadDeleteDescription}>
          {canReconnectThreadDelete ? (
            <button className="app-settings-action" onClick={() => void onReconnectThreadDelete()} type="button">
              重新连接
            </button>
          ) : (
            <span className="app-settings-status">请回主界面启用</span>
          )}
        </SettingRow>
      </SettingsGroup>
    </>
  );
}

function SettingsGroup({
  children,
  description,
  title,
}: {
  children: ReactNode;
  description: string;
  title: string;
}) {
  return (
    <section className="app-settings-group">
      <header><strong>{title}</strong><span>{description}</span></header>
      <div>{children}</div>
    </section>
  );
}

function SettingRow({
  children,
  description,
  title,
}: {
  children: ReactNode;
  description: string;
  title: string;
}) {
  return (
    <div className="app-setting-row">
      <span><strong>{title}</strong><em>{description}</em></span>
      <div>{children}</div>
    </div>
  );
}

function ToggleButton({
  active,
  disabled = false,
  label,
  onClick,
}: {
  active: boolean;
  disabled?: boolean;
  label: string;
  onClick: () => void;
}) {
  return (
    <button
      aria-label={`${label}：${active ? "开" : "关"}`}
      aria-pressed={active}
      className={active ? "app-settings-toggle is-active" : "app-settings-toggle"}
      disabled={disabled}
      onClick={onClick}
      type="button"
    >
      <span aria-hidden="true"><i /></span>
      <strong>{active ? "开" : "关"}</strong>
    </button>
  );
}

function isFloatingGroupVisible(visibility: FloatingContentVisibility, group: FloatingContentGroup): boolean {
  switch (group) {
    case "rateAndBar": return visibility.showRateAndBar;
    case "usageStatus": return visibility.showUsageStatus;
    case "metrics": return visibility.showMetrics;
    case "quota": return visibility.showQuota;
    case "radar": return visibility.showRadar;
  }
}

function visibilityKey(group: FloatingContentGroup): keyof FloatingContentVisibility {
  switch (group) {
    case "rateAndBar": return "showRateAndBar";
    case "usageStatus": return "showUsageStatus";
    case "metrics": return "showMetrics";
    case "quota": return "showQuota";
    case "radar": return "showRadar";
  }
}
