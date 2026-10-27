import { useSyncExternalStore } from "react";
import { ACTIVITY_RATE_UNIT_KEY, ACTIVITY_RATE_FX_KEY, DEFAULT_ACTIVITY_RATE_FX, safeActivityRateFX, type ActivityRateUnit } from "./activityRatePresentation";
const changed = "activity-rate-preferences-changed";
const serverSnapshot = () => `tok/s|${DEFAULT_ACTIVITY_RATE_FX}`;
function read() {
  try {
    const unit = window.localStorage.getItem(ACTIVITY_RATE_UNIT_KEY) === "CN 元/s" ? "CN 元/s" : "tok/s";
    const stored = window.localStorage.getItem(ACTIVITY_RATE_FX_KEY);
    return `${unit}|${safeActivityRateFX(stored === null ? DEFAULT_ACTIVITY_RATE_FX : Number(stored))}`;
  } catch { return serverSnapshot(); }
}
function subscribe(notify: () => void) {
  window.addEventListener("storage", notify); window.addEventListener(changed, notify);
  return () => { window.removeEventListener("storage", notify); window.removeEventListener(changed, notify); };
}
function write(key: string, value: string) {
  try { window.localStorage.setItem(key, value); window.dispatchEvent(new window.Event(changed)); } catch { /* Existing settings remain usable if storage is blocked. */ }
}
export function useActivityRatePreferences() {
  const snapshot = useSyncExternalStore(subscribe, read, serverSnapshot);
  const [unit, rawFX] = snapshot.split("|");
  return { unit: unit as ActivityRateUnit, fx: Number(rawFX),
    setUnit: (value: ActivityRateUnit) => write(ACTIVITY_RATE_UNIT_KEY, value),
    setFX: (value: number) => write(ACTIVITY_RATE_FX_KEY, String(safeActivityRateFX(value))) };
}
export function ActivityRateUnitControl() {
  const settings = useActivityRatePreferences();
  return <div className="activity-rate-units"><select aria-label="速率单位" value={settings.unit} onChange={e => settings.setUnit(e.target.value as ActivityRateUnit)}>
    <option>tok/s</option><option>CN 元/s</option>
  </select>{settings.unit === "CN 元/s" && <label title="手动换算参数，不是实时汇率">1 USD=<input key={settings.fx} aria-label="人民币换算汇率" type="number" min="0.1" max="100" step="0.01" defaultValue={settings.fx} onBlur={e => settings.setFX(Number(e.target.value))}/>元</label>}</div>;
}
