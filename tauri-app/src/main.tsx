import React from "react";
import ReactDOM from "react-dom/client";
import { App } from "./app/App";
import "./styles/global.css";

function showRuntimeError(error: unknown) {
  const message = error instanceof Error ? `${error.message}\n${error.stack ?? ""}` : String(error);
  const overlay = runtimeErrorOverlay();
  if (overlay !== null) {
    overlay.textContent = message;
  }
}

function runtimeErrorOverlay() {
  if (document.body === null) {
    return null;
  }

  let overlay = document.getElementById("runtime-error-overlay");
  if (overlay === null) {
    overlay = document.createElement("pre");
    overlay.id = "runtime-error-overlay";
    overlay.style.whiteSpace = "pre-wrap";
    overlay.style.position = "fixed";
    overlay.style.zIndex = "99999";
    overlay.style.left = "24px";
    overlay.style.right = "24px";
    overlay.style.top = "24px";
    overlay.style.maxHeight = "60vh";
    overlay.style.overflow = "auto";
    overlay.style.margin = "0";
    overlay.style.padding = "16px";
    overlay.style.border = "1px solid #ff6699";
    overlay.style.background = "#fff4f4";
    overlay.style.color = "#8a1f1f";
    overlay.style.borderRadius = "8px";
    overlay.style.font = "13px/1.45 ui-monospace, Menlo, monospace";
    document.body.appendChild(overlay);
  }
  return overlay;
}

window.addEventListener("error", (event) => {
  showRuntimeError(event.error ?? event.message);
});

window.addEventListener("unhandledrejection", (event) => {
  showRuntimeError(event.reason);
});

try {
  ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(
    <React.StrictMode>
      <App />
    </React.StrictMode>,
  );
} catch (error) {
  showRuntimeError(error);
}
