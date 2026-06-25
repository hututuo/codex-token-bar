import type { DashboardSnapshot } from "../types/dashboard";

type ExportableActivityDay = Pick<DashboardSnapshot["activityDays"][number], "calls" | "date" | "tokens">;
type ExportableDashboardSnapshot = {
  activityDays: ExportableActivityDay[];
  generatedAt: string;
  stats: Pick<
    DashboardSnapshot["stats"],
    "currentStreakDays" | "longestStreakDays" | "peakDayTokens" | "peakThreadTokens" | "totalCalls" | "totalThreads" | "totalTokens"
  >;
};

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

export async function downloadDashboardPng(snapshot: DashboardSnapshot): Promise<void> {
  const svg = dashboardToExportSvg(snapshot);
  const svgBlob = new Blob([svg], { type: "image/svg+xml;charset=utf-8" });
  const svgUrl = URL.createObjectURL(svgBlob);

  try {
    const image = await loadImage(svgUrl);
    const canvas = document.createElement("canvas");
    const width = 1320;
    const height = 860;
    const scale = 2;
    canvas.width = width * scale;
    canvas.height = height * scale;
    const context = canvas.getContext("2d");
    if (!context) {
      throw new Error("无法创建 PNG 导出画布。");
    }
    context.scale(scale, scale);
    context.drawImage(image, 0, 0, width, height);
    const png = await canvasToBlob(canvas);
    downloadBlob("codex-token-bar.png", png);
  } finally {
    URL.revokeObjectURL(svgUrl);
  }
}

export function dashboardToExportSvg(snapshot: ExportableDashboardSnapshot): string {
  const days = snapshot.activityDays.slice(-52);
  const maxTokens = Math.max(1, ...days.map((day) => day.tokens));
  const bars = days.map((day, index) => {
    const x = 96 + index * 20;
    const height = Math.max(5, (day.tokens / maxTokens) * 118);
    const y = 660 - height;
    return `<rect x="${x}" y="${y.toFixed(1)}" width="11" height="${height.toFixed(1)}" rx="4" fill="#1a84ff" opacity="${(0.28 + (day.tokens / maxTokens) * 0.62).toFixed(2)}"><title>${escapeXml(day.date)} ${day.tokens} tokens</title></rect>`;
  }).join("");
  const latestDay = snapshot.activityDays.at(-1);
  const exportedAt = shortDate(snapshot.generatedAt);

  return `<svg xmlns="http://www.w3.org/2000/svg" width="1320" height="860" viewBox="0 0 1320 860">
  <rect width="1320" height="860" rx="44" fill="#f4f8fd"/>
  <circle cx="660" cy="112" r="52" fill="#ff7f20"/>
  <text x="660" y="128" text-anchor="middle" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" font-size="36" font-weight="750" fill="#fff">CX</text>
  <text x="660" y="205" text-anchor="middle" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" font-size="34" font-weight="720" fill="#1f2933">Codex Token Bar</text>
  <text x="660" y="238" text-anchor="middle" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" font-size="16" font-weight="620" fill="#7a8491">导出于 ${escapeXml(exportedAt)} · 本地 token 统计</text>
  <rect x="92" y="284" width="1136" height="94" rx="18" fill="#ffffff" stroke="#dfe7f0"/>
  ${statText(178, "累计 Token 数", formatExportTokens(snapshot.stats.totalTokens))}
  ${statText(388, "峰值 Token 数", formatExportTokens(snapshot.stats.peakDayTokens))}
  ${statText(598, "单会话最大 Token", formatExportTokens(snapshot.stats.peakThreadTokens))}
  ${statText(808, "当前连续天数", `${snapshot.stats.currentStreakDays} 天`)}
  ${statText(1018, "最长连续天数", `${snapshot.stats.longestStreakDays} 天`)}
  <rect x="92" y="420" width="1136" height="340" rx="24" fill="#ffffff" stroke="#dfe7f0"/>
  <text x="124" y="468" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" font-size="24" font-weight="720" fill="#1f2933">Token 活动</text>
  <text x="124" y="498" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" font-size="14" font-weight="620" fill="#7a8491">最近 ${days.length} 天 · ${snapshot.stats.totalCalls} 次调用 · ${snapshot.stats.totalThreads} 个会话</text>
  <line x1="96" y1="660" x2="1186" y2="660" stroke="#e4ebf3" stroke-width="2"/>
  ${bars}
  ${latestDay ? `<text x="1190" y="712" text-anchor="end" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" font-size="17" font-weight="700" fill="#1a84ff">${escapeXml(latestDay.date)} · ${formatExportTokens(latestDay.tokens)} tokens</text>` : ""}
</svg>`;
}

function downloadTextFile(filename: string, mimeType: string, content: string): void {
  const blob = new Blob([content], { type: mimeType });
  downloadBlob(filename, blob);
}

function downloadBlob(filename: string, blob: Blob): void {
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

function loadImage(url: string): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const image = new Image();
    image.onload = () => resolve(image);
    image.onerror = () => reject(new Error("PNG 导出图片加载失败。"));
    image.src = url;
  });
}

function canvasToBlob(canvas: HTMLCanvasElement): Promise<Blob> {
  return new Promise((resolve, reject) => {
    canvas.toBlob((blob) => {
      if (!blob) {
        reject(new Error("PNG 导出编码失败。"));
        return;
      }
      resolve(blob);
    }, "image/png");
  });
}

function csvCell(value: string): string {
  if (!/[",\n\r]/.test(value)) {
    return value;
  }
  return `"${value.replaceAll("\"", "\"\"")}"`;
}

function statText(x: number, label: string, value: string): string {
  return `<text x="${x}" y="324" text-anchor="middle" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" font-size="26" font-weight="760" fill="#1f2933">${escapeXml(value)}</text>
  <text x="${x}" y="354" text-anchor="middle" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" font-size="15" font-weight="650" fill="#8a949f">${escapeXml(label)}</text>`;
}

function formatExportTokens(value: number): string {
  if (value >= 100_000_000) {
    return `${(value / 100_000_000).toFixed(1)}亿`;
  }
  if (value >= 10_000) {
    return `${(value / 10_000).toFixed(1)}万`;
  }
  return value.toLocaleString("zh-CN");
}

function shortDate(value: string): string {
  if (!value) {
    return "--";
  }
  return value.slice(0, 10);
}

function escapeXml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll("\"", "&quot;");
}
