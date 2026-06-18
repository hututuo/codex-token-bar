import { useEffect } from "react";
import { PhysicalPosition } from "@tauri-apps/api/dpi";
import { getCurrentWindow } from "@tauri-apps/api/window";

const FLOATING_POSITION_KEY = "codex-token-bar-floating-position-v1";
const MAX_REASONABLE_COORDINATE = 20_000;

interface StoredFloatingPosition {
  x: number;
  y: number;
  savedAt: number;
}

export function useFloatingWindowPlacement() {
  useEffect(() => {
    if (!("__TAURI_INTERNALS__" in window)) {
      return;
    }

    const currentWindow = getCurrentWindow();
    const storedPosition = readStoredPosition();
    if (storedPosition !== null) {
      void currentWindow.setPosition(new PhysicalPosition(storedPosition.x, storedPosition.y));
    }

    let disposed = false;
    let unlisten: (() => void) | null = null;

    void currentWindow.onMoved(({ payload }) => {
      writeStoredPosition(payload.x, payload.y);
    }).then((listener) => {
      if (disposed) {
        listener();
      } else {
        unlisten = listener;
      }
    });

    return () => {
      disposed = true;
      unlisten?.();
    };
  }, []);
}

function readStoredPosition(): StoredFloatingPosition | null {
  try {
    const raw = window.localStorage.getItem(FLOATING_POSITION_KEY);
    if (raw === null) {
      return null;
    }

    const parsed = JSON.parse(raw) as Partial<StoredFloatingPosition>;
    if (!isValidCoordinate(parsed.x) || !isValidCoordinate(parsed.y)) {
      return null;
    }

    return {
      x: parsed.x,
      y: parsed.y,
      savedAt: typeof parsed.savedAt === "number" ? parsed.savedAt : Date.now(),
    };
  } catch {
    return null;
  }
}

function writeStoredPosition(x: number, y: number) {
  if (!isValidCoordinate(x) || !isValidCoordinate(y)) {
    return;
  }

  const payload: StoredFloatingPosition = {
    x,
    y,
    savedAt: Date.now(),
  };
  window.localStorage.setItem(FLOATING_POSITION_KEY, JSON.stringify(payload));
}

function isValidCoordinate(value: unknown): value is number {
  return (
    typeof value === "number" &&
    Number.isFinite(value) &&
    Math.abs(value) <= MAX_REASONABLE_COORDINATE
  );
}
