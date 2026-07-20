import type { SessionEnhancementSettings } from "../types/settings";

export const DEFAULT_SESSION_ENHANCEMENTS: SessionEnhancementSettings = {
  sessionDelete: true,
  markdownExport: true,
  pasteFix: false,
  projectMove: true,
  threadIDBadge: false,
  conversationView: false,
  conversationViewMaxWidth: 900,
  threadScrollRestore: true,
};

export function sanitizeSessionEnhancements(
  value: Partial<SessionEnhancementSettings> | null | undefined,
): SessionEnhancementSettings {
  const width = Number(value?.conversationViewMaxWidth);
  return {
    sessionDelete: value?.sessionDelete !== false,
    markdownExport: value?.markdownExport !== false,
    pasteFix: value?.pasteFix === true,
    projectMove: value?.projectMove !== false,
    threadIDBadge: value?.threadIDBadge === true,
    conversationView: value?.conversationView === true,
    conversationViewMaxWidth: Math.max(320, Math.min(4_000, Number.isFinite(width) ? Math.round(width) : 900)),
    threadScrollRestore: value?.threadScrollRestore !== false,
  };
}
