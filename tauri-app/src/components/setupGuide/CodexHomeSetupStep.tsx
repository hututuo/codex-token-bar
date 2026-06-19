import { useEffect, useState } from "react";
import type { CodexHomeStatus } from "../../types/dashboard";
import { SetupStep } from "./SetupStep";

interface CodexHomeSetupStepProps {
  codexHome: CodexHomeStatus;
  onCodexHomeChange: (path: string) => Promise<void>;
  onCodexHomeReset: () => Promise<void>;
}

export function CodexHomeSetupStep({
  codexHome,
  onCodexHomeChange,
  onCodexHomeReset,
}: CodexHomeSetupStepProps) {
  const [editingPath, setEditingPath] = useState(!codexHome.exists);
  const [pathDraft, setPathDraft] = useState(codexHome.path);
  const [savingPath, setSavingPath] = useState(false);
  const [pathError, setPathError] = useState<string | null>(null);

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

  return (
    <SetupStep index="1" ok={codexHome.exists} title="Codex 目录" status={codexHome.exists ? "已识别" : "需要选择"}>
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
    </SetupStep>
  );
}
