import type { LocalDataWarning } from "../../types/dashboard";

const QUOTA_WARNING_SOURCES = new Set(["account_quota", "reset_credit"]);

export function quotaReadWarnings(warnings: LocalDataWarning[]): string[] {
  return warnings
    .filter((warning) => QUOTA_WARNING_SOURCES.has(warning.source))
    .map((warning) => warning.message)
    .filter((message, index, messages) => message.length > 0 && messages.indexOf(message) === index)
    .slice(0, 2);
}
