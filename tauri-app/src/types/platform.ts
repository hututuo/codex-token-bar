export interface CodexHomeStatus {
  path: string;
  exists: boolean;
  source: string;
}

export interface CodexHomeSourceEnvelope {
  codexHome: CodexHomeStatus;
  canonicalHomeKey: string;
  physicalHomeKey: string;
  transitionGeneration: number;
}

export interface CodexHomeSourceToken {
  canonicalHomeKey: string;
  physicalHomeKey: string;
  transitionGeneration: number;
}

export interface PlatformCapabilities {
  platform: string;
  shell: string;
  floatingWindow: PlatformFeatureCapability;
  floatingTransparency: PlatformFeatureCapability;
  floatingDrag: PlatformFeatureCapability;
  floatingLock: PlatformFeatureCapability;
  statusTray: PlatformFeatureCapability;
  statusTrayLiveText: PlatformFeatureCapability;
  autostart: PlatformFeatureCapability;
  notifications: PlatformFeatureCapability;
}

export interface PlatformFeatureCapability {
  available: boolean;
  status: "ready" | "pending" | "unavailable" | string;
  label: string;
  note: string;
}

export interface AutostartStatus {
  available: boolean;
  enabled: boolean;
  status: "enabled" | "disabled" | "unavailable" | string;
  message: string;
}
