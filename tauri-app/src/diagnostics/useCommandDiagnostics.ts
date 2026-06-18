import { useEffect, useState } from "react";
import {
  getCommandDiagnosticsSnapshot,
  subscribeCommandDiagnostics,
  type CommandFailureDiagnostic,
} from "./localDiagnostics";

export function useCommandDiagnostics(): CommandFailureDiagnostic[] {
  const [diagnostics, setDiagnostics] = useState<CommandFailureDiagnostic[]>(
    () => getCommandDiagnosticsSnapshot(),
  );

  useEffect(() => subscribeCommandDiagnostics(setDiagnostics), []);

  return diagnostics;
}
