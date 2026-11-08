// Complete native payload for sidebar tests that focus on other UI sections.
// Keep caller-supplied counts and details; absent detail lists are valid empty lists.
export function runningThreadFixture(overrides = {}) {
  const subagents = overrides.subagents ?? 0;
  return {
    total: 0,
    mainThreads: Math.max(0, (overrides.total ?? 0) - subagents),
    subagents,
    mainModels: [],
    subagentModels: [],
    groups: [],
    unassignedSubagents: [],
    status: "ready",
    updatedAt: null,
    detail: "",
    livenessLeaseHours: 0,
    ...overrides,
  };
}
