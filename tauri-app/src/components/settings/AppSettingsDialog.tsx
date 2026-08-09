import {
  useEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type KeyboardEvent as ReactKeyboardEvent,
  type RefObject,
  type ReactNode,
} from "react";
import type { ThreadDeleteBridgeStatus } from "../../api/threadDeleteClient";
import { sanitizeFloatingContentVisibility } from "../../floating/floatingContent";
import type { FloatingWindowSettings } from "../../floating/floatingSettings";
import { floatingGradientBackground } from "../../floating/floatingSettings";
import { floatingTextPaletteForGroup } from "../../floating/floatingTextPalette";
import {
  DEFAULT_STATUS_METRIC_ORDER,
  DEFAULT_STATUS_SUMMARY_ORDER,
} from "../../settings/displaySettings";
import { QUOTA_REFRESH_CADENCE_OPTIONS } from "../../settings/quotaRefreshCadence";
import { QUOTA_PRICE_MODEL_OPTIONS, type OfficialAPIPriceModel } from "../../settings/quotaPriceModel";
import {
  SHARED_ACCOUNT_RADAR_TIER_OPTIONS,
  type SharedAccountRadarTier,
} from "../../settings/sharedAccountAttribution";
import { useSharedAccountAttributionSettings } from "../../settings/useSharedAccountAttributionSettings";
import { buildStatusIndicatorPreview } from "../../status/statusIndicatorPresentation";
import { StatusPanelCompactItems } from "../../status/StatusPanelCompactIndicator";
import {
  AUTO_RESUME_FAILURE_REASONS,
  AUTO_RESUME_INTERVAL_OPTIONS,
  createAutoResumeTask,
  formatAutoResumeTimestamp,
  sanitizeAutoResumeSettings,
} from "../../settings/autoResume";
import {
  AUTO_RESUME_THREAD_PAGE_SIZE,
  autoResumeProjectKey,
  autoResumeThreadsInProject,
  buildAutoResumeProjects,
  matchingAutoResumeThreads,
  resolveAutoResumeProjectKey,
  visibleAutoResumeThreads,
} from "../../settings/autoResumeThreadPicker";
import type {
  AutostartStatus,
  AutoResumeRuntimeStatus,
  AutoResumeSettings,
  AutoResumeTaskRuntimeStatus,
  AutoResumeTaskSettings,
  AutoResumeThreadOption,
  CodexHomeStatus,
  DisplaySurfaceSettings,
  FloatingContentVisibility,
  FloatingPanelSnapshot,
  FloatingPalettePatch,
  FloatingUnreadEffect,
  PlatformCapabilities,
  RunningThreadSummary,
  SessionEnhancementSettings,
  StatusMetricId,
  StatusMetricLabelStyle,
  StatusSummarySectionId,
} from "../../types/dashboard";
import { sanitizeSessionEnhancements } from "../../settings/sessionEnhancements";
import { CodexHomeEditor } from "../dashboardHeader/CodexHomeEditor";
import { CodexInstancesSettings } from "./CodexInstancesSettings";
import { FloatingStructureEditor } from "./FloatingStructureEditor";

export type AppSettingsCategory =
  | "general"
  | "session"
  | "instances"
  | "surfaces"
  | "status"
  | "monitoring"
  | "automation"
  | "floating"
  | "content"
  | "alerts"
  | "data";

type VisibleAppSettingsCategory = Exclude<AppSettingsCategory, "content">;

interface SettingsCategoryDefinition {
  id: VisibleAppSettingsCategory;
  label: string;
  description: string;
}

const SETTINGS_CATEGORIES: SettingsCategoryDefinition[] = [
  { id: "general", label: "常规", description: "启动与基础偏好" },
  { id: "session", label: "会话增强", description: "会话管理、导出、移动、输入与阅读体验" },
  { id: "instances", label: "Codex 实例", description: "多开、隔离、同步与回滚" },
  { id: "automation", label: "自动续跑", description: "按所选中断原因、定时或额度恢复继续" },
  { id: "surfaces", label: "显示面", description: "主窗口、悬浮窗与状态栏" },
  { id: "status", label: "状态栏与托盘", description: "指标、顺序与紧缩预览" },
  { id: "monitoring", label: "监控与额度", description: "实时速率与额度刷新" },
  { id: "floating", label: "悬浮窗", description: "尺寸、外观、内容与翻页" },
  { id: "alerts", label: "提醒与更新", description: "未读提示与版本更新" },
  { id: "data", label: "数据与维护", description: "目录、修复与连接状态" },
];

function normalizeSettingsCategory(category: AppSettingsCategory): VisibleAppSettingsCategory {
  return category === "content" ? "floating" : category;
}

interface AppUpdateViewState {
  kind: "idle" | "checking" | "available" | "installing" | "error";
  message: string;
}

interface AppSettingsDialogProps {
  appUpdateState: AppUpdateViewState;
  autostartStatus: AutostartStatus;
  autoResumeCancelling: boolean;
  autoResumeError: string | null;
  autoResumeLoading: boolean;
  autoResumeRunning: boolean;
  autoResumeSaving: boolean;
  autoResumeSettings: AutoResumeSettings;
  autoResumeStatus: AutoResumeRuntimeStatus;
  autoResumeThreads: AutoResumeThreadOption[];
  codexHome: CodexHomeStatus;
  displaySurfaces: DisplaySurfaceSettings;
  floatingSettings: FloatingWindowSettings;
  floatingPreviewSnapshot: FloatingPanelSnapshot;
  floatingPreviewRunningThreads: RunningThreadSummary;
  initialCategory?: AppSettingsCategory;
  liveRateEnabled: boolean;
  open: boolean;
  platform: PlatformCapabilities;
  quotaRefreshIntervalMs: number;
  sessionEnhancements: SessionEnhancementSettings;
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
  onOpenSessionManagement: () => void;
  onQuotaRefreshIntervalChange: (intervalMs: number) => Promise<void>;
  onCancelAutoResume: () => Promise<void>;
  onRefreshAutoResume: () => Promise<void>;
  onReconnectThreadDelete: () => Promise<void>;
  onRunAutoResume: (taskId: string) => Promise<void>;
  onSaveAutoResume: (settings: AutoResumeSettings) => Promise<void>;
  onSaveSessionEnhancements: (settings: SessionEnhancementSettings) => Promise<void>;
  onTokenRateFullScaleChange: (fullScale: number) => void;
  onToggleAutostart: () => void;
  onToggleFloating: () => void;
  onToggleLiveRate: () => void;
  onToggleStatusTray: () => void;
  onStatusMetricOrderChange: (order: StatusMetricId[]) => void;
  onStatusMetricLabelStyleChange: (style: StatusMetricLabelStyle) => void;
  onStatusSummaryOrderChange: (order: StatusSummarySectionId[]) => void;
}

