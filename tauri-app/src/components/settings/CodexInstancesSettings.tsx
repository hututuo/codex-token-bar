import { useCallback, useEffect, useMemo, useState } from "react";
import {
  createCodexInstance,
  deleteCodexInstance,
  focusCodexInstance,
  importCodexInstance,
  launchCodexInstance,
  listCodexInstanceRuntimeStatuses,
  listCodexInstances,
  listCodexInstanceSyncTransactions,
  previewCodexInstanceSync,
  rollbackCodexInstanceSync,
  stopCodexInstance,
  syncCodexInstances,
  updateCodexInstance,
} from "../../api/codexInstancesClient";
import type {
  CodexInstance,
  CodexInstanceCreateMode,
  CodexInstanceRegistrySnapshot,
  CodexInstanceRuntimeStatus,
  CodexInstanceSyncPreview,
  CodexInstanceSyncTransactionSummary,
} from "../../types/codexInstances";

type AddMode = "empty" | "copyConfiguration" | "existing";

interface InstanceDraft {
  name: string;
  sourceHome: string;
  copyAuth: boolean;
  codexHome: string;
  workingDirectory: string;
  argumentsText: string;
  autoSyncEnabled: boolean;
}

const EMPTY_DRAFT: InstanceDraft = {
  name: "",
  sourceHome: "",
  copyAuth: false,
  codexHome: "",
  workingDirectory: "",
  argumentsText: "",
  autoSyncEnabled: false,
};

