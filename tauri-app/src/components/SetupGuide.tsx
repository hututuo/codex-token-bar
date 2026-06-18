import { useEffect, useState } from "react";
import type {
  CodexHomeStatus,
  DisplaySurfaceSettings,
  PlatformCapabilities,
} from "../types/dashboard";

interface SetupGuideProps {
  codexHome: CodexHomeStatus;
  displaySurfaces: DisplaySurfaceSettings;
  floatingVisible: boolean;
  platform: PlatformCapabilities;
  statusTrayLiveTextEnabled: boolean;
  onCodexHomeChange: (path: string) => Promise<void>;
  onCodexHomeReset: () => Promise<void>;
  onComplete: () => Promise<void>;
  onToggleFloating: () => void;
  onToggleStatusTray: () => void;
}

export function SetupGuide({
  codexHome,
  displaySurfaces,
  floatingVisible,
  platform,
  statusTrayLiveTextEnabled,
  onCodexHomeChange,
  onCodexHomeReset,
  onComplete,
  onToggleFloating,
  onToggleStatusTray,
}: SetupGuideProps) {
  const [editingPath, setEditingPath] = useState(!codexHome.exists);
  const [pathDraft, setPathDraft] = useState(codexHome.path);
  const [savingPath, setSavingPath] = useState(false);
  const [closing, setClosing] = useState(false);
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
    try {
      await onCodexHomeChange(path);
    } finally {
      setSavingPath(false);
    }
  }

  async function resetPath() {
    setSavingPath(true);
    try {
      await onCodexHomeReset();
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
                <strong>本地读取</strong>
                <span>{codexHome.exists ? "可以开始" : "等待目录"}</span>
              </div>
              <p>数据只从本机 Codex 目录读取；读取失败时页面会显示待读取。</p>
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
