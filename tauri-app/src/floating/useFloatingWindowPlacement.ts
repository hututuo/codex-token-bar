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
    const positionPersistence = createFloatingPositionPersistence((position) =>
      saveFloatingPosition({
        ...position,
        savedAt: Date.now(),
      }),
    );

    void readAppSettings().then((settings) => {
      if (!disposed && settings !== null && isStoredPosition(settings.floatingPosition)) {
        positionPersistence.setPersisted(settings.floatingPosition);
        void desktopPlatform.setFloatingWindowPosition(settings.floatingPosition);
      }
    }).catch(() => {
      // 保持当前窗口位置；失败已由命令诊断链路记录。
    });

    void desktopPlatform.onFloatingWindowMoved((position) => {
      if (isValidCoordinate(position.x) && isValidCoordinate(position.y)) {
        positionPersistence.schedule(position);
      }
    }).then((listener) => {
      if (disposed) {
        listener();
      } else {
        unlisten = listener;
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