export function CodexInstancesSettings() {
  const [snapshot, setSnapshot] = useState<CodexInstanceRegistrySnapshot | null>(null);
  const [statuses, setStatuses] = useState<Record<string, CodexInstanceRuntimeStatus>>({});
  const [transactions, setTransactions] = useState<CodexInstanceSyncTransactionSummary[]>([]);
  const [selectedIds, setSelectedIds] = useState<string[]>([]);
  const [preview, setPreview] = useState<CodexInstanceSyncPreview | null>(null);
  const [addMode, setAddMode] = useState<AddMode>("empty");
  const [draft, setDraft] = useState<InstanceDraft>(EMPTY_DRAFT);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [editDraft, setEditDraft] = useState<InstanceDraft>(EMPTY_DRAFT);
  const [busy, setBusy] = useState<string | null>("loading");
  const [error, setError] = useState<string | null>(null);
  const [message, setMessage] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    setError(null);
    const [nextSnapshot, nextTransactions] = await Promise.all([
      listCodexInstances(),
      listCodexInstanceSyncTransactions(),
    ]);
    setSnapshot(nextSnapshot);
    setTransactions(nextTransactions);
    setSelectedIds((current) => current.filter((id) => nextSnapshot.instances.some((item) => item.id === id)));
    const nextStatuses = await listCodexInstanceRuntimeStatuses();
    setStatuses(Object.fromEntries(nextStatuses.map((status) => [status.id, status])));
  }, []);

  useEffect(() => {
    let active = true;
    void (async () => {
      try {
        await refresh();
      } catch (loadError) {
        if (active) setError(`读取实例失败：${errorMessage(loadError)}`);
      } finally {
        if (active) setBusy(null);
      }
    })();
    return () => {
      active = false;
    };
  }, [refresh]);

  const selectedInstances = useMemo(
    () => snapshot?.instances.filter((instance) => selectedIds.includes(instance.id)) ?? [],
    [selectedIds, snapshot],
  );

  async function perform(label: string, action: () => Promise<{ message: string }>) {
    setBusy(label);
    setError(null);
    setMessage(null);
    try {
      const result = await action();
      setMessage(result.message);
      setPreview(null);
      try {
        await refresh();
      } catch (refreshError) {
        setError(`操作已经完成，但重新读取状态失败：${errorMessage(refreshError)}`);
      }
      return true;
    } catch (actionError) {
      setError(errorMessage(actionError));
      return false;
    } finally {
      setBusy(null);
    }
  }

  async function submitAdd() {
    const argumentsList = parseArguments(draft.argumentsText);
    if (addMode === "existing") {
      const succeeded = await perform("import", () => importCodexInstance({
        name: draft.name,
        codexHome: draft.codexHome,
        workingDirectory: nullableText(draft.workingDirectory),
        arguments: argumentsList,
        autoSyncEnabled: draft.autoSyncEnabled,
      }));
      if (succeeded) setDraft(EMPTY_DRAFT);
    } else {
      const succeeded = await perform("create", () => createCodexInstance({
        name: draft.name,
        mode: addMode as CodexInstanceCreateMode,
        sourceHome: nullableText(draft.sourceHome),
        copyAuth: draft.copyAuth,
        workingDirectory: nullableText(draft.workingDirectory),
        arguments: argumentsList,
        autoSyncEnabled: draft.autoSyncEnabled,
      }));
      if (succeeded) setDraft(EMPTY_DRAFT);
    }
  }

  function beginEdit(instance: CodexInstance) {
    setEditingId(instance.id);
    setEditDraft({
      name: instance.name,
      sourceHome: "",
      copyAuth: false,
      codexHome: instance.codexHome,
      workingDirectory: instance.workingDirectory ?? "",
      argumentsText: instance.arguments.join("\n"),
      autoSyncEnabled: instance.autoSyncEnabled,
    });
  }

  async function saveEdit() {
    if (!editingId) return;
    const succeeded = await perform("edit", () => updateCodexInstance({
      id: editingId,
      name: editDraft.name,
      workingDirectory: nullableText(editDraft.workingDirectory),
      arguments: parseArguments(editDraft.argumentsText),
      autoSyncEnabled: editDraft.autoSyncEnabled,
    }));
    if (succeeded) setEditingId(null);
  }

  async function buildPreview() {
    setBusy("preview");
    setError(null);
    setMessage(null);
    try {
      const result = await previewCodexInstanceSync(selectedIds);
      setPreview(result);
      setMessage(
        `预览完成：${result.operations.length} 项可安全同步，${result.conflicts.length} 个分歧将保留。`,
      );
    } catch (previewError) {
      setPreview(null);
      setError(errorMessage(previewError));
    } finally {
      setBusy(null);
    }
  }

  async function executeSync() {
    await perform("sync", () => syncCodexInstances(selectedIds));
  }

  if (!snapshot && busy === "loading") {
    return <div className="codex-instances-loading">正在读取 Codex 实例…</div>;
  }

  return (
    <div className="codex-instances-settings">
      {error ? <div className="codex-instances-banner is-error" role="alert">{error}</div> : null}
      {message ? <div className="codex-instances-banner" role="status">{message}</div> : null}

      <section className="app-settings-group">
        <header>
          <strong>实例列表</strong>
          <span>每个实例拥有独立 Codex Home 与桌面数据目录；默认实例只读，Token Bar 不会停止它。</span>
        </header>
        <div className="codex-instance-list">
          {snapshot?.instances.map((instance) => {
            const status = statuses[instance.id];
            const selected = selectedIds.includes(instance.id);
            const isEditing = editingId === instance.id;
            const stopped = status?.running === false;
            const statusLabel = status ? (status.running ? "运行中" : "已停止") : "状态未知";
            const invalidatedRollbackCount = transactions.filter(
              (transaction) => transaction.state === "committed"
                && transaction.instanceIds.includes(instance.id),
            ).length;
            return (
              <div className="codex-instance-card" key={instance.id}>
                <div className="codex-instance-card-main">
                  <label className="codex-instance-select">
                    <input
                      checked={selected}
                      onChange={(event) => {
                        setSelectedIds((current) => event.currentTarget.checked
                          ? [...current, instance.id]
                          : current.filter((id) => id !== instance.id));
                        setPreview(null);
                      }}
                      type="checkbox"
                    />
                    <span>
                      <strong>{instance.name}</strong>
                      <em>{instance.isDefault ? "系统默认" : instance.managed ? "Token Bar 托管" : "外部目录"}</em>
                    </span>
                  </label>
                  <div className={`codex-instance-status ${status?.running ? "is-running" : ""} ${status ? "" : "is-unknown"}`}>
                    <i />
                    <span>{statusLabel}</span>
                  </div>
                  <div className="codex-instance-actions">
                    {!instance.isDefault && stopped ? (
                      <button
                        className="app-settings-action is-primary"
                        disabled={busy !== null}
                        onClick={() => void perform("launch", () => launchCodexInstance(instance.id))}
                        type="button"
                      >
                        启动
                      </button>
                    ) : null}
                    {status?.running && status.controlled ? (
                      <>
                        <button
                          className="app-settings-action"
                          disabled={busy !== null}
                          onClick={() => void perform("focus", () => focusCodexInstance(instance.id))}
                          type="button"
                        >
                          切换
                        </button>
                        <button
                          className="app-settings-action"
                          disabled={busy !== null}
                          onClick={() => void perform("stop", () => stopCodexInstance(instance.id))}
                          type="button"
                        >
                          停止
                        </button>
                      </>
                    ) : null}
                    {!instance.isDefault ? (
                      <button
                        className="app-settings-action"
                        disabled={busy !== null || !stopped}
                        onClick={() => beginEdit(instance)}
                        type="button"
                      >
                        编辑
                      </button>
                    ) : null}
                    {!instance.isDefault ? (
                      <button
                        className="app-settings-action is-danger"
                        disabled={busy !== null || !stopped}
                        onClick={() => {
                          const rollbackWarning = invalidatedRollbackCount > 0
                            ? ` 此操作会使 ${invalidatedRollbackCount} 个历史同步事务无法再完整回滚。`
                            : "";
                          if (window.confirm(`确定移除“${instance.name}”吗？${instance.managed ? "托管目录会一起删除。" : "原 Codex Home 不会删除。"}${rollbackWarning}`)) {
                            void perform("delete", () => deleteCodexInstance(instance.id));
                          }
                        }}
                        type="button"
                      >
                        {instance.managed ? "删除" : "取消登记"}
                      </button>
                    ) : null}
                  </div>
                </div>
                <div className="codex-instance-details">
                  <span title={instance.codexHome}>Home · {instance.codexHome}</span>
                  {instance.electronDataDirectory ? (
                    <span title={instance.electronDataDirectory}>桌面数据 · {instance.electronDataDirectory}</span>
                  ) : null}
                  <span>{status?.message ?? "正在检查运行状态…"}</span>
                  {instance.autoSyncEnabled ? <b>与默认实例在全部停止后自动同步</b> : null}
                </div>
                {isEditing ? (
                  <InstanceEditForm
                    busy={busy !== null}
                    draft={editDraft}
                    onCancel={() => setEditingId(null)}
                    onChange={setEditDraft}
                    onSave={() => void saveEdit()}
                  />
                ) : null}
              </div>
            );
          })}
          {snapshot?.instances.length === 1 ? (
            <div className="app-settings-note">还没有额外实例。可以从空目录创建、复制配置，或登记已有 Codex Home。</div>
          ) : null}
        </div>
      </section>

      <section className="app-settings-group">
        <header>
          <strong>添加实例</strong>
          <span>复制模式只复制配置、技能与可选登录文件，不复制正在变化的会话数据库。</span>
        </header>
        <div>
          <div className="codex-instance-mode" role="tablist" aria-label="实例来源">
            {([
              ["empty", "空白实例"],
              ["copyConfiguration", "复制配置"],
              ["existing", "已有目录"],
            ] as const).map(([mode, label]) => (
              <button
                aria-selected={addMode === mode}
                className={addMode === mode ? "is-active" : ""}
                key={mode}
                onClick={() => setAddMode(mode)}
                role="tab"
                type="button"
              >
                {label}
              </button>
            ))}
          </div>
          <InstanceFields
            addMode={addMode}
            draft={draft}
            onChange={setDraft}
            showSource
          />
          <div className="app-settings-group-footer">
            <button
              className="app-settings-action is-primary"
              disabled={busy !== null || !draft.name.trim() || (addMode === "existing" && !draft.codexHome.trim())}
              onClick={() => void submitAdd()}
              type="button"
            >
              {addMode === "existing" ? "登记实例" : "创建实例"}
            </button>
          </div>
        </div>
      </section>

      <section className="app-settings-group">
        <header>
          <strong>会话同步</strong>
          <span>只自动复制缺失会话或严格前缀的较新版本；分叉会话保持原样，不会逐行拼接。</span>
        </header>
        <div>
          <div className="codex-instance-sync-summary">
            <span>已选择 <strong>{selectedInstances.length}</strong> 个实例</span>
            <span>同步前后均会重新检查所有实例已经停止</span>
            <div>
              <button
                className="app-settings-action"
                disabled={busy !== null || selectedInstances.length < 2}
                onClick={() => void buildPreview()}
                type="button"
              >
                预览
              </button>
              <button
                className="app-settings-action is-primary"
                disabled={busy !== null || !preview || !sameStringSet(preview.instanceIds, selectedIds)}
                onClick={() => void executeSync()}
                type="button"
              >
                执行同步
              </button>
            </div>
          </div>
          {preview ? (
            <div className="codex-instance-preview">
              <span><strong>{preview.operations.length}</strong> 项安全写入</span>
              <span><strong>{preview.conflicts.length}</strong> 个分歧保留</span>
              <span><strong>{preview.unchangedThreads}</strong> 个会话已一致</span>
            </div>
          ) : null}
          {snapshot?.conflicts.length ? (
            <div className="codex-instance-conflicts">
              <strong>尚未处理的分歧</strong>
              {snapshot.conflicts.slice(0, 6).map((conflict) => (
                <div key={conflict.id}>
                  <span>{shortId(conflict.threadId)}</span>
                  <em>{conflict.reason}</em>
                </div>
              ))}
            </div>
          ) : null}
        </div>
      </section>

      <section className="app-settings-group">
        <header>
          <strong>同步回滚</strong>
          <span>每次写入都有事务清单和校验备份；仅当文件仍是本次写入值时才允许回滚。</span>
        </header>
        <div className="codex-instance-transactions">
          {transactions.slice(0, 6).map((transaction) => (
            <div key={transaction.transactionId}>
              <span>
                <strong>{formatTime(transaction.createdAt)}</strong>
                <em>{transaction.operations} 项写入 · {transaction.conflicts} 个分歧 · {transaction.state}</em>
              </span>
              <button
                className="app-settings-action"
                disabled={busy !== null || !["committed", "prepared", "failedNeedsRecovery"].includes(transaction.state)}
                onClick={() => {
                  if (window.confirm(`回滚 ${formatTime(transaction.createdAt)} 的同步事务吗？只会恢复仍与本次写入值一致的文件。`)) {
                    void perform(
                      "rollback",
                      () => rollbackCodexInstanceSync(transaction.transactionId),
                    );
                  }
                }}
                type="button"
              >
                回滚
              </button>
            </div>
          ))}
          {transactions.length === 0 ? <div className="app-settings-note">还没有实例同步事务。</div> : null}
        </div>
      </section>

      <p className="codex-instances-registry-path" title={snapshot?.registryPath}>
        共享注册表 · {snapshot?.registryPath}
      </p>
      <p className="codex-instances-registry-path">
        产品行为参考 Cockpit Tools；因其 CC BY-NC-SA 非商业许可，本功能为独立实现，未复制其源码。
      </p>
    </div>
  );
}

