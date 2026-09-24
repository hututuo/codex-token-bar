import { useEffect, useRef, useState } from "react";
import { readAppSettings, saveQuotaHistoryFilter } from "../../api/settingsClient";
import { desktopPlatform } from "../../platform/desktop";

export function QuotaHistoryFilterSetting() {
  const [enabled, setEnabled] = useState(true);
  const [ready, setReady] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const savingRef = useRef(false);

  useEffect(() => {
    let active = true;
    void readAppSettings().then((settings) => {
      if (!active) return;
      setEnabled(settings?.filterQuotaHistoryAnomalies !== false);
      setReady(true);
    }).catch(() => {
      if (active) setError("读取异常点过滤设置失败，请重新打开设置后重试。");
    });
    return () => { active = false; };
  }, []);

  async function save(next: boolean) {
    if (!ready || savingRef.current) return;
    savingRef.current = true;
    setSaving(true);
    setError(null);
    try {
      const settings = await saveQuotaHistoryFilter(next);
      setEnabled(settings.filterQuotaHistoryAnomalies !== false);
      // Publish only after durable save; mounted history readers then reload.
      if (!await desktopPlatform.publishAppSettings(settings)) {
        setError("设置已保存，但历史视图同步失败，请重新打开主窗口。");
      }
    } catch {
      setError("保存或同步过滤设置失败，请重新打开设置核对后重试。");
    } finally {
      savingRef.current = false;
      setSaving(false);
    }
  }

  return (
    <div>
      <div className="app-setting-row">
        <span>
          <strong>过滤异常点</strong>
          <em>默认开启。过滤额度历史中的异常跳变；关闭后显示原始记录。不会删除数据或改变实时额度。</em>
        </span>
        <button
          aria-label={`过滤异常点：${enabled ? "开" : "关"}`}
          aria-checked={enabled}
          className={enabled ? "app-settings-toggle is-active" : "app-settings-toggle"}
          disabled={!ready || saving}
          onClick={() => void save(!enabled)}
          role="switch"
          type="button"
        >
          <span aria-hidden="true"><i /></span>
          <strong>{enabled ? "开" : "关"}</strong>
        </button>
      </div>
      {error ? <p role="alert" className="app-settings-note">{error}</p> : null}
    </div>
  );
}
