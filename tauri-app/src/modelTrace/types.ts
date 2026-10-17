export interface Candidate {
  model: string;
  displayName: string;
  family: string;
  probability: number;
  profileSimilarity: number;
  score: number;
}
export interface Attribution {
  prediction: string;
  candidates: Candidate[];
  usedOutputs: number;
  bankSha256: string;
  upstreamCommit: string;
  beta: number;
}
export interface TraceRun {
  id: string;
  planId: string;
  model: string;
  startedAt: number;
  completedAt: number;
  status: string;
  attempts: number;
  validSamples: number;
  message: string | null;
  attribution: Attribution | null;
}
export interface TracePlan {
  id: string;
  model: string;
  startedAt: number;
  status: string;
  totalRounds: number;
  completedRounds: number;
  currentAttempt: number;
  validSamples: number;
  nextRunAt: number | null;
  error: string | null;
}
export interface TraceSnapshot {
  models: string[];
  scopeKey: string;
  plan: TracePlan | null;
  latest: TraceRun | null;
  bankVersion: string;
}
export interface TraceHistory { scopeKey: string; runs: TraceRun[]; hasMore: boolean }
