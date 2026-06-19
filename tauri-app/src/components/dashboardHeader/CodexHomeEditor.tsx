import { useEffect, useState } from "react";
import type { CodexHomeStatus } from "../../types/dashboard";

interface CodexHomeEditorProps {
  codexHome: CodexHomeStatus;
  onCodexHomeChange: (path: string) => Promise<void>;
  onCodexHomeReset: () => Promise<void>;
  onDone: () => void;
}

export function CodexHomeEditor({
  codexHome,
  onCodexHomeChange,
  onCodexHomeReset,
  onDone,
}: CodexHomeEditorProps) {
  const [pathDraft, setPathDraft] = useState(codexHome.path);
  const [savingPath, setSavingPath] = useState(false);
  const [pathError, setPathError] = useState<string | null>(null);

  useEffect(() => {
    setPathDraft(codexHome.path);
  }, [codexHome.path]);

  async function savePath() {
    setSavingPath(true);
    setPathError(null);
    try {
      await onCodexHomeChange(pathDraft);
      onDone();
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
      onDone();
    } catch (error) {
      setPathError(error instanceof Error ? error.message : "自动发现 Codex 目录失败。");
    } finally {
      setSavingPath(false);
    }
  }

  return (
    <div className="codex-home-editor">
      <input
        aria-label="Codex 目录"
        disabled={savingPath}
        onChange={(event) => setPathDraft(event.target.value)}
        onKeyDown={(event) => {
          if (event.key === "Enter") {
            void savePath();
          }
        }}
        value={pathDraft}
      />
      <button disabled={savingPath || pathDraft.trim().length === 0} onClick={savePath} type="button">
        保存目录
      </button>
      <button disabled={savingPath} onClick={resetPath} type="button">
        恢复自动
      </button>
      {pathError ? <span className="setup-error">{pathError}</span> : null}
    </div>
  );
}
