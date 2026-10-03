import packageInfo from "../../package.json" with { type: "json" };
import type { CodexHomeSourceEnvelope } from "../types/platform.ts";

let source = "尚未确认数据源";
export function setDiagnosticSource(envelope: CodexHomeSourceEnvelope) {
  source = `${envelope.codexHome.path} · 来源=${envelope.codexHome.source} · 目录存在=${envelope.codexHome.exists} · generation=${envelope.transitionGeneration}`;
}
export function diagnosticSourceText() { return source; }
export function diagnosticEnvironmentText() {
  return `Codex Token Bar · 跨平台端\n版本：${packageInfo.version}\n环境：${typeof navigator === "undefined" ? "test" : navigator.userAgent}\n数据源：${source}\n记录范围：本次运行；历史最多 100 条`;
}
