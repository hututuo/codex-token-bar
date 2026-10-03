// Keep error codes and cause chains without serializing invocation arguments.
export function diagnosticErrorText(error: unknown): string {
  const seen = new WeakSet<object>();
  let visited = 0;
  function visit(value: unknown, depth: number): unknown {
    if (++visited > 200) return "[diagnostic item limit]";
    if (depth > 5) return "[cause depth limit]";
    if (typeof value === "string") return value.slice(0, 16_384);
    if (value === null || typeof value !== "object") return value === undefined ? "undefined" : value;
    if (seen.has(value)) return "[circular]";
    seen.add(value);
    if (Array.isArray(value)) return value.slice(0, 50).map(item => visit(item, depth + 1));
    const result: Record<string, unknown> = {};
    const entries: [string, unknown][] = value instanceof Error
      ? [["name", value.name], ["message", value.message], ["cause", value.cause], ...Object.entries(value)]
      : Object.entries(value);
    for (const [key, item] of entries.slice(0, 50)) {
      if (item === undefined) continue;
      result[key] = /token|password|authorization|cookie|secret|api.?key/i.test(key)
        ? "[redacted]" : visit(item, depth + 1);
    }
    return result;
  }
  try {
    const payload = error && typeof error === "object" && "commandPayload" in error ? error.commandPayload : undefined;
    if (payload !== undefined) error = payload;
    if (typeof error === "string" && error.length <= 16_384 && /^[\s]*[\[{]/.test(error)) {
      try { error = JSON.parse(error); } catch { /* Keep non-JSON error text. */ }
    }
    const plainError = error instanceof Error && !error.cause && Object.keys(error).length === 0;
    const value = typeof error === "string" ? error : error instanceof Error && plainError ? error.message : JSON.stringify(visit(error, 0), null, 2);
    const redacted = (value ?? String(error)).replace(/\bBearer\s+[^\s"\\]+/gi, "Bearer [redacted]");
    return redacted.length > 16_384 ? redacted.slice(0, 16_384) + "\n[diagnostic truncated]" : redacted;
  } catch { return "无法格式化错误对象"; }
}