export function AppSettingsDialog({
  appUpdateState,
  autostartStatus,
  autoResumeCancelling,
  autoResumeError,
  autoResumeLoading,
  autoResumeRunning,
  autoResumeSaving,
  autoResumeSettings,
  autoResumeStatus,
  autoResumeThreads,
  codexHome,
  displaySurfaces,
  floatingSettings,
  floatingPreviewSnapshot,
  floatingPreviewRunningThreads,
  initialCategory = "general",
  liveRateEnabled,
  open,
  platform,
  quotaRefreshIntervalMs,
  sessionEnhancements,
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
  onOpenSessionManagement,
  onQuotaRefreshIntervalChange,
  onCancelAutoResume,
  onRefreshAutoResume,
  onReconnectThreadDelete,
  onRunAutoResume,
  onSaveAutoResume,
  onSaveSessionEnhancements,
  onTokenRateFullScaleChange,
  onToggleAutostart,
  onToggleFloating,
  onToggleLiveRate,
  onToggleStatusTray,
  onStatusMetricOrderChange,
  onStatusMetricLabelStyleChange,
  onStatusSummaryOrderChange,
}: AppSettingsDialogProps) {
  const [selectedCategory, setSelectedCategory] = useState<VisibleAppSettingsCategory>(
    normalizeSettingsCategory(initialCategory),
  );
  const [sessionEnableConfirmationOpen, setSessionEnableConfirmationOpen] = useState(false);
  const sessionEnableConfirmationOpenRef = useRef(false);
  const closeButtonRef = useRef<HTMLButtonElement>(null);
  const dialogRef = useRef<HTMLElement>(null);
  const previousFocusRef = useRef<HTMLElement | null>(null);
  const sessionConnectionTriggerRef = useRef<HTMLButtonElement>(null);
  const sessionConfirmationCancelRef = useRef<HTMLButtonElement>(null);
  const sessionConfirmationDialogRef = useRef<HTMLDivElement>(null);
  const selectedDefinition = SETTINGS_CATEGORIES.find((category) => category.id === selectedCategory)
    ?? SETTINGS_CATEGORIES[0];

  useEffect(() => {
    if (!open) return undefined;
    previousFocusRef.current = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    closeButtonRef.current?.focus();
    const closeForEscape = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      if (sessionEnableConfirmationOpenRef.current) {
        setSessionEnableConfirmationOpen(false);
        window.requestAnimationFrame(() => sessionConnectionTriggerRef.current?.focus());
      } else {
        onClose();
      }
    };
    window.addEventListener("keydown", closeForEscape);
    return () => {
      window.removeEventListener("keydown", closeForEscape);
      previousFocusRef.current?.focus();
    };
  }, [onClose, open]);

  useEffect(() => {
    if (!open) {
      setSessionEnableConfirmationOpen(false);
      return;
    }
    setSelectedCategory(normalizeSettingsCategory(initialCategory));
  }, [initialCategory, open]);

  useEffect(() => {
    sessionEnableConfirmationOpenRef.current = sessionEnableConfirmationOpen;
    if (sessionEnableConfirmationOpen) sessionConfirmationCancelRef.current?.focus();
  }, [sessionEnableConfirmationOpen]);

  useEffect(() => {
    if (open && selectedCategory === "automation") {
      void onRefreshAutoResume();
    }
  }, [onRefreshAutoResume, open, selectedCategory]);

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

  function handleSessionConfirmationKeyDown(event: ReactKeyboardEvent<HTMLDivElement>) {
    if (event.key !== "Tab") return;
    const buttons = [...(sessionConfirmationDialogRef.current?.querySelectorAll<HTMLButtonElement>(
      "button:not(:disabled)",
    ) ?? [])];
    if (buttons.length === 0) return;
    const currentIndex = buttons.indexOf(document.activeElement as HTMLButtonElement);
    if (event.shiftKey && currentIndex <= 0) {
      event.preventDefault();
      buttons.at(-1)?.focus();
    } else if (!event.shiftKey && currentIndex === buttons.length - 1) {
      event.preventDefault();
      buttons[0]?.focus();
    }
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
            "a[href], button:not(:disabled), input:not(:disabled), select:not(:disabled), textarea:not(:disabled), [tabindex]:not([tabindex=\"-1\"])",
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
              {selectedCategory === "session" ? (
                <SessionEnhancementSettingsPanel
                  onConnectionAction={() => {
                    if (threadDeleteBridgeStatus.debugPort === null) {
                      setSessionEnableConfirmationOpen(true);
                    } else {
                      void onReconnectThreadDelete();
                    }
                  }}
                  onOpenSessionManagement={onOpenSessionManagement}
                  onSaveSessionEnhancements={onSaveSessionEnhancements}
                  sessionConnectionTriggerRef={sessionConnectionTriggerRef}
                  sessionEnhancements={sessionEnhancements}
                  threadDeleteBridgeStatus={threadDeleteBridgeStatus}
                />
              ) : null}
              {selectedCategory === "instances" ? <CodexInstancesSettings /> : null}
              {selectedCategory === "surfaces" ? (
                <SurfaceSettings
                  displaySurfaces={displaySurfaces}
                  onOpenStatusSettings={() => setSelectedCategory("status")}
                  onToggleFloating={onToggleFloating}
                  platform={platform}
                />
              ) : null}
              {selectedCategory === "status" ? (
                <StatusIndicatorSettings
                  displaySurfaces={displaySurfaces}
                  onStatusMetricLabelStyleChange={onStatusMetricLabelStyleChange}
                  onStatusMetricOrderChange={onStatusMetricOrderChange}
                  onStatusSummaryOrderChange={onStatusSummaryOrderChange}
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
              {selectedCategory === "automation" ? (
                <AutomationSettings
                  autoResumeCancelling={autoResumeCancelling}
                  autoResumeError={autoResumeError}
                  autoResumeLoading={autoResumeLoading}
                  autoResumeRunning={autoResumeRunning}
                  autoResumeSaving={autoResumeSaving}
                  autoResumeSettings={autoResumeSettings}
                  autoResumeStatus={autoResumeStatus}
                  autoResumeThreads={autoResumeThreads}
                  onCancelAutoResume={onCancelAutoResume}
                  onRefreshAutoResume={onRefreshAutoResume}
                  onRunAutoResume={onRunAutoResume}
                  onSaveAutoResume={onSaveAutoResume}
                />
              ) : null}
              {selectedCategory === "floating" ? (
                <>
                  <FloatingAppearanceSettings
                    floatingSettings={floatingSettings}
                    onFloatingGradientChange={onFloatingGradientChange}
                    onFloatingOpacityChange={onFloatingOpacityChange}
                    onFloatingScaleChange={onFloatingScaleChange}
                    onFloatingTextToneChange={onFloatingTextToneChange}
                  />
                  <ContentSettings
                    floatingSettings={floatingSettings}
                    floatingPreviewSnapshot={floatingPreviewSnapshot}
                    floatingPreviewRunningThreads={floatingPreviewRunningThreads}
                    onFloatingContentVisibilityChange={onFloatingContentVisibilityChange}
                  />
                </>
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
                />
              ) : null}
            </div>
          </div>
        </div>
      </section>
      {sessionEnableConfirmationOpen ? (
        <div
          className="thread-delete-confirmation-overlay"
          onMouseDown={(event) => {
            if (event.target === event.currentTarget) {
              setSessionEnableConfirmationOpen(false);
              window.requestAnimationFrame(() => sessionConnectionTriggerRef.current?.focus());
            }
          }}
        >
          <div
            aria-describedby="session-enhancement-confirmation-description"
            aria-labelledby="session-enhancement-confirmation-title"
            aria-modal="true"
            className="thread-delete-confirmation-dialog"
            onKeyDown={handleSessionConfirmationKeyDown}
            ref={sessionConfirmationDialogRef}
            role="alertdialog"
          >
            <h2 id="session-enhancement-confirmation-title">重启 Codex 并启用会话增强？</h2>
            <p id="session-enhancement-confirmation-description">Codex 会关闭后立即以仅限本机的调试端口重新打开。当前任务不会被删除，但界面会短暂中断。</p>
            <div className="thread-delete-confirmation-actions">
              <button
                onClick={() => {
                  setSessionEnableConfirmationOpen(false);
                  window.requestAnimationFrame(() => sessionConnectionTriggerRef.current?.focus());
                }}
                ref={sessionConfirmationCancelRef}
                type="button"
              >
                取消
              </button>
              <button
                className="thread-delete-confirmation-primary"
                onClick={() => {
                  setSessionEnableConfirmationOpen(false);
                  window.requestAnimationFrame(() => sessionConnectionTriggerRef.current?.focus());
                  void onReconnectThreadDelete();
                }}
                type="button"
              >
                重启并启用
              </button>
            </div>
          </div>
        </div>
      ) : null}
    </div>
  );
}

function SessionEnhancementSettingsPanel({
  onConnectionAction,
  onOpenSessionManagement,
  onSaveSessionEnhancements,
  sessionConnectionTriggerRef,
  sessionEnhancements,
  threadDeleteBridgeStatus,
}: Pick<AppSettingsDialogProps,
  | "onOpenSessionManagement"
  | "onSaveSessionEnhancements"
  | "sessionEnhancements"
  | "threadDeleteBridgeStatus"
> & {
  onConnectionAction: () => void;
  sessionConnectionTriggerRef: RefObject<HTMLButtonElement | null>;
}) {
  const settings = sanitizeSessionEnhancements(sessionEnhancements);
  const [widthDraft, setWidthDraft] = useState(settings.conversationViewMaxWidth);
  const [saveError, setSaveError] = useState<string | null>(null);

  useEffect(() => setWidthDraft(settings.conversationViewMaxWidth), [settings.conversationViewMaxWidth]);

  async function save(patch: Partial<SessionEnhancementSettings>) {
    setSaveError(null);
    try {
      await onSaveSessionEnhancements(sanitizeSessionEnhancements({ ...settings, ...patch }));
    } catch (error) {
      setSaveError(`保存会话增强失败：${error instanceof Error ? error.message : String(error)}`);
    }
  }

  function toggle(key: "markdownExport" | "pasteFix" | "projectMove" | "threadIDBadge" | "conversationView" | "threadScrollRestore") {
    void save({ [key]: !settings[key] });
  }

  const connectionTitle = threadDeleteBridgeStatus.connected ? "会话增强已连接" : "会话增强未连接";
  const connectionAction = threadDeleteBridgeStatus.debugPort === null ? "重启 Codex 并启用" : "重新连接";
  return (
    <>
      <SettingsGroup title="Codex 页面连接" description="通过仅限本机的调试端口加载增强；功能开关变化后自动重连，无需重启 Codex。">
        <SettingRow title={connectionTitle} description={threadDeleteBridgeStatus.message}>
          <button
            className="app-settings-action"
            onClick={onConnectionAction}
            ref={sessionConnectionTriggerRef}
            type="button"
          >
            {connectionAction}
          </button>
        </SettingRow>
      </SettingsGroup>
      <SettingsGroup title="会话管理" description="在 Codex 侧栏为每个任务增加可靠的管理操作。">
        <SettingRow
          title="Token Bar 会话管理"
          description="独立工作面：按项目查看上下文，分开管理官方归档、深度压缩恢复包和安全删除。"
        >
          <button
            className="app-settings-action is-primary"
            onClick={onOpenSessionManagement}
            type="button"
          >
            打开会话管理
          </button>
        </SettingRow>
        <SettingRow
          title="永久删除"
          description="旧侧栏直接删除已停用。请从会话管理进入；删除前会强制创建并校验完整影响闭包的恢复包。"
        >
          <span className="app-settings-status">仅在会话管理中</span>
        </SettingRow>
        <SettingRow title="Markdown 导出" description="从真实 rollout 生成可保存的 Markdown。">
          <ToggleButton active={settings.markdownExport} label="Markdown 导出" onClick={() => toggle("markdownExport")} />
        </SettingRow>
        <SettingRow title="会话项目移动" description="同步更新本地会话数据库与 rollout 项目目录。">
          <ToggleButton active={settings.projectMove} label="会话项目移动" onClick={() => toggle("projectMove")} />
        </SettingRow>
        <SettingRow title="会话 ID 标识" description="在侧栏显示每个会话 ID 的短标识。">
          <ToggleButton active={settings.threadIDBadge} label="会话 ID 标识" onClick={() => toggle("threadIDBadge")} />
        </SettingRow>
      </SettingsGroup>
      <SettingsGroup title="输入与阅读" description="改善富文本粘贴、大屏阅读和多任务切换体验。">
        <SettingRow title="粘贴修复" description="把富文本粘贴规范化为纯文本输入。">
          <ToggleButton active={settings.pasteFix} label="粘贴修复" onClick={() => toggle("pasteFix")} />
        </SettingRow>
        <SettingRow title="对话居中宽度" description="限制正文和输入框最大宽度，提升大屏阅读体验。">
          <ToggleButton active={settings.conversationView} label="对话居中宽度" onClick={() => toggle("conversationView")} />
        </SettingRow>
        {settings.conversationView ? (
          <label className="app-setting-range">
            <span><strong>最大宽度</strong><em>正文与输入框的最大显示宽度。</em></span>
            <input
              aria-label="对话居中最大宽度"
              max="4000"
              min="320"
              onChange={(event) => setWidthDraft(Number(event.currentTarget.value))}
              onKeyUp={(event) => void save({ conversationViewMaxWidth: Number(event.currentTarget.value) })}
              onPointerUp={(event) => void save({ conversationViewMaxWidth: Number(event.currentTarget.value) })}
              step="10"
              type="range"
              value={widthDraft}
            />
            <output>{widthDraft} px</output>
          </label>
        ) : null}
        <SettingRow title="切换对话保留位置" description="回到会话时恢复上次滚动位置。">
          <ToggleButton active={settings.threadScrollRestore} label="切换对话保留位置" onClick={() => toggle("threadScrollRestore")} />
        </SettingRow>
      </SettingsGroup>
      <SettingsGroup title="开源归属" description="本页能力基于 Codex++ v1.2.41 的对话与输入实现迁入。">
        <SettingRow title="Codex++ · AGPL-3.0" description="保留 BigPizzaV3/CodexPlusPlus 的版权、来源和 GNU AGPL v3 许可。">
          <a className="app-settings-action" href="https://github.com/BigPizzaV3/CodexPlusPlus" rel="noreferrer" target="_blank">查看上游源码</a>
        </SettingRow>
      </SettingsGroup>
      {saveError ? <div className="auto-resume-error" role="alert">{saveError}</div> : null}
    </>
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
  onOpenStatusSettings,
  onToggleFloating,
  platform,
}: Pick<AppSettingsDialogProps, "displaySurfaces" | "onToggleFloating" | "platform"> & {
  onOpenStatusSettings: () => void;
}) {
  const floatingAvailable = platform.floatingWindow.available;
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
        title="状态栏与系统托盘"
        description={`当前${displaySurfaces.statusTrayLiveTextEnabled ? "已开启" : "已关闭"}；指标选择和顺序集中在专属页面。`}
      >
        <button className="app-settings-secondary-button" onClick={onOpenStatusSettings} type="button">
          前往设置
        </button>
      </SettingRow>
      <div className="app-settings-note">
        跨平台版会按当前系统能力开放显示面；主窗口缩放由系统窗口尺寸自动适配。
      </div>
    </SettingsGroup>
  );
}

