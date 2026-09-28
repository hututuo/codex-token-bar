import { useState } from "react";
import { invokePlatformCommandResult } from "../platform/desktopBridge";
import type { CodexHomeSourceToken } from "../types/dashboard";
import { changeQuotaAccount, useQuotaAccounts } from "../quotaAccounts";

export function QuotaAccountSelector({ compact = false }: { compact?: boolean }) {
  const { accounts, error: readError } = useQuotaAccounts();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [path, setPath] = useState("");
  async function run(action: () => Promise<void>) {
    setBusy(true); setError("");
    try { await action(); } catch (cause) { setError(cause instanceof Error ? cause.message : "账号更新失败"); }
    finally { setBusy(false); }
  }
  async function saveCurrent() {
    const source = await invokePlatformCommandResult<CodexHomeSourceToken | null>("get_codex_home", null, undefined, 10_000);
    if (!source.ok || !source.value) throw new Error("无法确认当前 Codex 数据源，请重新打开主界面");
    await changeQuotaAccount("save_current_quota_account", { sourceToken: source.value });
  }
  return <div className={"quota-account-selector" + (compact ? " quota-account-compact" : "")}>
    <label>
      <span>{compact ? "额度账号" : "额度账号 · 官方直连"}</span>
      <select aria-label="切换额度账号" title="只切换额度，本地 token 统计不变" disabled={busy || !!readError}
        value={accounts.selectedId ?? ""} onChange={event => void run(() => changeQuotaAccount("select_quota_account", { id: event.target.value || null }))}>
        <option value="">跟随当前登录</option>
        {accounts.accounts.map(account => <option key={account.id} value={account.id}>{account.label} · {account.id.slice(0, 6)}</option>)}
      </select>
    </label>
    {!compact && <details className="quota-account-manage">
      <summary>管理账号</summary>
      <div className="quota-account-popover">
        <p>只读取所选账号的额度。本地 token 始终统计本机全部用量，不归属于所选账号。</p>
        <button type="button" disabled={busy} onClick={() => void run(saveCurrent)}>添加 / 更新当前登录账号</button>
        <label>导入 Codex / CPA 登录 JSON 文件
          <input aria-label="登录文件完整路径" type="text" value={path} placeholder="登录文件的完整路径" onChange={e => setPath(e.target.value)} />
        </label>
        <button type="button" disabled={busy || !path.trim()} onClick={() => void run(async () => {
          await changeQuotaAccount("import_quota_account", { path: path.trim() }); setPath("");
        })}>导入账号</button>
        {accounts.selectedId && <button type="button" disabled={busy} onClick={() => void run(() => changeQuotaAccount("remove_quota_account", { id: accounts.selectedId }))}>移除所选账号</button>}
        <small>凭据保存在系统安全存储中。登录过期时，请在原客户端重新登录，再更新账号；普通 API Key 不适用。</small>
      </div>
    </details>}
    {(error || readError) && <span role="alert" className="quota-account-error">{error || readError}</span>}
  </div>;
}
