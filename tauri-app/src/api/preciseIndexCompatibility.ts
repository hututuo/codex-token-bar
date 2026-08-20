import { commandErrorPayload } from "./command";

export interface PreciseIndexUpgradeRequired {
  component: string;
  stored: string;
  supported: string;
  message: string;
}

export class PreciseIndexUpgradeRequiredError extends Error {
  readonly details: PreciseIndexUpgradeRequired;

  constructor(details: PreciseIndexUpgradeRequired) {
    super(details.message);
    this.name = "PreciseIndexUpgradeRequiredError";
    this.details = details;
  }
}

export function classifyPreciseIndexUpgradeRequired(
  error: unknown,
): PreciseIndexUpgradeRequired | null {
  const direct = commandErrorPayload(error);
  const fromDirect = parsePayload(direct);
  if (fromDirect !== null) return fromDirect;

  // Some Tauri transports stringify structured command errors. Parse the
  // stable `code` field only; never classify by localized message text.
  const message = error instanceof Error
    ? error.message
    : typeof error === "string"
      ? error
      : null;
  if (message === null) return null;
  try {
    return parsePayload(JSON.parse(message));
  } catch {
    return null;
  }
}

function parsePayload(value: unknown): PreciseIndexUpgradeRequired | null {
  if (typeof value !== "object" || value === null) return null;
  const payload = value as Record<string, unknown>;
  if (payload.code !== "indexUpgradeRequired"
    || typeof payload.component !== "string"
    || typeof payload.stored !== "string"
    || typeof payload.supported !== "string"
    || typeof payload.message !== "string") {
    return null;
  }
  return {
    component: payload.component,
    stored: payload.stored,
    supported: payload.supported,
    message: payload.message,
  };
}