const STATUS_METRIC_OPTIONS: ReadonlyArray<{
  description: string;
  id: StatusMetricId;
  label: string;
}> = [
  { id: "rate", label: "实时速度", description: "当前 Token 生成速度；真实为零时仍显示。" },
  { id: "fiveHour", label: "5 小时额度", description: "官方未提供时隐藏；读取失败时保留“—”。" },
  { id: "sevenDay", label: "7 天额度", description: "读取不到时保留“—”占位。" },
  { id: "iq", label: "今日众测榜", description: "两行显示当天众测实时榜第一、第二名模型及思考强度。" },
  { id: "today", label: "今日 Token", description: "今天累计处理的 Token。" },
  { id: "total", label: "累计 Token", description: "本机历史累计 Token。" },
  { id: "requests", label: "请求次数", description: "累计请求数量。" },
  { id: "running", label: "运行任务", description: "没有运行任务时显示 0。" },
  { id: "unread", label: "未读会话", description: "没有未读时显示 0。" },
];

const STATUS_SUMMARY_OPTIONS: ReadonlyArray<{
  description: string;
  id: StatusSummarySectionId;
  label: string;
}> = [
  { id: "overview", label: "速度概览", description: "当前速度、趋势与速率条。" },
  { id: "usage", label: "用量统计", description: "今日、累计与请求次数。" },
  { id: "quota", label: "额度", description: "5 小时和 7 天额度。" },
  { id: "running", label: "运行任务", description: "主任务与子 Agent 概览。" },
  { id: "unread", label: "未读会话", description: "未读数量和标记已读入口。" },
  { id: "radar", label: "雷达", description: "官方雷达动作、概率和 IQ。" },
  { id: "crowdRadar", label: "众测雷达", description: "众测排行的紧凑摘要。" },
];

