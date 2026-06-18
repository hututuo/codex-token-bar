import { useEffect, useState } from "react";
import type {
  AutostartStatus,
  CodexHomeStatus,
  DisplaySurfaceSettings,
  PlatformCapabilities,
} from "../types/dashboard";

interface SetupGuideProps {
  autostartStatus: AutostartStatus;
  codexHome: CodexHomeStatus;
  displaySurfaces: DisplaySurfaceSettings;
  floatingVisible: boolean;
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
  floatingVisible,
  platform,
  statusTrayLiveTextEnabled,
  onCodexHomeChange,
  onCodexHomeReset,
  onComplete,
  onToggleAutostart,
  onToggleFloating,
  onToggleStatusTray,
}: SetupGuideProps) {
  const [editingPath, setEditingPath] = useState(!codexHome.exists);
  const [pathDraft, setPathDraft] = useState(codexHome.path);
  const [savingPath, setSavingPath] = useState(false);
  const [closing, setClosing] = useState(false);
  const [pathError, setPathError] = useState<string | null>(null);
  const [completionError, setCompletionError] = useState<string | null>(null);

  useEffect(() => {
    setPathDraft(codexHome.path);
    if (!codexHome.exists) {
      setEditingPath(true);
    }
  }, [codexHome.exists, codexHome.path]);

  async function savePath() {
    const path = pathDraft.trim();
    if (path.length === 0) {
      return;
    }

    setSavingPath(true);
    setPathError(null);
    try {
      await onCodexHomeChange(path);
    } catch (error) {
      setPathError(error instanceof Error ? error.message : "Codex 目录保存失败。");
    } finally {
      setSavingPath(false);
    }
  }

  async function resetPath() {
    setSavingPath(true);
    setPathError(null);
    try {
      await onCodexHomeReset();
    } catch (error) {
      setPathError(error instanceof Error ? error.message : "自动发现 Codex 目录失败。");
    } finally {
      setSavingPath(false);
    }
  }

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
          <section className="setup-step">
            <div className={codexHome.exists ? "setup-step-index is-ok" : "setup-step-index"}>
              {codexHome.exists ? "✓" : "1"}
            </div>
            <div className="setup-step-body">
              <div className="setup-step-title">
                <strong>Codex 目录</strong>
                <span>{codexHome.exists ? "已识别" : "需要选择"}</span>
              </div>
              <div className="setup-path-row">
                <span>{codexHome.path}</span>
                <button type="button" onClick={() => setEditingPath((value) => !value)}>
                  手动更改
                </button>
              </div>
              {editingPath ? (
                <div className="setup-path-editor">
                  <input
                    aria-label="Codex 目录"
                    disabled={savingPath}
                    onChange={(event) => setPathDraft(event.currentTarget.value)}
                    onKeyDown={(event) => {
                      if (event.key === "Enter") {
                        void savePath();
                      }
                    }}
                    value={pathDraft}
                  />
                  <button disabled={savingPath || pathDraft.trim().length === 0} onClick={savePath} type="button">
                    保存
                  </button>
                  <button disabled={savingPath} onClick={resetPath} type="button">
                    自动
                  </button>
                </div>
              ) : null}
              {pathError ? <p className="setup-error">{pathError}</p> : null}
            </div>
          </section>

          <section className="setup-step">
            <div className="setup-step-index is-ok">2</div>
            <div className="setup-step-body">
              <div className="setup-step-title">
                <strong>显示面</strong>
                <span>可同时开启</span>
              </div>
              <div className="setup-toggle-row">
                <button
                  className={floatingVisible ? "setup-toggle is-active" : "setup-toggle"}
                  disabled={!platform.floatingWindow.available}
                  onClick={onToggleFloating}
                  title={platform.floatingWindow.note}
                  type="button"
                >
                  <span>悬浮窗</span>
                  <strong>{displaySurfaces.floatingWindowEnabled ? "开" : "关"}</strong>
                </button>
                <button
                  className={statusTrayLiveTextEnabled ? "setup-toggle is-active" : "setup-toggle"}
                  disabled={!platform.statusTray.available}
                  onClick={onToggleStatusTray}
                  title={platform.statusTray.note}
                  type="button"
                >
                  <span>状态栏数字</span>
                  <strong>{displaySurfaces.statusTrayLiveTextEnabled ? "开" : "关"}</strong>
                </button>
              </div>
            </div>
          </section>

          <section className="setup-step">
            <div className="setup-step-index is-ok">3</div>
            <div className="setup-step-body">
              <div className="setup-step-title">
                <strong>常驻运行</strong>
                <span>{autostartStatus.enabled ? "已开启" : "建议开启"}</span>
              </div>
              <div className="setup-toggle-row">
                <button
                  className={autostartStatus.enabled ? "setup-toggle is-active" : "setup-toggle"}
                  disabled={!platform.autostart.available}
                  onClick={onToggleAutostart}
                  title={autostartStatus.message || platform.autostart.note}
                  type="button"
                >
                  <span>开机自启</span>
                  <strong>{autostartStatus.enabled ? "开" : "关"}</strong>
                </button>
              </div>
              <p>建议开启后常驻读取本地状态；这次不开也没关系，之后可在主界面顶部开启。数据只从本机 Codex 目录读取。</p>
            </div>
          </section>
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
