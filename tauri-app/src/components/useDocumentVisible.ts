import { useEffect, useState } from "react";

/** Native detail visibility is conveyed by unmounting; this also covers a hidden WebView/tab. */
export function useDocumentVisible() {
  const [visible, setVisible] = useState(() => typeof document === "undefined" || !document.hidden);
  useEffect(() => {
    const update = () => setVisible(!document.hidden);
    document.addEventListener("visibilitychange", update);
    update();
    return () => document.removeEventListener("visibilitychange", update);
  }, []);
  return visible;
}
