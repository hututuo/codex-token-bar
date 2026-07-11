export const UNSUPPORTED_UPDATE_MESSAGE = "此平台暂不支持应用内更新";
export const UPDATE_CHECK_FAILURE_MESSAGE = "暂时无法检查更新，请稍后重试";

export function isUnsupportedUpdaterError(error: unknown): boolean {
  const message = errorMessage(error).toLowerCase();
  return /(?:updater|platform|target|darwin|macos)[\s\S]{0,80}(?:unsupported|not supported|not available)/.test(message)
    || /(?:unsupported|not supported)[\s\S]{0,80}(?:updater|platform|target|darwin|macos)/.test(message);
}

export function manualUpdateFailureMessage(error: unknown): string {
  return isUnsupportedUpdaterError(error)
    ? UNSUPPORTED_UPDATE_MESSAGE
    : UPDATE_CHECK_FAILURE_MESSAGE;
}

function errorMessage(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }
  return typeof error === "string" ? error : String(error);
}