function StatusIndicatorSettings({
  displaySurfaces,
  onStatusMetricLabelStyleChange,
  onStatusMetricOrderChange,
  onStatusSummaryOrderChange,
  onToggleStatusTray,
  platform,
}: Pick<
  AppSettingsDialogProps,
  | "displaySurfaces"
  | "onStatusMetricLabelStyleChange"
  | "onStatusMetricOrderChange"
  | "onStatusSummaryOrderChange"
  | "onToggleStatusTray"
  | "platform"
>) {
  const order = displaySurfaces.statusMetricOrder;
  const summaryOrder = displaySurfaces.statusSummaryOrder;
  const preview = useMemo(
    () => buildStatusIndicatorPreview(order, displaySurfaces.statusMetricLabelStyle),
    [displaySurfaces.statusMetricLabelStyle, order],
  );
  const options = useMemo(() => {
    const configured = order
      .map((id) => STATUS_METRIC_OPTIONS.find((option) => option.id === id))
      .filter((option): option is (typeof STATUS_METRIC_OPTIONS)[number] => option !== undefined);
    const selected = new Set(order);
    return [
      ...configured,
      ...STATUS_METRIC_OPTIONS.filter((option) => !selected.has(option.id)),
    ];
  }, [order]);
  const summaryOptions = useMemo(() => {
    const configured = summaryOrder
      .map((id) => STATUS_SUMMARY_OPTIONS.find((option) => option.id === id))
      .filter((option): option is (typeof STATUS_SUMMARY_OPTIONS)[number] => option !== undefined);
    const selected = new Set(summaryOrder);
    return [
      ...configured,
      ...STATUS_SUMMARY_OPTIONS.filter((option) => !selected.has(option.id)),
    ];
  }, [summaryOrder]);
  const statusAvailable = platform.statusTray.available;
  const platformDescription = platform.platform === "windows"
    ? "Windows 系统托盘图标保留稳定入口；可选任务栏旁紧凑条按顺序显示所选指标，完整详情点开查看。"
    : "macOS 会在菜单栏按顺序显示紧缩文字，点击后仍可查看完整详情。";

  function setMetricEnabled(id: StatusMetricId, enabled: boolean) {
    if (enabled) {
      onStatusMetricOrderChange([...order, id]);
    } else {
      onStatusMetricOrderChange(order.filter((metric) => metric !== id));
    }
  }

  function moveMetric(id: StatusMetricId, offset: -1 | 1) {
    const index = order.indexOf(id);
    const destination = index + offset;
    if (index < 0 || destination < 0 || destination >= order.length) {
      return;
    }
    const next = [...order];
    [next[index], next[destination]] = [next[destination], next[index]];
    onStatusMetricOrderChange(next);
  }

  function setSummaryEnabled(id: StatusSummarySectionId, enabled: boolean) {
    if (enabled) {
      onStatusSummaryOrderChange([...summaryOrder, id]);
    } else {
      onStatusSummaryOrderChange(summaryOrder.filter((section) => section !== id));
    }
  }

  function moveSummary(id: StatusSummarySectionId, offset: -1 | 1) {
    const index = summaryOrder.indexOf(id);
    const destination = index + offset;
    if (index < 0 || destination < 0 || destination >= summaryOrder.length) {
      return;
    }
    const next = [...summaryOrder];
    [next[index], next[destination]] = [next[destination], next[index]];
    onStatusSummaryOrderChange(next);
  }

  return (
    <>
      <SettingsGroup title="显示方式" description="设置状态栏或系统托盘是否工作，并即时查看紧缩结果。">
        <SettingRow title="状态栏与托盘指标" description={platformDescription}>
          <ToggleButton
            active={displaySurfaces.statusTrayLiveTextEnabled}
            disabled={!statusAvailable}
            label="状态栏与托盘指标"
            onClick={onToggleStatusTray}
          />
        </SettingRow>
        <SettingRow title="标签样式" description="完整标签便于辨认，紧缩标签节省空间，仅数值最窄。">
          <div aria-label="状态栏标签样式" className="app-setting-choice" role="radiogroup">
            {([
              ["full", "完整"],
              ["compact", "紧缩"],
              ["hidden", "仅数值"],
            ] as const).map(([style, label]) => (
              <button
                aria-checked={displaySurfaces.statusMetricLabelStyle === style}
                className={displaySurfaces.statusMetricLabelStyle === style ? "is-active" : ""}
                key={style}
                onClick={() => onStatusMetricLabelStyleChange(style)}
                role="radio"
                type="button"
              >{label}</button>
            ))}
          </div>
        </SettingRow>
        <div className="status-indicator-preview" aria-label="状态栏指标实时示例">
          <span>{platform.platform === "windows" ? "Windows 紧凑条示例" : "macOS 菜单栏示例"}</span>
          {preview.visibleItems.length > 0 ? (
            <div aria-label={preview.title} style={{ display: "flex", justifyContent: "flex-end", overflow: "hidden" }}>
              <StatusPanelCompactItems columns={preview.columns} />
            </div>
          ) : <strong>仅显示应用图标</strong>}
          <em title={preview.tooltip}>{preview.tooltip}</em>
        </div>
        {!statusAvailable ? (
          <div className="app-settings-note">{platform.statusTray.note}</div>
        ) : null}
      </SettingsGroup>

      <SettingsGroup title="指标与顺序" description="勾选需要的指标；已选项目按这里的顺序显示。">
        <div className="status-metric-list">
          {options.map((option) => {
            const selectedIndex = order.indexOf(option.id);
            const enabled = selectedIndex >= 0;
            return (
              <div className="status-metric-row" key={option.id}>
                <label>
                  <input
                    checked={enabled}
                    onChange={(event) => setMetricEnabled(option.id, event.currentTarget.checked)}
                    type="checkbox"
                  />
                  <span><strong>{option.label}</strong><em>{option.description}</em></span>
                </label>
                <div className="status-metric-order-actions">
                  <button
                    aria-label={`${option.label}上移`}
                    disabled={!enabled || selectedIndex === 0}
                    onClick={() => moveMetric(option.id, -1)}
                    type="button"
                  >↑</button>
                  <button
                    aria-label={`${option.label}下移`}
                    disabled={!enabled || selectedIndex === order.length - 1}
                    onClick={() => moveMetric(option.id, 1)}
                    type="button"
                  >↓</button>
                </div>
              </div>
            );
          })}
        </div>
        <div className="app-settings-group-footer">
          <span>已选指标始终保留：真实零显示 0，暂未读取或不可用显示“—”。</span>
          <button
            className="app-settings-secondary-button"
            disabled={sameMetricOrder(order, DEFAULT_STATUS_METRIC_ORDER)}
            onClick={() => onStatusMetricOrderChange([...DEFAULT_STATUS_METRIC_ORDER])}
            type="button"
          >恢复默认</button>
        </div>
      </SettingsGroup>

      <SettingsGroup title="摘要内容与排序" description="自由选择点击托盘或闪电后详情面板里的内容与顺序。">
        <div className="status-metric-list status-summary-list">
          {summaryOptions.map((option) => {
            const selectedIndex = summaryOrder.indexOf(option.id);
            const enabled = selectedIndex >= 0;
            return (
              <div className="status-metric-row" key={option.id}>
                <label>
                  <input
                    checked={enabled}
                    onChange={(event) => setSummaryEnabled(option.id, event.currentTarget.checked)}
                    type="checkbox"
                  />
                  <span><strong>{option.label}</strong><em>{option.description}</em></span>
                </label>
                <div className="status-metric-order-actions">
                  <button
                    aria-label={`${option.label}上移`}
                    disabled={!enabled || selectedIndex === 0}
                    onClick={() => moveSummary(option.id, -1)}
                    type="button"
                  >↑</button>
                  <button
                    aria-label={`${option.label}下移`}
                    disabled={!enabled || selectedIndex === summaryOrder.length - 1}
                    onClick={() => moveSummary(option.id, 1)}
                    type="button"
                  >↓</button>
                </div>
              </div>
            );
          })}
        </div>
        <div className="app-settings-group-footer">
          <span>摘要使用独立顺序，不会改变悬浮窗内容。</span>
          <button
            className="app-settings-secondary-button"
            disabled={sameSummaryOrder(summaryOrder, DEFAULT_STATUS_SUMMARY_ORDER)}
            onClick={() => onStatusSummaryOrderChange([...DEFAULT_STATUS_SUMMARY_ORDER])}
            type="button"
          >恢复摘要默认</button>
        </div>
      </SettingsGroup>
    </>
  );
}

function sameMetricOrder(left: readonly StatusMetricId[], right: readonly StatusMetricId[]): boolean {
  return left.length === right.length && left.every((metric, index) => metric === right[index]);
}

function sameSummaryOrder(
  left: readonly StatusSummarySectionId[],
  right: readonly StatusSummarySectionId[],
): boolean {
  return left.length === right.length && left.every((section, index) => section === right[index]);
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
  const { settings: attributionSettings, updateSettings: updateAttributionSettings } =
    useSharedAccountAttributionSettings();
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
      <SettingsGroup title="共享账号归因" description="对比本机等值消耗与账号 7 天额度变化。">
        <SettingRow
          title="估算本机与他人用量"
          description="只在本机计算；差额是估算值，不会读取其他使用者的会话。"
        >
          <ToggleButton
            active={attributionSettings.enabled}
            label="共享账号用量归因"
            onClick={() => updateAttributionSettings({ enabled: !attributionSettings.enabled })}
          />
        </SettingRow>
        <SettingRow title="雷达 7 天套餐总额" description="默认按 20x Pro；本机等值金额除以该套餐 7 天总额度，得到本机额度占比。">
          <select
            aria-label="共享账号归因雷达套餐"
            className="app-settings-select"
            disabled={!attributionSettings.enabled}
            onChange={(event) => updateAttributionSettings({
              radarTier: event.currentTarget.value as SharedAccountRadarTier,
            })}
            value={attributionSettings.radarTier}
          >
            {SHARED_ACCOUNT_RADAR_TIER_OPTIONS.map((option) => (
              <option key={option.value} value={option.value}>{option.label}</option>
            ))}
          </select>
        </SettingRow>
        <SettingRow title="本机价格模型" description="与折线图反推和累计 API 等值共用同一项。">
          <select
            aria-label="共享账号归因价格模型"
            className="app-settings-select"
            disabled={!attributionSettings.enabled}
            onChange={(event) => updateAttributionSettings({
              priceModel: event.currentTarget.value as OfficialAPIPriceModel,
            })}
            value={attributionSettings.priceModel}
          >
            {QUOTA_PRICE_MODEL_OPTIONS.map((option) => (
              <option key={option.value} value={option.value}>{option.label}</option>
            ))}
          </select>
        </SettingRow>
        <div className="app-settings-note">
          归因会自动使用与雷达日期相容的价格基准；详情仍单独显示按当前官方 API 单价计算的金额。
        </div>
      </SettingsGroup>
    </>
  );
}

