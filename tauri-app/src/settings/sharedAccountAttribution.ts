import type { OfficialAPIPriceModel } from "./quotaPriceModel";
import {
  normalizeOfficialAPIPriceModel,
  QUOTA_PRICE_MODEL_EVENT,
  QUOTA_PRICE_MODEL_STORAGE_KEY,
  readStoredQuotaPriceModel,
} from "./quotaPriceModel";

export type SharedAccountRadarTier = "pro20x" | "pro5x" | "plus";

export interface SharedAccountAttributionSettings {
  enabled: boolean;
  radarTier: SharedAccountRadarTier;
  priceModel: OfficialAPIPriceModel;
}

export const SHARED_ACCOUNT_ATTRIBUTION_ENABLED_STORAGE_KEY = "sharedAccountAttributionEnabled";
export const SHARED_ACCOUNT_ATTRIBUTION_TIER_STORAGE_KEY = "sharedAccountAttributionRadarTier";
export const SHARED_ACCOUNT_ATTRIBUTION_SETTINGS_EVENT = "codex-token-bar:shared-account-attribution-settings";

export const SHARED_ACCOUNT_RADAR_TIER_OPTIONS: ReadonlyArray<{
  value: SharedAccountRadarTier;
  label: string;
}> = [
  { value: "pro20x", label: "20x Pro" },
  { value: "pro5x", label: "5x Pro" },
  { value: "plus", label: "Plus" },
];

export const DEFAULT_SHARED_ACCOUNT_ATTRIBUTION_SETTINGS: SharedAccountAttributionSettings = {
  enabled: true,
  radarTier: "pro20x",
  priceModel: "gpt56Sol",
};

export function normalizeSharedAccountRadarTier(value: unknown): SharedAccountRadarTier | null {
  return value === "pro20x" || value === "pro5x" || value === "plus" ? value : null;
}

export function readSharedAccountAttributionSettings(
  storage?: Pick<Storage, "getItem" | "setItem"> | null,
): SharedAccountAttributionSettings {
  const target = storage ?? (typeof window === "undefined" ? null : window.localStorage);
  if (!target) return DEFAULT_SHARED_ACCOUNT_ATTRIBUTION_SETTINGS;
  return {
    enabled: target.getItem(SHARED_ACCOUNT_ATTRIBUTION_ENABLED_STORAGE_KEY) !== "false",
    radarTier: normalizeSharedAccountRadarTier(
      target.getItem(SHARED_ACCOUNT_ATTRIBUTION_TIER_STORAGE_KEY),
    ) ?? DEFAULT_SHARED_ACCOUNT_ATTRIBUTION_SETTINGS.radarTier,
    priceModel: readStoredQuotaPriceModel(target),
  };
}

export function writeSharedAccountAttributionSettings(
  settings: SharedAccountAttributionSettings,
): void {
  if (typeof window === "undefined") return;
  const previousPriceModel = normalizeOfficialAPIPriceModel(
    window.localStorage.getItem(QUOTA_PRICE_MODEL_STORAGE_KEY),
  );
  window.localStorage.setItem(
    SHARED_ACCOUNT_ATTRIBUTION_ENABLED_STORAGE_KEY,
    settings.enabled ? "true" : "false",
  );
  window.localStorage.setItem(SHARED_ACCOUNT_ATTRIBUTION_TIER_STORAGE_KEY, settings.radarTier);
  window.localStorage.setItem(QUOTA_PRICE_MODEL_STORAGE_KEY, settings.priceModel);
  window.dispatchEvent(new CustomEvent(SHARED_ACCOUNT_ATTRIBUTION_SETTINGS_EVENT, { detail: settings }));
  if (previousPriceModel !== settings.priceModel) {
    window.dispatchEvent(new CustomEvent(QUOTA_PRICE_MODEL_EVENT, { detail: settings.priceModel }));
  }
}
