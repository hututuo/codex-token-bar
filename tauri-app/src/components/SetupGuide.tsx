import { useState } from "react";
import type {
  AutostartStatus,
  CodexHomeStatus,
  DisplaySurfaceSettings,
  PlatformCapabilities,
} from "../types/dashboard";
import { CodexHomeSetupStep } from "./setupGuide/CodexHomeSetupStep";
import { SetupStep } from "./setupGuide/SetupStep";
import { SetupToggle } from "./setupGuide/SetupToggle";

interface SetupGuideProps {
  autostartStatus: AutostartStatus;
  codexHome: CodexHomeStatus;
  displaySurfaces: DisplaySurfaceSettings;
  platform: PlatformCapabilities;
  statusTrayLiveTextEnabled: boolean;
  onCodexHomeChange: (path: string) => Promise<void>;
  onCodexHomeReset: () => Promise<void>;
  onComplete: () => Promise<void>;
  onToggleAutostart: () => void;
  onToggleFloating: () => void;
  onToggleStatusTray: () => void;
}

export function SetupGuide({
  autostartStatus,
  codexHome,
  displaySurfaces,
  platform,
  statusTrayLiveTextEnabled,
  onCodexHomeChange,
  onCodexHomeReset,
  onComplete,
  onToggleAutostart,
  onToggleFloating,
  onToggleStatusTray,
}: SetupGuideProps) {
  const [closing, setClosing] = useState(false);
  const [completionError, setCompletionError] = useState<string | null>(null);
  const statusTrayLiveTextAvailable =
    platform.statusTray.available && platform.statusTrayLiveText.available;

  async function completeGuide() {
    setClosing(true);
    setCompletionError(null);
    try {
      await onComplete();
    } catch (error) {
      setCompletionError(error instanceof Error ? error.message : "首次设置状态保存失败。");
    } finally {
      setClosing(false);
    }
  }

  return (
    <div className="setup-overlay" role="dialog" aria-modal="true" aria-label="首次设置">
      <section className="setup-card">
        <header className="setup-head">
          <div className="setup-mark">CX</div>
          <div>
            <span>首次设置</span>
            <h2>Codex Token Bar</h2>
          </div>
        </header>

        <div className="setup-steps">
          <CodexHomeSetupStep
            codexHome={codexHome}
            onCodexHomeChange={onCodexHomeChange}
            onCodexHomeReset={onCodexHomeReset}
          />

          <SetupStep index="2" title="显示面" status="可同时开启">
            <div className="setup-toggle-row">
              <SetupToggle
                active={displaySurfaces.floatingWindowEnabled}
                disabled={!platform.floatingWindow.available}
                label="悬浮窗"
                note={platform.floatingWindow.note}
                onClick={onToggleFloating}
                valueLabel={displaySurfaces.floatingWindowEnabled ? "开" : "关"}
              />
              <SetupToggle
                active={statusTrayLiveTextEnabled}
                disabled={!statusTrayLiveTextAvailable}
                label={statusTrayLiveTextAvailable ? "状态栏数字" : "托盘图标"}
                note={
                  statusTrayLiveTextAvailable
                    ? platform.statusTrayLiveText.note
                    : platform.statusTray.note
                }
                onClick={onToggleStatusTray}
                valueLabel={
                  statusTrayLiveTextAvailable
                    ? displaySurfaces.statusTrayLiveTextEnabled
                      ? "开"
                      : "关"
                    : platform.statusTray.available
                      ? "已启用"
                      : "待接入"
                }
              />
            </div>
          </SetupStep>

          <SetupStep index="3" title="常驻运行" status={autostartStatus.enabled ? "已开启" : "建议开启"}>
            <div className="setup-toggle-row">
              <SetupToggle
                active={autostartStatus.enabled}
                disabled={!platform.autostart.available}
                label="开机自启"
                note={autostartStatus.message || platform.autostart.note}
                onClick={onToggleAutostart}
                valueLabel={autostartStatus.enabled ? "开" : "关"}
              />
            </div>
            <p>建议开启后常驻读取本地状态；这次不开也没关系，之后可在主界面顶部开启。数据只从本机 Codex 目录读取。</p>
          </SetupStep>
        </div>

        <footer className="setup-actions">
          {completionError ? <span className="setup-error">{completionError}</span> : null}
          <button type="button" onClick={completeGuide} disabled={closing}>
            关闭引导
          </button>
          <button className="setup-primary" type="button" onClick={completeGuide} disabled={closing}>
            进入主界面
          </button>
        </footer>
      </section>
    </div>
  );
}