function AutomationSettings({
  autoResumeCancelling,
  autoResumeError,
  autoResumeLoading,
  autoResumeRunning,
  autoResumeSaving,
  autoResumeSettings,
  autoResumeStatus,
  autoResumeThreads,
  onCancelAutoResume,
  onRefreshAutoResume,
  onRunAutoResume,
  onSaveAutoResume,
}: Pick<AppSettingsDialogProps,
  | "autoResumeCancelling"
  | "autoResumeError"
  | "autoResumeLoading"
  | "autoResumeRunning"
  | "autoResumeSaving"
  | "autoResumeSettings"
  | "autoResumeStatus"
  | "autoResumeThreads"
  | "onCancelAutoResume"
  | "onRefreshAutoResume"
  | "onRunAutoResume"
  | "onSaveAutoResume"
>) {
  const [draft, setDraft] = useState(() => sanitizeAutoResumeSettings(autoResumeSettings));
  const [threadQuery, setThreadQuery] = useState("");
  const [selectedProjectKey, setSelectedProjectKey] = useState(
    () => autoResumeProjectKey(autoResumeSettings.threadCwd),
  );
  const [composerThreadId, setComposerThreadId] = useState("");
  const [visibleThreadLimit, setVisibleThreadLimit] = useState(AUTO_RESUME_THREAD_PAGE_SIZE);
  const [expandedTaskId, setExpandedTaskId] = useState<string | null>(
    () => sanitizeAutoResumeSettings(autoResumeSettings).selectedTaskId || null,
  );
  const [pendingDeleteId, setPendingDeleteId] = useState<string | null>(null);
  const [localError, setLocalError] = useState<string | null>(null);

  useEffect(() => {
    const next = sanitizeAutoResumeSettings(autoResumeSettings);
    setDraft(next);
    setExpandedTaskId((current) => (
      current && next.tasks.some((task) => task.id === current)
        ? current
        : (next.selectedTaskId || null)
    ));
    setLocalError(null);
  }, [autoResumeSettings]);

  const projectOptions = useMemo(
    () => buildAutoResumeProjects(autoResumeThreads),
    [autoResumeThreads],
  );

  useEffect(() => {
    setSelectedProjectKey((current) => resolveAutoResumeProjectKey(
      projectOptions,
      current,
      autoResumeThreads.find((thread) => thread.id === composerThreadId)?.cwd
        ?? autoResumeSettings.threadCwd,
    ));
  }, [autoResumeSettings.threadCwd, autoResumeThreads, composerThreadId, projectOptions]);

  useEffect(() => {
    setVisibleThreadLimit(AUTO_RESUME_THREAD_PAGE_SIZE);
  }, [selectedProjectKey, threadQuery]);

  const normalizedDraft = sanitizeAutoResumeSettings(draft);
  const dirty = JSON.stringify(normalizedDraft)
    !== JSON.stringify(sanitizeAutoResumeSettings(autoResumeSettings));
  const selectedProject = projectOptions.find((project) => project.key === selectedProjectKey);
  const projectThreads = useMemo(
    () => autoResumeThreadsInProject(autoResumeThreads, selectedProjectKey),
    [autoResumeThreads, selectedProjectKey],
  );
  const matchingThreads = useMemo(
    () => matchingAutoResumeThreads(autoResumeThreads, selectedProjectKey, threadQuery),
    [autoResumeThreads, selectedProjectKey, threadQuery],
  );
  const filteredThreads = useMemo(
    () => visibleAutoResumeThreads(
      autoResumeThreads,
      selectedProjectKey,
      threadQuery,
      composerThreadId,
      visibleThreadLimit,
    ),
    [autoResumeThreads, composerThreadId, selectedProjectKey, threadQuery, visibleThreadLimit],
  );
  const selectedThread = autoResumeThreads.find((thread) => thread.id === composerThreadId);
  const busy = autoResumeLoading || autoResumeSaving || autoResumeRunning || autoResumeStatus.isRunning;
  const runInProgress = autoResumeRunning || autoResumeStatus.isRunning;
  const cancellationPending = autoResumeCancelling || autoResumeStatus.state === "cancelling";
  const taskStatusById = new Map(
    (autoResumeStatus.tasks ?? []).map((status) => [status.taskId, status]),
  );

  function updateTask(taskId: string, patch: Partial<AutoResumeTaskSettings>) {
    setDraft((current) => sanitizeAutoResumeSettings({
      ...current,
      selectedTaskId: taskId,
      tasks: current.tasks.map((task) => (
        task.id === taskId
          ? { ...task, ...patch, updatedAt: Date.now() }
          : task
      )),
    }));
    setLocalError(null);
  }

  function selectThread(thread: AutoResumeThreadOption) {
    setComposerThreadId(thread.id);
    setLocalError(null);
  }

  async function persist(next: AutoResumeSettings) {
    try {
      const normalized = sanitizeAutoResumeSettings(next);
      await onSaveAutoResume(normalized);
      setDraft(normalized);
      setLocalError(null);
      return true;
    } catch (error) {
      setLocalError(shortErrorMessage(error, "设置没有保存，请重试。"));
      return false;
    }
  }

  async function saveTask(taskId: string) {
    const task = normalizedDraft.tasks.find((candidate) => candidate.id === taskId);
    if (!task) return false;
    const validation = validateAutoResumeTask(task, false);
    if (validation) {
      setLocalError(validation);
      return false;
    }
    return persist({ ...normalizedDraft, selectedTaskId: taskId });
  }

  async function createTask() {
    if (!selectedThread) {
      setLocalError("请先选择一个 Codex 会话。");
      return;
    }
    const existing = normalizedDraft.tasks.find((task) => task.threadId === selectedThread.id);
    if (existing) {
      setExpandedTaskId(existing.id);
      setDraft((current) => sanitizeAutoResumeSettings({
        ...current,
        selectedTaskId: existing.id,
      }));
      setLocalError("这个会话已经在保护列表中，已定位到原任务。");
      return;
    }
    const task = createAutoResumeTask(selectedThread);
    const next = sanitizeAutoResumeSettings({
      ...normalizedDraft,
      selectedTaskId: task.id,
      tasks: [...normalizedDraft.tasks, task],
    });
    if (await persist(next)) {
      setExpandedTaskId(task.id);
      setLocalError("任务已创建并保持暂停；确认条件后再开启保护。");
    }
  }

  async function toggleProtection(task: AutoResumeTaskSettings) {
    const enabling = !task.enabled;
    if (enabling && !hasAutomaticTrigger(task)) {
      setExpandedTaskId(task.id);
      setLocalError("请先选择至少一种失败原因、定时或额度恢复条件。");
      return;
    }
    const next = sanitizeAutoResumeSettings({
      ...normalizedDraft,
      selectedTaskId: task.id,
      tasks: normalizedDraft.tasks.map((candidate) => (
        candidate.id === task.id
          ? { ...candidate, enabled: enabling, updatedAt: Date.now() }
          : candidate
      )),
    });
    if (await persist(next)) {
      setLocalError(enabling ? "任务已进入保护状态。" : "任务已暂停。");
    }
  }

  async function deleteTask(taskId: string) {
    const remaining = normalizedDraft.tasks.filter((task) => task.id !== taskId);
    const next = sanitizeAutoResumeSettings({
      ...normalizedDraft,
      selectedTaskId: remaining[0]?.id ?? "",
      tasks: remaining,
    });
    if (await persist(next)) {
      setExpandedTaskId(remaining[0]?.id ?? null);
      setPendingDeleteId(null);
      setLocalError("监控任务已删除；Codex 原会话未受影响。");
    }
  }

  async function runNow(taskId: string) {
    const task = normalizedDraft.tasks.find((candidate) => candidate.id === taskId);
    if (!task) return;
    const validation = validateAutoResumeTask(task, true);
    if (validation) {
      setLocalError(validation);
      return;
    }
    if (dirty && !(await saveTask(taskId))) return;
    try {
      await onRunAutoResume(taskId);
      setLocalError(null);
    } catch (error) {
      setLocalError(shortErrorMessage(error, "本次续跑没有启动，请重试。"));
    }
  }

  async function cancelRun() {
    try {
      await onCancelAutoResume();
      setLocalError(null);
    } catch (error) {
      setLocalError(shortErrorMessage(error, "本次续跑没有停止，请重试。"));
    }
  }

  return (
    <>
      <div className="auto-resume-safety-note" role="note">
        <strong>一条任务保护一个 Codex 会话</strong>
        <span>每条任务独立配置并持久化；应用内串行执行。只有显式开启“自动批准”时，当前 turn 的普通命令与文件变更才会逐条放行；破坏性操作、额外权限、人工输入和未知请求仍会拦截。“任务被中断”可能包含主动停止，只有勾选后才会续跑。</span>
      </div>

      <SettingsGroup title="创建监控任务" description="保留完整会话选择器；创建后默认暂停，可以先编辑再开启保护。">
        <label className="auto-resume-project-picker">
          <span>项目文件夹</span>
          <select
            aria-label="自动续跑项目文件夹"
            className="app-settings-select"
            disabled={projectOptions.length === 0}
            onChange={(event) => {
              setSelectedProjectKey(event.currentTarget.value);
              setThreadQuery("");
              setComposerThreadId("");
            }}
            value={selectedProjectKey}
          >
            {projectOptions.length === 0 ? <option value="">暂无可选项目</option> : null}
            {projectOptions.map((project) => (
              <option key={project.key} value={project.key}>
                {project.name} · {project.threadCount} 个会话
              </option>
            ))}
          </select>
          <small>
            {selectedProject
              ? `${selectedProject.cwd || "未记录工作目录"} · 共 ${selectedProject.threadCount} 个会话`
              : (autoResumeLoading ? "正在读取本机项目…" : "刷新后选择项目文件夹")}
          </small>
        </label>
        <form
          className="auto-resume-thread-tools"
          onSubmit={(event) => {
            event.preventDefault();
            void onRefreshAutoResume();
          }}
        >
          <label>
            <span>搜索当前项目的标题、ID 或状态</span>
            <div className="auto-resume-search-control">
              <input
                aria-label="搜索自动续跑会话"
                onChange={(event) => setThreadQuery(event.currentTarget.value)}
                placeholder="输入关键词；回车即可刷新"
                type="search"
                value={threadQuery}
              />
              <button
                aria-label="应用搜索并刷新会话"
                disabled={autoResumeLoading}
                title="应用搜索并刷新会话"
                type="submit"
              >
                <span aria-hidden="true">→</span>
              </button>
            </div>
          </label>
          <button
            className="app-settings-action"
            disabled={autoResumeLoading}
            onClick={() => void onRefreshAutoResume()}
            type="button"
          >
            {autoResumeLoading ? "刷新中…" : "刷新会话"}
          </button>
        </form>
        <div className="auto-resume-thread-summary" aria-live="polite">
          {selectedProject
            ? `当前显示 ${filteredThreads.length} / ${matchingThreads.length} 条 · 项目共 ${projectThreads.length} 条${filteredThreads.length < matchingThreads.length ? " · 继续下滑自动加载" : ""}`
            : "请先选择项目文件夹"}
        </div>
        <div
          aria-label="自动续跑目标会话"
          className="auto-resume-thread-list is-compact"
          onScroll={(event) => {
            const list = event.currentTarget;
            const distanceToBottom = list.scrollHeight - list.scrollTop - list.clientHeight;
            if (distanceToBottom <= 48 && filteredThreads.length < matchingThreads.length) {
              setVisibleThreadLimit((current) => Math.min(
                current + AUTO_RESUME_THREAD_PAGE_SIZE,
                matchingThreads.length,
              ));
            }
          }}
          role="listbox"
        >
          {filteredThreads.length > 0 ? filteredThreads.map((thread) => (
            <button
              aria-selected={composerThreadId === thread.id}
              className={composerThreadId === thread.id ? "is-selected" : ""}
              key={thread.id}
              onClick={() => selectThread(thread)}
              role="option"
              type="button"
            >
              <span>
                <strong>{thread.title || "未命名会话"}</strong>
                <em>{thread.status || "状态未知"}</em>
              </span>
              <small>{formatAutoResumeTimestamp(thread.updatedAt)} · {thread.source || "本地"} · ID {thread.id}</small>
            </button>
          )) : (
            <div className="auto-resume-empty">
              {autoResumeLoading
                ? "正在读取本机会话…"
                : (selectedProject ? "当前项目没有匹配的会话，请调整搜索或按回车刷新。" : "请先选择项目文件夹。")}
            </div>
          )}
          {filteredThreads.length > 0 && filteredThreads.length < matchingThreads.length ? (
            <div aria-live="polite" className="auto-resume-thread-progress">
              继续下滑，加载后续 {Math.min(
                AUTO_RESUME_THREAD_PAGE_SIZE,
                matchingThreads.length - filteredThreads.length,
              )} 条
            </div>
          ) : null}
        </div>
        <div className="auto-resume-selected" aria-live="polite">
          <strong>当前选择</strong>
          <span>{selectedThread?.title || "尚未选择会话"}</span>
          {selectedThread?.cwd ? <code>{selectedThread.cwd}</code> : null}
          {selectedThread?.id ? <small>thread ID: {selectedThread.id}</small> : null}
          <button
            className="app-settings-action is-primary"
            disabled={!selectedThread || autoResumeSaving}
            onClick={() => void createTask()}
            type="button"
          >
            {autoResumeSaving ? "创建中…" : "创建任务"}
          </button>
        </div>
        <div className="app-settings-note">创建本身不会发送任何内容；默认开启额度恢复条件，但保护开关保持关闭。</div>
      </SettingsGroup>

      <SettingsGroup
        title="监控任务"
        description={`${normalizedDraft.tasks.filter((task) => task.enabled).length} 条保护中 · ${normalizedDraft.tasks.length} 条任务；同一时间只执行一条。`}
      >
        <div className="auto-resume-task-list">
          {normalizedDraft.tasks.length === 0 ? (
            <div className="auto-resume-empty is-task-empty">
              还没有监控任务。请在上方选择会话并创建。
            </div>
          ) : normalizedDraft.tasks.map((task) => {
            const status = taskStatusById.get(task.id);
            const expanded = expandedTaskId === task.id;
            const isTaskRunning = status?.isRunning === true
              || autoResumeStatus.runningTaskId === task.id;
            const selectedFailureReasons = new Set(task.failureRecoveryReasons);
            const allFailureReasonsSelected =
              selectedFailureReasons.size === AUTO_RESUME_FAILURE_REASONS.length;
            const hasRiskyFailureReason = AUTO_RESUME_FAILURE_REASONS.some(
              ({ id, risky }) => risky && selectedFailureReasons.has(id),
            );
            return (
              <article
                className={`auto-resume-task-card${task.enabled ? " is-protected" : ""}${expanded ? " is-expanded" : ""}`}
                data-state={status?.state ?? (task.enabled ? "waiting" : "disabled")}
                key={task.id}
              >
                <header className="auto-resume-task-header">
                  <button
                    aria-expanded={expanded}
                    className="auto-resume-task-disclosure"
                    onClick={() => {
                      setExpandedTaskId(expanded ? null : task.id);
                      setDraft((current) => sanitizeAutoResumeSettings({
                        ...current,
                        selectedTaskId: task.id,
                      }));
                    }}
                    type="button"
                  >
                    <span className="auto-resume-task-state-dot" aria-hidden="true" />
                    <span className="auto-resume-task-summary">
                      <span>
                        <strong>{task.threadTitle || "未命名会话"}</strong>
                        <em>{displayAutoResumeTaskState(task, status)}</em>
                      </span>
                      <small>{task.threadCwd || "未记录项目"} · ID {task.threadId.slice(-6)}</small>
                      <span className="auto-resume-task-chips">
                        {autoResumeTriggerLabels(task).map((label) => <i key={label}>{label}</i>)}
                      </span>
                    </span>
                    <span className="auto-resume-task-chevron" aria-hidden="true">
                      {expanded ? "▴" : "▾"}
                    </span>
                  </button>
                  <ToggleButton
                    active={task.enabled}
                    disabled={autoResumeSaving || isTaskRunning}
                    label={`${task.threadTitle || "监控任务"}保护`}
                    onClick={() => void toggleProtection(task)}
                  />
                </header>

                {expanded ? (
                  <div className="auto-resume-task-editor">
                    <div className="auto-resume-task-runtime" aria-live="polite">
                      <strong>{displayAutoResumeTaskState(task, status)}</strong>
                      <span>{status?.message || (task.enabled ? "正在等待触发条件" : "任务已暂停")}</span>
                    </div>

                    <section className="auto-resume-trigger-section">
                      <header>
                        <span>
                          <strong>定时续跑</strong>
                          <small>按间隔或每天固定时间启动同一会话的下一轮。</small>
                        </span>
                      </header>
                      <div aria-label="自动续跑时间计划" className="auto-resume-mode-choice" role="radiogroup">
                        {([
                          ["off", "关闭定时", "只保留其他触发"],
                          ["interval", "按间隔", "固定分钟数后触发"],
                          ["daily", "每天", "每天固定时间触发"],
                        ] as const).map(([mode, label, description]) => (
                          <button
                            aria-checked={task.scheduleMode === mode}
                            className={task.scheduleMode === mode ? "is-active" : ""}
                            disabled={isTaskRunning}
                            key={mode}
                            onClick={() => updateTask(task.id, { scheduleMode: mode })}
                            role="radio"
                            type="button"
                          >
                            <strong>{label}</strong><span>{description}</span>
                          </button>
                        ))}
                      </div>
                      {task.scheduleMode === "interval" ? (
                        <SettingRow title="触发间隔" description="从上一次自动续跑完成后计算。">
                          <select
                            aria-label="自动续跑间隔"
                            className="app-settings-select"
                            disabled={isTaskRunning}
                            onChange={(event) => updateTask(task.id, { intervalMinutes: Number(event.currentTarget.value) })}
                            value={task.intervalMinutes}
                          >
                            {AUTO_RESUME_INTERVAL_OPTIONS.map((minutes) => (
                              <option key={minutes} value={minutes}>{formatInterval(minutes)}</option>
                            ))}
                          </select>
                        </SettingRow>
                      ) : null}
                      {task.scheduleMode === "daily" ? (
                        <SettingRow title="每日时间" description="使用当前设备的本地时区。">
                          <input
                            aria-label="自动续跑每日时间"
                            className="app-settings-time"
                            disabled={isTaskRunning}
                            onChange={(event) => {
                              const [dailyHour, dailyMinute] = event.currentTarget.value.split(":").map(Number);
                              if (Number.isFinite(dailyHour) && Number.isFinite(dailyMinute)) {
                                updateTask(task.id, { dailyHour, dailyMinute });
                              }
                            }}
                            type="time"
                            value={`${String(task.dailyHour).padStart(2, "0")}:${String(task.dailyMinute).padStart(2, "0")}`}
                          />
                        </SettingRow>
                      ) : null}
                    </section>

                    <section className="auto-resume-trigger-section">
                      <header>
                        <label className="auto-resume-type-checkbox">
                          <input
                            aria-label="开启额度恢复续跑"
                            checked={task.quotaResumeEnabled}
                            disabled={isTaskRunning}
                            onChange={() => updateTask(task.id, {
                              quotaResumeEnabled: !task.quotaResumeEnabled,
                            })}
                            type="checkbox"
                          />
                          <span>
                            <strong>额度恢复续跑</strong>
                            <small>对应 usageLimitExceeded；只有勾选后才显示下面的额度选项。</small>
                          </span>
                        </label>
                      </header>
                      {task.quotaResumeEnabled ? (
                        <>
                        <div
                          aria-label="额度恢复监测窗口"
                          className="auto-resume-mode-choice"
                          role="radiogroup"
                        >
                          {([
                            ["either", "取较低值", "5 小时与 7 天中，按剩余更低者判断"],
                            ["fiveHour", "5 小时", "只按 5 小时额度判断（若可用）"],
                            ["sevenDay", "7 天", "只按 7 天额度判断（若可用）"],
                          ] as const).map(([window, label, description]) => (
                            <button
                              aria-checked={task.quotaWindow === window}
                              className={task.quotaWindow === window ? "is-active" : ""}
                              disabled={isTaskRunning}
                              key={window}
                              onClick={() => updateTask(task.id, { quotaWindow: window })}
                              role="radio"
                              type="button"
                            >
                              <strong>{label}</strong><span>{description}</span>
                            </button>
                          ))}
                        </div>
                        <p className="auto-resume-threshold-explanation">
                          额度先降到“开始等待刷新”值或以下，才记录本轮耗尽；之后恢复到“刷新后续跑”值或以上时续跑，避免额度本来充足时误触发。
                        </p>
                        <div className="auto-resume-number-grid">
                          <label>
                            <span><strong>开始等待刷新</strong><em>先降到此值或以下</em></span>
                            <span><input aria-label="额度开始等待刷新值" disabled={isTaskRunning} max="20" min="0" onChange={(event) => updateTask(task.id, { quotaLowThresholdPercent: Number(event.currentTarget.value) })} type="number" value={task.quotaLowThresholdPercent} />%</span>
                          </label>
                          <label>
                            <span><strong>刷新后续跑</strong><em>恢复到此值或以上</em></span>
                            <span><input aria-label="额度刷新后续跑值" disabled={isTaskRunning} max="100" min="1" onChange={(event) => updateTask(task.id, { quotaRecoveryThresholdPercent: Number(event.currentTarget.value) })} type="number" value={task.quotaRecoveryThresholdPercent} />%</span>
                          </label>
                        </div>
                        </>
                      ) : null}
                    </section>

                    <section className="auto-resume-trigger-section auto-resume-failure-selector">
                      <header>
                        <span>
                          <strong>失败 / 中断续跑</strong>
                          <small>逐项匹配 Codex app-server 终态/错误码；未勾选的原因不会自动重试。</small>
                        </span>
                        <button
                          className="app-settings-action"
                          disabled={isTaskRunning}
                          onClick={() => updateTask(task.id, {
                            failureRecoveryPolicyVersion: 2,
                            failureRecoveryReasons: allFailureReasonsSelected
                              ? []
                              : AUTO_RESUME_FAILURE_REASONS.map(({ id }) => id),
                            capacityRecoveryEnabled: !allFailureReasonsSelected,
                          })}
                          type="button"
                        >
                          {allFailureReasonsSelected ? "清空" : "全选"}
                        </button>
                      </header>
                      <div className="auto-resume-failure-grid">
                        {AUTO_RESUME_FAILURE_REASONS.map(({ id, label }) => {
                          const selected = selectedFailureReasons.has(id);
                          return (
                            <label className={selected ? "is-active" : ""} key={id}>
                              <input
                                checked={selected}
                                disabled={isTaskRunning}
                                onChange={() => updateTask(task.id, {
                                  failureRecoveryPolicyVersion: 2,
                                  failureRecoveryReasons: selected
                                    ? task.failureRecoveryReasons.filter((reason) => reason !== id)
                                    : [...task.failureRecoveryReasons, id],
                                })}
                                type="checkbox"
                              />
                              <span title={`${label} · ${id}`}>{label}</span>
                            </label>
                          );
                        })}
                      </div>
                      <p className={hasRiskyFailureReason ? "is-warning" : ""}>
                        {hasRiskyFailureReason
                          ? "谨慎条件可能包含主动停止或必须人工修复的问题；仍只按 Codex 的结构化状态判断。"
                          : "不按报错文案猜测；自动续跑产生的后续轮也不会再次触发失败续跑。"}
                      </p>
                    </section>

                    <section className="auto-resume-trigger-section">
                      <header>
                        <span>
                          <strong>自动批准</strong>
                          <small>只处理当前会话当前 turn 的 Codex 结构化批准请求。</small>
                        </span>
                      </header>
                      <label className="auto-resume-type-checkbox is-body">
                        <input
                          aria-label="自动批准普通操作"
                          checked={task.autoApprovalEnabled}
                          disabled={isTaskRunning}
                          onChange={() => updateTask(task.id, {
                            autoApprovalEnabled: !task.autoApprovalEnabled,
                          })}
                          type="checkbox"
                        />
                        <span>
                          <strong>自动批准普通操作</strong>
                          <small>普通命令与文件变更逐条放行；每一条都会重新做安全判断，不使用整会话永久批准。</small>
                        </span>
                      </label>
                      <p className="is-warning">
                        rm -rf、磁盘擦除、破坏性 Git / 数据库命令、额外权限扩张、跨会话或无法解析的请求仍会拦截并停止本轮。
                      </p>
                    </section>

                    <section className="auto-resume-trigger-section">
                      <header>
                        <span>
                          <strong>续跑方式</strong>
                          <small>选择 app-server 无痕空输入，或发送一条可见提示词。</small>
                        </span>
                      </header>
                      <label className="auto-resume-type-checkbox is-body">
                        <input
                          aria-label="无痕续跑"
                          checked={task.invisibleResumeEnabled}
                          disabled={isTaskRunning}
                          onChange={() => updateTask(task.id, {
                            invisibleResumeEnabled: !task.invisibleResumeEnabled,
                          })}
                          type="checkbox"
                        />
                        <span>
                          <strong>无痕续跑</strong>
                          <small>通过 Codex app-server 的 turn/start + input: [] 启动同一 thread 的下一轮；旧版不接受空输入时才回退发送可见的“继续”。</small>
                        </span>
                      </label>
                      <label className={`auto-resume-prompt${task.invisibleResumeEnabled ? " is-disabled" : ""}`}>
                        <span>续跑提示词</span>
                        <textarea
                          aria-label="自动续跑提示词"
                          disabled={isTaskRunning || task.invisibleResumeEnabled}
                          maxLength={8_000}
                          onChange={(event) => updateTask(task.id, { prompt: event.currentTarget.value })}
                          rows={3}
                          value={task.prompt}
                        />
                        <small>
                          {task.invisibleResumeEnabled
                            ? "已启用无痕续跑，提示词不会发送；取消勾选后可编辑并作为可见消息发送。"
                            : `${task.prompt.length} / 8000 · 这段文字会作为可见用户消息发送。`}
                        </small>
                      </label>
                    </section>

                    <section className="auto-resume-trigger-section">
                      <header>
                        <span>
                          <strong>保护限制</strong>
                          <small>限制自动执行频率，并决定是否通知结果。</small>
                        </span>
                      </header>
                      <div className="auto-resume-number-grid">
                        <label>
                          <span><strong>冷却时间</strong><em>两次自动续跑至少等待</em></span>
                          <span><input aria-label="自动续跑冷却分钟" disabled={isTaskRunning} max="1440" min="1" onChange={(event) => updateTask(task.id, { cooldownMinutes: Number(event.currentTarget.value) })} type="number" value={task.cooldownMinutes} />分钟</span>
                        </label>
                        <label>
                          <span><strong>每日上限</strong><em>Swift 与 Tauri 合计</em></span>
                          <span><input aria-label="自动续跑每日上限" disabled={isTaskRunning} max="24" min="1" onChange={(event) => updateTask(task.id, { maxRunsPerDay: Number(event.currentTarget.value) })} type="number" value={task.maxRunsPerDay} />次</span>
                        </label>
                      </div>
                      <SettingRow title="结果通知" description="成功、等待或失败后显示系统通知。">
                        <ToggleButton
                          active={task.notifyOnResult}
                          disabled={isTaskRunning}
                          label="自动续跑结果通知"
                          onClick={() => updateTask(task.id, { notifyOnResult: !task.notifyOnResult })}
                        />
                      </SettingRow>
                    </section>

                    <div className="auto-resume-task-actions">
                      {pendingDeleteId === task.id ? (
                        <span className="auto-resume-delete-confirm">
                          <strong>确认删除？</strong>
                          <button className="app-settings-action is-danger" disabled={isTaskRunning} onClick={() => void deleteTask(task.id)} type="button">确认删除</button>
                          <button className="app-settings-action" onClick={() => setPendingDeleteId(null)} type="button">取消</button>
                        </span>
                      ) : (
                        <button className="app-settings-action is-danger" disabled={isTaskRunning} onClick={() => setPendingDeleteId(task.id)} type="button">删除任务</button>
                      )}
                      <span />
                      <button className="app-settings-action" disabled={autoResumeSaving || isTaskRunning} onClick={() => void saveTask(task.id)} type="button">
                        {autoResumeSaving ? "保存中…" : "保存任务"}
                      </button>
                      {isTaskRunning ? (
                        <button className="app-settings-action is-danger" disabled={cancellationPending} onClick={() => void cancelRun()} type="button">
                          {cancellationPending ? "停止中…" : "停止本次续跑"}
                        </button>
                      ) : (
                        <button className="app-settings-action is-primary" disabled={busy || autoResumeCancelling} onClick={() => void runNow(task.id)} type="button">
                          {autoResumeRunning ? "启动中…" : "立即测试 / 续跑"}
                        </button>
                      )}
                    </div>
                  </div>
                ) : null}
              </article>
            );
          })}
        </div>
        {(localError || autoResumeError) ? (
          <div className="auto-resume-error" role="alert">{localError || autoResumeError}</div>
        ) : null}
        <div className="auto-resume-actions">
          <span>{dirty ? "有任务修改尚未保存" : `当前设置已同步 · 状态版本 ${autoResumeStatus.revision}`}</span>
          <button className="app-settings-action" disabled={autoResumeLoading} onClick={() => void onRefreshAutoResume()} type="button">刷新状态</button>
          {runInProgress ? <strong>{autoResumeStatus.message || "一条任务正在续跑"}</strong> : null}
        </div>
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
  floatingPreviewSnapshot,
  floatingPreviewRunningThreads,
  onFloatingContentVisibilityChange,
}: Pick<AppSettingsDialogProps,
  | "floatingSettings"
  | "floatingPreviewSnapshot"
  | "floatingPreviewRunningThreads"
  | "onFloatingContentVisibilityChange"
>) {
  const visibility = sanitizeFloatingContentVisibility(floatingSettings.contentVisibility);
  return (
    <FloatingStructureEditor
      onChange={onFloatingContentVisibilityChange}
      runningThreads={floatingPreviewRunningThreads}
      settings={floatingSettings}
      snapshot={floatingPreviewSnapshot}
      visibility={visibility}
    />
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
}: Pick<AppSettingsDialogProps,
  | "codexHome"
  | "onClose"
  | "onCodexHomeChange"
  | "onCodexHomeReset"
  | "onOpenProviderRepair"
>) {
  const sourceLabel = codexHome.source === "manual" ? "手动目录" : codexHome.exists ? "自动发现" : "等待选择";
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
        <div className="app-settings-note">Codex 页面连接和会话操作已归入独立的“会话增强”分类。</div>
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

function validateAutoResumeTask(settings: AutoResumeTaskSettings, forRun: boolean): string | null {
  if ((settings.enabled || forRun) && settings.threadId.trim().length === 0) {
    return forRun ? "请先明确选择要立即续跑的会话。" : "开启自动续跑前，请先选择目标会话。";
  }
  if ((settings.enabled || forRun) && settings.prompt.trim().length === 0) {
    return "续跑提示词不能为空。";
  }
  if (settings.quotaResumeEnabled
    && settings.quotaRecoveryThresholdPercent <= settings.quotaLowThresholdPercent) {
    return "“刷新后续跑”数值必须高于“开始等待刷新”数值。";
  }
  if (!Number.isFinite(settings.cooldownMinutes) || settings.cooldownMinutes < 1) {
    return "冷却时间至少为 1 分钟。";
  }
  if (!Number.isFinite(settings.maxRunsPerDay) || settings.maxRunsPerDay < 1) {
    return "每日续跑上限至少为 1 次。";
  }
  if (settings.enabled && !hasAutomaticTrigger(settings)) {
    return "开启保护前，请至少选择一种自动触发条件。";
  }
  return null;
}

function displayAutoResumeTaskState(
  task: AutoResumeTaskSettings,
  status?: AutoResumeTaskRuntimeStatus,
): string {
  if (status?.isRunning) return "正在续跑";
  if (status?.waitingForQuota) return "等待额度恢复";
  if (!task.enabled) return "已暂停";
  switch (status?.state) {
    case "disabled": return "已关闭";
    case "needsTarget": return "等待选择任务";
    case "armed": return "已就绪";
    case "waiting": return "等待触发";
    case "running": return "正在续跑";
    case "scheduled": return "等待计划";
    case "ready": return "已就绪";
    case "idle": return "等待触发";
    case "cancelling": return "正在停止";
    case "succeeded": return "最近续跑已完成";
    case "waitingQuota": return "等待额度恢复";
    case "needsAttention": return "等待你处理";
    case "failed":
    case "error": return "续跑失败";
    case "guarded": return "安全限制已生效";
    case "skipped": return "本次已跳过";
    default: return task.enabled ? "保护中" : "已暂停";
  }
}

function hasAutomaticTrigger(task: AutoResumeTaskSettings): boolean {
  return task.capacityRecoveryEnabled
    || task.quotaResumeEnabled
    || task.scheduleMode !== "off";
}

function autoResumeTriggerLabels(task: AutoResumeTaskSettings): string[] {
  const labels: string[] = [];
  if (task.failureRecoveryReasons.length > 0) {
    labels.push(`失败 ${task.failureRecoveryReasons.length}项`);
  }
  if (task.scheduleMode !== "off") labels.push("定时");
  if (task.quotaResumeEnabled) {
    const quotaLabel = task.quotaWindow === "fiveHour"
      ? "额度·5h"
      : (task.quotaWindow === "sevenDay" ? "额度·7d" : "额度·低者");
    labels.push(quotaLabel);
  }
  return labels.length > 0 ? labels : ["未设触发"];
}

function formatInterval(minutes: number): string {
  if (minutes < 60) return `每 ${minutes} 分钟`;
  const hours = minutes / 60;
  return `每 ${hours} 小时`;
}

function shortErrorMessage(error: unknown, fallback: string): string {
  if (error instanceof Error && error.message.trim()) return error.message;
  if (typeof error === "string" && error.trim()) return error;
  return fallback;
}
