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
import {
  FLOATING_CONTENT_LABELS,
  moveFloatingContent,
  sanitizeFloatingContentVisibility,
} from "../../floating/floatingContent";
import type { FloatingWindowSettings } from "../../floating/floatingSettings";
import { floatingGradientBackground } from "../../floating/floatingSettings";
import { floatingTextPaletteForGroup } from "../../floating/floatingTextPalette";
import { QUOTA_REFRESH_CADENCE_OPTIONS } from "../../settings/quotaRefreshCadence";
import {
  AUTO_RESUME_FAILURE_REASONS,
  AUTO_RESUME_INTERVAL_OPTIONS,
  createAutoResumeTask,
  formatAutoResumeTimestamp,
  sanitizeAutoResumeSettings,
} from "../../settings/autoResume";
import {
  AUTO_RESUME_VISIBLE_THREAD_LIMIT,
  autoResumeProjectKey,
  autoResumeThreadsInProject,
  buildAutoResumeProjects,
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
  FloatingContentGroup,
  FloatingContentVisibility,
  FloatingPalettePatch,
  FloatingUnreadEffect,
  PlatformCapabilities,
  SessionEnhancementSettings,
} from "../../types/dashboard";
import { sanitizeSessionEnhancements } from "../../settings/sessionEnhancements";
import { CodexHomeEditor } from "../dashboardHeader/CodexHomeEditor";
import { CodexInstancesSettings } from "./CodexInstancesSettings";

export type AppSettingsCategory =
  | "general"
  | "session"
  | "instances"
  | "surfaces"
  | "monitoring"
  | "automation"
  | "floating"
  | "content"
  | "alerts"
  | "data";

interface SettingsCategoryDefinition {
  id: AppSettingsCategory;
  label: string;
  description: string;
}

