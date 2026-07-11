import type { UpdateAvailability } from "../api/updateClient";
import type { UpdateCheckOutcome } from "./updateCheckScheduler";

export function automaticUpdateNotice(
  outcome: UpdateCheckOutcome<UpdateAvailability>,
) {
  if (outcome.kind !== "completed" || outcome.value.status !== "available") {
    return null;
  }
  return {
    kind: "available" as const,
    message: `发现新版本 ${outcome.value.version}`,
    update: outcome.value,
  };
}
