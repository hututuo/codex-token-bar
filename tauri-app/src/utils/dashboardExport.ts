import type { DashboardSnapshot } from "../types/dashboard";

type ExportableActivityDay = Pick<DashboardSnapshot["activityDays"][number], "calls" | "date" | "tokens">;

export function dashboardToCsv(snapshot: { activityDays: ExportableActivityDay[] }): string {
  const lines = ["date,tokens,calls"];
  snapshot.activityDays.forEach((day) => {
    lines.push(`${csvCell(day.date)},${Math.round(day.tokens)},${Math.round(day.calls)}`);
  });
  return lines.join("\n");
}

export function downloadDashboardCsv(snapshot: DashboardSnapshot): void {
  downloadTextFile("codex-token-usage.csv", "text/csv;charset=utf-8", dashboardToCsv(snapshot));
}

function downloadTextFile(filename: string, mimeType: string, content: string): void {
  const blob = new Blob([content], { type: mimeType });
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = filename;
  anchor.style.display = "none";
  document.body.append(anchor);
  anchor.click();
  anchor.remove();
  URL.revokeObjectURL(url);
}

function csvCell(value: string): string {
  if (!/[",\n\r]/.test(value)) {
    return value;
  }
  return `"${value.replaceAll("\"", "\"\"")}"`;
}
