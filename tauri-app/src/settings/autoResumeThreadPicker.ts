import type { AutoResumeThreadOption } from "../types/dashboard";

export const AUTO_RESUME_THREAD_PAGE_SIZE = 100;
export const AUTO_RESUME_EMPTY_PROJECT_KEY = "__codex_token_bar_no_cwd__";

export interface AutoResumeProjectOption {
  key: string;
  cwd: string;
  name: string;
  threadCount: number;
  updatedAt: number;
}

export function autoResumeProjectKey(cwd: string): string {
  const trimmed = cwd.trim();
  const normalized = trimmed === "/" ? trimmed : trimmed.replace(/[\\/]+$/u, "");
  if (normalized.length === 0) return AUTO_RESUME_EMPTY_PROJECT_KEY;
  return normalized;
}

export function buildAutoResumeProjects(
  threads: AutoResumeThreadOption[],
): AutoResumeProjectOption[] {
  const projects = new Map<string, AutoResumeProjectOption>();
  for (const thread of threads) {
    const key = autoResumeProjectKey(thread.cwd);
    const cwd = key === AUTO_RESUME_EMPTY_PROJECT_KEY ? "" : key;
    const existing = projects.get(key);
    if (existing) {
      existing.threadCount += 1;
      existing.updatedAt = Math.max(existing.updatedAt, thread.updatedAt);
      continue;
    }
    projects.set(key, {
      key,
      cwd,
      name: projectDisplayName(cwd),
      threadCount: 1,
      updatedAt: thread.updatedAt,
    });
  }
  return [...projects.values()].sort((left, right) => (
    right.updatedAt - left.updatedAt
      || left.name.localeCompare(right.name, "zh-CN")
      || left.cwd.localeCompare(right.cwd, "zh-CN")
  ));
}

export function resolveAutoResumeProjectKey(
  projects: AutoResumeProjectOption[],
  currentKey: string,
  preferredCwd: string,
): string {
  if (projects.some((project) => project.key === currentKey)) return currentKey;
  const preferredKey = autoResumeProjectKey(preferredCwd);
  if (projects.some((project) => project.key === preferredKey)) return preferredKey;
  return projects[0]?.key ?? "";
}

export function autoResumeThreadsInProject(
  threads: AutoResumeThreadOption[],
  projectKey: string,
): AutoResumeThreadOption[] {
  if (!projectKey) return [];
  return threads
    .filter((thread) => autoResumeProjectKey(thread.cwd) === projectKey)
    .sort((left, right) => right.updatedAt - left.updatedAt || left.id.localeCompare(right.id));
}

export function matchingAutoResumeThreads(
  threads: AutoResumeThreadOption[],
  projectKey: string,
  query: string,
): AutoResumeThreadOption[] {
  const normalizedQuery = query.trim().toLocaleLowerCase();
  return autoResumeThreadsInProject(threads, projectKey).filter((thread) => (
    normalizedQuery.length === 0
      || [thread.title, thread.cwd, thread.id, thread.status, thread.source]
        .some((value) => value.toLocaleLowerCase().includes(normalizedQuery))
  ));
}

export function visibleAutoResumeThreads(
  threads: AutoResumeThreadOption[],
  projectKey: string,
  query: string,
  selectedThreadID = "",
  limit = AUTO_RESUME_THREAD_PAGE_SIZE,
): AutoResumeThreadOption[] {
  const matches = matchingAutoResumeThreads(threads, projectKey, query);
  const boundedLimit = Math.max(1, limit);
  const visible = matches.slice(0, boundedLimit);
  if (!selectedThreadID || visible.some((thread) => thread.id === selectedThreadID)) return visible;
  const selected = matches.find((thread) => thread.id === selectedThreadID);
  if (!selected) return visible;
  if (visible.length < boundedLimit) return [...visible, selected];
  return [...visible.slice(0, boundedLimit - 1), selected];
}

function projectDisplayName(cwd: string): string {
  if (!cwd) return "未记录工作目录";
  const components = cwd.split(/[\\/]/u).filter(Boolean);
  return components.at(-1) ?? cwd;
}
