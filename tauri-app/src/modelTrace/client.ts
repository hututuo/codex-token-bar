import { callCommandStrict } from "../api/command";
import type { TraceHistory, TracePlan, TraceSnapshot } from "./types";

export const readSnapshot = () => callCommandStrict<TraceSnapshot>("read_modeltrace_snapshot");
export const startPlan = (model: string, rounds: number) => callCommandStrict<TracePlan>("start_modeltrace_plan", {model, rounds}, null);
export const cancelPlan = (planId: string) => callCommandStrict<void>("cancel_modeltrace_plan", {planId}, null);
export const readHistory = (since: number, until: number, offset = 0) =>
  callCommandStrict<TraceHistory>("read_modeltrace_history", {since, until, model: null, offset});
