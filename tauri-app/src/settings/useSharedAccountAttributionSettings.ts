import { useCallback, useEffect, useState } from "react";
import {
  readSharedAccountAttributionSettings,
  SHARED_ACCOUNT_ATTRIBUTION_ENABLED_STORAGE_KEY,
  SHARED_ACCOUNT_ATTRIBUTION_SETTINGS_EVENT,
  SHARED_ACCOUNT_ATTRIBUTION_TIER_STORAGE_KEY,
  type SharedAccountAttributionSettings,
  writeSharedAccountAttributionSettings,
} from "./sharedAccountAttribution";
import {
  normalizeOfficialAPIPriceModel,
  QUOTA_PRICE_MODEL_EVENT,
  QUOTA_PRICE_MODEL_STORAGE_KEY,
} from "./quotaPriceModel";

export interface SharedAccountAttributionSettingsController {
  settings: SharedAccountAttributionSettings;
  updateSettings: (patch: Partial<SharedAccountAttributionSettings>) => void;
}

export function useSharedAccountAttributionSettings(): SharedAccountAttributionSettingsController {
  const [settings, setSettings] = useState<SharedAccountAttributionSettings>(
    () => readSharedAccountAttributionSettings(),
  );

  useEffect(() => {
    const refresh = () => setSettings(readSharedAccountAttributionSettings());
    const onStorage = (event: StorageEvent) => {
      if (event.key === SHARED_ACCOUNT_ATTRIBUTION_ENABLED_STORAGE_KEY
        || event.key === SHARED_ACCOUNT_ATTRIBUTION_TIER_STORAGE_KEY
        || event.key === QUOTA_PRICE_MODEL_STORAGE_KEY) {
        refresh();
      }
    };
    const onPriceModel = (event: Event) => {
      const priceModel = normalizeOfficialAPIPriceModel((event as CustomEvent<unknown>).detail);
      if (priceModel) setSettings((current) => ({ ...current, priceModel }));
    };
    window.addEventListener("storage", onStorage);
    window.addEventListener(SHARED_ACCOUNT_ATTRIBUTION_SETTINGS_EVENT, refresh);
    window.addEventListener(QUOTA_PRICE_MODEL_EVENT, onPriceModel);
    return () => {
      window.removeEventListener("storage", onStorage);
      window.removeEventListener(SHARED_ACCOUNT_ATTRIBUTION_SETTINGS_EVENT, refresh);
      window.removeEventListener(QUOTA_PRICE_MODEL_EVENT, onPriceModel);
    };
  }, []);

  const updateSettings = useCallback((patch: Partial<SharedAccountAttributionSettings>) => {
    const next = { ...readSharedAccountAttributionSettings(), ...patch };
    setSettings(next);
    writeSharedAccountAttributionSettings(next);
  }, []);

  return { settings, updateSettings };
}