const SETTINGS_CATEGORIES: SettingsCategoryDefinition[] = [
  { id: "general", label: "常规", description: "启动与基础偏好" },
  { id: "session", label: "会话增强", description: "删除、导出、移动、输入与阅读体验" },
  { id: "instances", label: "Codex 实例", description: "多开、隔离、同步与回滚" },
  { id: "automation", label: "自动续跑", description: "按所选中断原因、定时或额度恢复继续" },
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
}: AppSettingsDialogProps) {
  const [selectedCategory, setSelectedCategory] = useState<AppSettingsCategory>(initialCategory);
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
    setSelectedCategory(initialCategory);
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
  onSaveSessionEnhancements,
  sessionConnectionTriggerRef,
  sessionEnhancements,
  threadDeleteBridgeStatus,
}: Pick<AppSettingsDialogProps,
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

  function toggle(key: "sessionDelete" | "markdownExport" | "pasteFix" | "projectMove" | "threadIDBadge" | "conversationView" | "threadScrollRestore") {
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
        <SettingRow title="会话删除" description="使用官方 Codex 删除命令永久删除所选会话。">
          <ToggleButton active={settings.sessionDelete} label="会话删除" onClick={() => toggle("sessionDelete")} />
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

  const normalizedDraft = sanitizeAutoResumeSettings(draft);
  const dirty = JSON.stringify(normalizedDraft)
    !== JSON.stringify(sanitizeAutoResumeSettings(autoResumeSettings));
  const selectedProject = projectOptions.find((project) => project.key === selectedProjectKey);
  const projectThreads = useMemo(
    () => autoResumeThreadsInProject(autoResumeThreads, selectedProjectKey),
    [autoResumeThreads, selectedProjectKey],
  );
  const filteredThreads = useMemo(
    () => visibleAutoResumeThreads(
      autoResumeThreads,
      selectedProjectKey,
      threadQuery,
      composerThreadId,
    ),
    [autoResumeThreads, composerThreadId, selectedProjectKey, threadQuery],
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
        <span>每条任务独立配置并持久化；应用内串行执行。授权确认和人工输入不会被自动批准或代填；“任务被中断”可能包含主动停止，只有勾选后才会续跑。</span>
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
            ? `当前显示 ${filteredThreads.length} 条 · 项目共 ${projectThreads.length} 条 · 最多列出最近 ${AUTO_RESUME_VISIBLE_THREAD_LIMIT} 条`
            : "请先选择项目文件夹"}
        </div>
        <div aria-label="自动续跑目标会话" className="auto-resume-thread-list is-compact" role="listbox">
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
            const allRecoveryConditionsSelected =
              selectedFailureReasons.size === AUTO_RESUME_FAILURE_REASONS.length
              && task.quotaResumeEnabled;
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
                  <span className="auto-resume-task-state-dot" aria-hidden="true" />
                  <button
                    className="auto-resume-task-summary"
                    onClick={() => {
                      setExpandedTaskId(expanded ? null : task.id);
                      setDraft((current) => sanitizeAutoResumeSettings({
                        ...current,
                        selectedTaskId: task.id,
                      }));
                    }}
                    type="button"
                  >
                    <span>
                      <strong>{task.threadTitle || "未命名会话"}</strong>
                      <em>{displayAutoResumeTaskState(task, status)}</em>
                    </span>
                    <small>{task.threadCwd || "未记录项目"} · ID {task.threadId.slice(-6)}</small>
                    <span className="auto-resume-task-chips">
                      {autoResumeTriggerLabels(task).map((label) => <i key={label}>{label}</i>)}
                    </span>
                  </button>
                  <ToggleButton
                    active={task.enabled}
                    disabled={autoResumeSaving || isTaskRunning}
                    label={`${task.threadTitle || "监控任务"}保护`}
                    onClick={() => void toggleProtection(task)}
                  />
                  <button
                    className="app-settings-action"
                    onClick={() => setExpandedTaskId(expanded ? null : task.id)}
                    type="button"
                  >
                    {expanded ? "收起" : "编辑"}
                  </button>
                </header>

                {expanded ? (
                  <div className="auto-resume-task-editor">
                    <div className="auto-resume-task-runtime" aria-live="polite">
                      <strong>{displayAutoResumeTaskState(task, status)}</strong>
                      <span>{status?.message || (task.enabled ? "正在等待触发条件" : "任务已暂停")}</span>
                    </div>

                    <section className="auto-resume-failure-selector">
                      <header>
                        <span>
                          <strong>失败 / 中断续跑条件</strong>
                          <small>逐项匹配 Codex app-server 终态/错误码；额度耗尽会等待恢复。</small>
                        </span>
                        <button
                          className="app-settings-action"
                          disabled={isTaskRunning}
                          onClick={() => updateTask(task.id, {
                            failureRecoveryPolicyVersion: 2,
                            failureRecoveryReasons: allRecoveryConditionsSelected
                              ? []
                              : AUTO_RESUME_FAILURE_REASONS.map(({ id }) => id),
                            capacityRecoveryEnabled: !allRecoveryConditionsSelected,
                            quotaResumeEnabled: !allRecoveryConditionsSelected,
                          })}
                          type="button"
                        >
                          {allRecoveryConditionsSelected ? "清空" : "全选"}
                        </button>
                      </header>
                      <div className="auto-resume-failure-grid">
                        {AUTO_RESUME_FAILURE_REASONS.map(({ id, label }) => {
                          const selected = selectedFailureReasons.has(id);
                          return (
                            <label
                              className={selected ? "is-active" : ""}
                              key={id}
                            >
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
                        <label
                          className={task.quotaResumeEnabled ? "is-active" : ""}
                        >
                          <input
                            checked={task.quotaResumeEnabled}
                            disabled={isTaskRunning}
                            onChange={() => updateTask(task.id, {
                              quotaResumeEnabled: !task.quotaResumeEnabled,
                            })}
                            type="checkbox"
                          />
                          <span title="usageLimitExceeded">额度耗尽（恢复后）</span>
                        </label>
                      </div>
                      <p className={hasRiskyFailureReason ? "is-warning" : ""}>
                        {hasRiskyFailureReason
                          ? "谨慎条件可能包含主动停止或必须人工修复的问题；仍只按 Codex 的结构化状态判断。"
                          : "不按报错文案猜测；自动续跑产生的后续轮也不会再次触发失败续跑。"}
                      </p>
                    </section>

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

                    {task.quotaResumeEnabled ? (
                      <>
                        <SettingRow title="监测窗口" description="选择哪个额度窗口参与恢复判断。">
                          <select
                            aria-label="额度恢复监测窗口"
                            className="app-settings-select"
                            disabled={isTaskRunning}
                            onChange={(event) => updateTask(task.id, {
                              quotaWindow: event.currentTarget.value as AutoResumeTaskSettings["quotaWindow"],
                            })}
                            value={task.quotaWindow}
                          >
                            <option value="either">可用窗口中剩余更低者</option>
                            <option value="fiveHour">5h 窗口</option>
                            <option value="sevenDay">7d 窗口</option>
                          </select>
                        </SettingRow>
                        <div className="auto-resume-number-grid">
                          <label>
                            <span><strong>低位阈值</strong><em>降到此值或以下</em></span>
                            <span><input aria-label="额度低位阈值" disabled={isTaskRunning} max="20" min="0" onChange={(event) => updateTask(task.id, { quotaLowThresholdPercent: Number(event.currentTarget.value) })} type="number" value={task.quotaLowThresholdPercent} />%</span>
                          </label>
                          <label>
                            <span><strong>恢复阈值</strong><em>恢复到此值或以上</em></span>
                            <span><input aria-label="额度恢复阈值" disabled={isTaskRunning} max="100" min="1" onChange={(event) => updateTask(task.id, { quotaRecoveryThresholdPercent: Number(event.currentTarget.value) })} type="number" value={task.quotaRecoveryThresholdPercent} />%</span>
                          </label>
                        </div>
                      </>
                    ) : null}

                    <label className="auto-resume-prompt">
                      <span>续跑提示词</span>
                      <textarea
                        aria-label="自动续跑提示词"
                        disabled={isTaskRunning}
                        maxLength={8_000}
                        onChange={(event) => updateTask(task.id, { prompt: event.currentTarget.value })}
                        rows={3}
                        value={task.prompt}
                      />
                      <small>{task.prompt.length} / 8000 · 默认“继续”先用 app-server 空输入无痕续跑；旧版不支持时才发送可见的“继续”，自定义文字会直接显示</small>
                    </label>

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
    return "额度恢复阈值必须高于低位阈值。";
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
  if (task.quotaResumeEnabled) labels.push("额度恢复");
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

function isFloatingGroupVisible(visibility: FloatingContentVisibility, group: FloatingContentGroup): boolean {
  switch (group) {
    case "rateAndBar": return visibility.showRateAndBar;
    case "usageStatus": return visibility.showUsageStatus;
    case "metrics": return visibility.showMetrics;
    case "runningThreads": return visibility.showRunningThreads;
    case "quota": return visibility.showQuota;
    case "radar": return visibility.showRadar;
    case "crowdRadar": return visibility.showCrowdRadar;
  }
}

function visibilityKey(group: FloatingContentGroup): keyof FloatingContentVisibility {
  switch (group) {
    case "rateAndBar": return "showRateAndBar";
    case "usageStatus": return "showUsageStatus";
    case "metrics": return "showMetrics";
    case "runningThreads": return "showRunningThreads";
    case "quota": return "showQuota";
    case "radar": return "showRadar";
    case "crowdRadar": return "showCrowdRadar";
  }
}
