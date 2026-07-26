import type { CommandFailureDiagnostic } from "../api/client";

// 设置读写失败由 settingsError 通道给出带后果说明的横幅文案，
// 通用诊断列表里排除这两条命令避免同一失败重复展示。
export const SETTINGS_OWNED_COMMANDS = new Set([
  "read_app_settings",
  "save_floating_settings",
]);

export const MAX_VISIBLE_NOTICE_LINES = 3;

export interface LocalCommandNoticeLine {
  key: string;
  text: string;
}

export function buildLocalCommandNoticeLines(
  settingsError: string | null,
  diagnostics: CommandFailureDiagnostic[],
): LocalCommandNoticeLine[] {
  const lines: LocalCommandNoticeLine[] = [];
  if (settingsError !== null && settingsError.trim() !== "") {
    lines.push({ key: "settings", text: settingsError });
  }
  const commandLines = diagnostics
    .filter((diagnostic) => !SETTINGS_OWNED_COMMANDS.has(diagnostic.command))
    .map((diagnostic) => ({
      key: `command:${diagnostic.command}`,
      text: diagnostic.count > 1
        ? `本地操作 ${diagnostic.command} 失败 ×${diagnostic.count}：${diagnostic.message}`
        : `本地操作 ${diagnostic.command} 失败：${diagnostic.message}`,
    }));
  const remainingSlots = Math.max(0, MAX_VISIBLE_NOTICE_LINES - lines.length);
  if (commandLines.length > remainingSlots) {
    const hidden = commandLines.length - Math.max(0, remainingSlots - 1);
    lines.push(...commandLines.slice(0, Math.max(0, remainingSlots - 1)));
    lines.push({
      key: "overflow",
      text: `另有 ${hidden} 项本地操作失败（详见开发者控制台）`,
    });
  } else {
    lines.push(...commandLines);
  }
  return lines;
}
