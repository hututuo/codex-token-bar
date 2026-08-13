import { useEffect } from "react";
import { readAppSettings, saveFloatingPosition } from "../api/client";
import { desktopPlatform } from "../platform/desktop";
import { createFloatingPositionPersistence } from "./floatingPositionPersistence";

const MAX_REASONABLE_COORDINATE = 20_000;

interface StoredFloatingPosition {
  x: number;
  y: number;
  savedAt: number;
}

export function useFloatingWindowPlacement() {
  useEffect(() => {
    let disposed = false;
    let unlisten: (() => void) | null = null;
    let movementGeneration = 0;
    let restoringStoredPosition = false;
    const positionPersistence = createFloatingPositionPersistence((position) =>
      saveFloatingPosition({
        ...position,
        savedAt: Date.now(),
      }),
    );

    void desktopPlatform.onFloatingWindowMoved((position) => {
      if (restoringStoredPosition) return;
      if (isValidCoordinate(position.x) && isValidCoordinate(position.y)) {
        movementGeneration += 1;
        positionPersistence.schedule(position);
      }
    }).then(async (listener) => {
      if (disposed) {
        listener();
      } else {
        unlisten = listener;
        const restoreGeneration = movementGeneration;
        try {
          const settings = await readAppSettings();
          if (
            disposed
            || movementGeneration !== restoreGeneration
            || settings === null
            || !isStoredPosition(settings.floatingPosition)
          ) return;
          positionPersistence.setPersisted(settings.floatingPosition);
          restoringStoredPosition = true;
          await desktopPlatform.setFloatingWindowPosition(settings.floatingPosition);
          restoringStoredPosition = false;
        } catch {
          restoringStoredPosition = false;
          // 保持当前窗口位置；失败已由命令诊断链路记录。
        }
      }
    });

    return () => {
      disposed = true;
      positionPersistence.flush();
      unlisten?.();
    };
  }, []);
}

function isStoredPosition(value: unknown): value is StoredFloatingPosition {
  const position = value as Partial<StoredFloatingPosition> | null;
  return position !== null && isValidCoordinate(position.x) && isValidCoordinate(position.y);
}

function isValidCoordinate(value: unknown): value is number {
  return (
    typeof value === "number" &&
    Number.isFinite(value) &&
    Math.abs(value) <= MAX_REASONABLE_COORDINATE
  );
}