function InstanceEditForm({
  busy,
  draft,
  onCancel,
  onChange,
  onSave,
}: {
  busy: boolean;
  draft: InstanceDraft;
  onCancel: () => void;
  onChange: (draft: InstanceDraft) => void;
  onSave: () => void;
}) {
  return (
    <div className="codex-instance-edit">
      <InstanceFields draft={draft} onChange={onChange} />
      <div className="app-settings-group-footer">
        <button className="app-settings-action" disabled={busy} onClick={onCancel} type="button">取消</button>
        <button className="app-settings-action is-primary" disabled={busy || !draft.name.trim()} onClick={onSave} type="button">保存</button>
      </div>
    </div>
  );
}

function InstanceFields({
  addMode,
  draft,
  onChange,
  showSource = false,
}: {
  addMode?: AddMode;
  draft: InstanceDraft;
  onChange: (draft: InstanceDraft) => void;
  showSource?: boolean;
}) {
  return (
    <div className="codex-instance-fields">
      <label>
        <span>实例名称</span>
        <input
          onChange={(event) => onChange({ ...draft, name: event.currentTarget.value })}
          placeholder="例如：工作账号"
          value={draft.name}
        />
      </label>
      {showSource && addMode === "copyConfiguration" ? (
        <>
          <label>
            <span>源 Codex Home</span>
            <input
              onChange={(event) => onChange({ ...draft, sourceHome: event.currentTarget.value })}
              placeholder="留空使用当前默认目录"
              value={draft.sourceHome}
            />
          </label>
          <label className="codex-instance-checkbox">
            <input
              checked={draft.copyAuth}
              onChange={(event) => onChange({ ...draft, copyAuth: event.currentTarget.checked })}
              type="checkbox"
            />
            <span>同时复制 auth.json（会把登录凭据带入新实例）</span>
          </label>
        </>
      ) : null}
      {showSource && addMode === "existing" ? (
        <label>
          <span>已有 Codex Home</span>
          <input
            onChange={(event) => onChange({ ...draft, codexHome: event.currentTarget.value })}
            placeholder="/Users/you/.codex-work"
            value={draft.codexHome}
          />
        </label>
      ) : null}
      <label>
        <span>工作目录</span>
        <input
          onChange={(event) => onChange({ ...draft, workingDirectory: event.currentTarget.value })}
          placeholder="可选；作为启动环境传给 Codex"
          value={draft.workingDirectory}
        />
      </label>
      <label>
        <span>额外参数</span>
        <textarea
          onChange={(event) => onChange({ ...draft, argumentsText: event.currentTarget.value })}
          placeholder="每行一个参数，不经过 shell"
          rows={2}
          value={draft.argumentsText}
        />
      </label>
      <label className="codex-instance-checkbox">
        <input
          checked={draft.autoSyncEnabled}
          onChange={(event) => onChange({ ...draft, autoSyncEnabled: event.currentTarget.checked })}
          type="checkbox"
        />
        <span>与默认实例及其他已开启实例在全部停止后自动安全同步</span>
      </label>
    </div>
  );
}

function parseArguments(value: string) {
  return value
    .split(/\r?\n/)
    .map((item) => item.trim())
    .filter(Boolean);
}

function nullableText(value: string) {
  const trimmed = value.trim();
  return trimmed ? trimmed : null;
}

function sameStringSet(left: string[], right: string[]) {
  if (left.length !== right.length) return false;
  const sortedLeft = [...left].sort();
  const sortedRight = [...right].sort();
  return sortedLeft.every((value, index) => value === sortedRight[index]);
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

function shortId(value: string) {
  return value.length > 18 ? `${value.slice(0, 8)}…${value.slice(-6)}` : value;
}

function formatTime(timestamp: number) {
  return new Intl.DateTimeFormat("zh-CN", {
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  }).format(new Date(timestamp));
}
