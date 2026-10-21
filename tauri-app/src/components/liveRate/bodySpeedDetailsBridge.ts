import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { useEffect } from "react";
import { isDesktopRuntimeAvailable } from "../../platform/desktopBridge";

export const BODY_SPEED_DETAILS_EVENT = "body-speed-history-open";

/** Subscribe before consuming the durable intent; coalesce overlap without losing a request. */
export function attachBodySpeedDetailsRequests({ subscribe, take, open, fail }: {
    subscribe: (handler: () => void) => Promise<() => void>;
    take: () => Promise<boolean>;
    open: () => void;
    fail: (error: string) => void;
}) {
    let disposed = false, busy = false, again = false;
    let unlisten: (() => void) | undefined;
    const consume = async () => {
        if (disposed) return;
        if (busy) { again = true; return; }
        busy = true;
        try {
            do {
                again = false;
                const requested = await take();
                if (requested && !disposed) open();
            } while (again && !disposed);
        } catch (error) { if (!disposed) fail(String(error)); }
        finally { busy = false; }
    };
    void subscribe(() => { void consume(); }).then(stop => {
        if (disposed) { stop(); return; }
        unlisten = stop;
        void consume();
    }).catch(error => { if (!disposed) fail(String(error)); });
    return () => { disposed = true; unlisten?.(); };
}

export function useBodySpeedDetailsRequests(enabled: boolean, sourceKey: string, open: () => void, fail: (error: string) => void) {
    useEffect(() => {
        if (!enabled || !sourceKey || !isDesktopRuntimeAvailable()) return;
        return attachBodySpeedDetailsRequests({
            subscribe: handler => listen(BODY_SPEED_DETAILS_EVENT, handler),
            take: () => invoke<boolean>("take_body_speed_details_request"), open, fail,
        });
    }, [enabled, sourceKey, open, fail]);
}
