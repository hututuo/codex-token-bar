import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type MouseEvent as ReactMouseEvent,
} from "react";
import {
  archiveSessionThreads,
  createSessionRecoveryArchives,
  deleteSessionThreads,
  listSessionManagementCatalog,
  readSessionContextPage,
  unarchiveSessionThreads,
} from "../api/client";
import { prepareSessionDeleteConfirmation } from "../api/sessionManagementClient";
import {
  DEFAULT_LARGE_SESSION_BYTES,
  SESSION_DISCLOSURE_PAGE_SIZE,
  buildSessionCollections,
  buildSessionProjects,
  eligibilityForMutation,
  filterSessionThreads,
  formatSessionBytes,
  formatSessionTimestamp,
  mergeContextMessages,
  nextSessionNavigationStage,
  projectLabel,
  relatedThreads,
  sessionDeletionImpact,
  type SessionCollectionId,
  type SessionDeletionImpact,
  type SessionNavigationStage,
  type SessionSortId,
} from "../sessionManagement/model";
import type {
  SessionContextPage,
  SessionDeleteConfirmation,
  SessionManagementCapability,
  SessionManagementCatalog,
  SessionManagementMutation,
  SessionManagementThread,
  SessionMutationBatchResult,
} from "../types/sessionManagement";
import type { CodexHomeSourceToken } from "../types/dashboard";

export interface SessionManagementClient {
  listCatalog: () => Promise<SessionManagementCatalog>;
  readContextPage: (
    threadId: string,
    beforeOffset?: number | null,
    pageSize?: number,
  ) => Promise<SessionContextPage>;
  archive: (threadIds: string[]) => Promise<SessionMutationBatchResult>;
  unarchive: (threadIds: string[]) => Promise<SessionMutationBatchResult>;
  delete: (
    threadIds: string[],
    confirmation: SessionDeleteConfirmation,
  ) => Promise<SessionMutationBatchResult>;
  prepareDeleteConfirmation: (
    threadIds: string[],
  ) => Promise<SessionDeleteConfirmation>;
  createRecoveryArchives: (threadIds: string[]) => Promise<SessionMutationBatchResult>;
}

interface SessionManagementWorkspaceProps {
  client?: SessionManagementClient;
  onClose: () => void;
  open: boolean;
  sourceToken: CodexHomeSourceToken;
}

interface ContextState {
  error: string | null;
  fileIdentity: string | null;
  hasMoreBefore: boolean;
  loading: boolean;
  messages: SessionContextPage["messages"];
  nextBeforeOffset: number | null;
  threadId: string | null;
  warnings: string[];
}

interface DeleteConfirmationSnapshot {
  selectedThreads: SessionManagementThread[];
  impact: SessionDeletionImpact;
  confirmation: SessionDeleteConfirmation;
  canCreateRecovery: boolean;
}

type DetailTab = "overview" | "context" | "lineage";

const EMPTY_CONTEXT: ContextState = {
  error: null,
  fileIdentity: null,
  hasMoreBefore: false,
  loading: false,
  messages: [],
  nextBeforeOffset: null,
  threadId: null,
  warnings: [],
};

export function SessionManagementWorkspace({
  client: injectedClient,
  onClose,
  open,
  sourceToken,
}: SessionManagementWorkspaceProps) {
  const sourceScopeKey = [
    sourceToken.transitionGeneration,
    sourceToken.canonicalHomeKey,
    sourceToken.physicalHomeKey,
  ].join(":");
  const client = useMemo<SessionManagementClient>(() => injectedClient ?? {
    listCatalog: () => listSessionManagementCatalog(sourceToken),
    readContextPage: (threadId, beforeOffset, pageSize) => (
      readSessionContextPage(sourceToken, threadId, beforeOffset, pageSize)
    ),
    archive: (threadIds) => archiveSessionThreads(sourceToken, threadIds),
    unarchive: (threadIds) => unarchiveSessionThreads(sourceToken, threadIds),
    delete: (threadIds, confirmation) => (
      deleteSessionThreads(sourceToken, threadIds, confirmation)
    ),
    prepareDeleteConfirmation: (threadIds) => (
      prepareSessionDeleteConfirmation(sourceToken, threadIds)
    ),
    createRecoveryArchives: (threadIds) => (
      createSessionRecoveryArchives(sourceToken, threadIds)
    ),
  }, [
    injectedClient,
    sourceToken.canonicalHomeKey,
    sourceToken.physicalHomeKey,
    sourceToken.transitionGeneration,
  ]);
  const [catalog, setCatalog] = useState<SessionManagementCatalog | null>(null);
  const [catalogError, setCatalogError] = useState<string | null>(null);
  const [catalogLoading, setCatalogLoading] = useState(false);
  const [collection, setCollection] = useState<SessionCollectionId>("all");
  const [query, setQuery] = useState("");
  const [sort, setSort] = useState<SessionSortId>("recent");
  const [minimumSizeBytes, setMinimumSizeBytes] = useState(DEFAULT_LARGE_SESSION_BYTES);
  const [idleDays, setIdleDays] = useState<number | null>(null);
  const [visibleLimit, setVisibleLimit] = useState(SESSION_DISCLOSURE_PAGE_SIZE);
  const [selectedIds, setSelectedIds] = useState<Set<string>>(() => new Set());
  const [focusedThreadId, setFocusedThreadId] = useState<string | null>(null);
  const [navigationStage, setNavigationStage] = useState<SessionNavigationStage>("projects");
  const [detailTab, setDetailTab] = useState<DetailTab>("overview");
  const [context, setContext] = useState<ContextState>(EMPTY_CONTEXT);
  const [mutation, setMutation] = useState<SessionManagementMutation | null>(null);
  const [mutationReport, setMutationReport] = useState<SessionMutationBatchResult | null>(null);
  const [mutationError, setMutationError] = useState<string | null>(null);
  const [deleteDialogOpen, setDeleteDialogOpen] = useState(false);
  const [deletePreparationLoading, setDeletePreparationLoading] = useState(false);
  const [deleteConfirmed, setDeleteConfirmed] = useState(false);
  const [deleteConfirmationSnapshot, setDeleteConfirmationSnapshot] =
    useState<DeleteConfirmationSnapshot | null>(null);
  const closeButtonRef = useRef<HTMLButtonElement>(null);
  const previousFocusRef = useRef<HTMLElement | null>(null);
  const dialogRef = useRef<HTMLElement>(null);
  const mutationRef = useRef<SessionManagementMutation | null>(null);
  const deleteDialogOpenRef = useRef(false);
  const contextRequestGenerationRef = useRef(0);
  const deletePreparationGenerationRef = useRef(0);
  const deletePreparationPendingRef = useRef(false);

  const invalidatePendingDeletePreparation = useCallback(() => {
    deletePreparationGenerationRef.current += 1;
    deletePreparationPendingRef.current = false;
    setDeletePreparationLoading(false);
  }, []);

  const invalidateDeleteConfirmation = useCallback(() => {
    invalidatePendingDeletePreparation();
    setDeleteDialogOpen(false);
    setDeleteConfirmed(false);
    setDeleteConfirmationSnapshot(null);
  }, [invalidatePendingDeletePreparation]);

  const refreshCatalog = useCallback(async (preserveContent = true) => {
    // A refresh can replace the catalog generation used to derive a deletion
    // scope. Cancel both an in-flight preparation and an already-open snapshot
    // before requesting or publishing that new generation.
    invalidateDeleteConfirmation();
    setCatalogLoading(true);
    setCatalogError(null);
    try {
      const nextCatalog = await client.listCatalog();
      invalidateDeleteConfirmation();
      setCatalog(nextCatalog);
      setSelectedIds((current) => {
        const existing = new Set(nextCatalog.threads.map((thread) => thread.id));
        return new Set([...current].filter((id) => existing.has(id)));
      });
      setFocusedThreadId((current) => (
        current && nextCatalog.threads.some((thread) => thread.id === current) ? current : null
      ));
      return nextCatalog;
    } catch (error) {
      setCatalogError(errorMessage(error));
      if (!preserveContent) setCatalog(null);
      return null;
    } finally {
      setCatalogLoading(false);
    }
  }, [client, invalidateDeleteConfirmation]);

  useEffect(() => {
    contextRequestGenerationRef.current += 1;
    invalidateDeleteConfirmation();
    setCatalog(null);
    setCatalogError(null);
    setSelectedIds(new Set());
    setFocusedThreadId(null);
    setNavigationStage("projects");
    setContext(EMPTY_CONTEXT);
    setMutationReport(null);
    setMutationError(null);
  }, [invalidateDeleteConfirmation, sourceScopeKey]);

  useEffect(() => {
    if (open) return;
    invalidateDeleteConfirmation();
    setNavigationStage("projects");
  }, [invalidateDeleteConfirmation, open]);

  useEffect(() => {
    if (!open) return undefined;
    previousFocusRef.current = document.activeElement instanceof HTMLElement
      ? document.activeElement
      : null;
    window.requestAnimationFrame(() => closeButtonRef.current?.focus());
    return () => {
      previousFocusRef.current?.focus();
    };
  }, [open]);

  useEffect(() => {
    if (open) void refreshCatalog(false);
  }, [open, refreshCatalog, sourceScopeKey]);

  useEffect(() => {
    mutationRef.current = mutation;
    deleteDialogOpenRef.current = deleteDialogOpen;
  }, [deleteDialogOpen, mutation]);

  useEffect(() => {
    if (!open) return undefined;
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key !== "Escape" || mutationRef.current !== null) return;
      if (deleteDialogOpenRef.current) {
        invalidateDeleteConfirmation();
      } else {
        invalidateDeleteConfirmation();
        onClose();
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [invalidateDeleteConfirmation, onClose, open]);

  useEffect(() => {
    setVisibleLimit(SESSION_DISCLOSURE_PAGE_SIZE);
  }, [collection, idleDays, minimumSizeBytes, query, sort]);

  const threads = catalog?.threads ?? [];
  const collections = useMemo(() => buildSessionCollections(threads), [threads]);
  const projects = useMemo(() => buildSessionProjects(threads), [threads]);
  const filteredThreads = useMemo(() => filterSessionThreads(threads, {
    collection,
    idleDays,
    minimumSizeBytes,
    query,
    sort,
  }), [collection, idleDays, minimumSizeBytes, query, sort, threads]);
  const visibleThreads = filteredThreads.slice(0, visibleLimit);
  const selectedThreads = useMemo(
    () => threads.filter((thread) => selectedIds.has(thread.id)),
    [selectedIds, threads],
  );
  const deletionImpact = useMemo(
    () => sessionDeletionImpact(threads, selectedThreads),
    [selectedThreads, threads],
  );
  const focusedThread = threads.find((thread) => thread.id === focusedThreadId) ?? null;
  const focusedRelations = focusedThread ? relatedThreads(focusedThread, threads) : null;
  const allVisibleSelected = visibleThreads.length > 0
    && visibleThreads.every((thread) => selectedIds.has(thread.id));
  const activeCollectionLabel = projects.find((project) => project.id === collection)?.label
    ?? collections.find((item) => item.id === collection)?.label
    ?? "全部会话";
  const catalogWarnings = catalog?.warnings ?? [];
  const selectedBytes = selectedThreads.every((thread) => thread.fileBytes !== null)
    ? selectedThreads.reduce((sum, thread) => sum + (thread.fileBytes ?? 0), 0)
    : null;
  const filteredThreadIds = new Set(filteredThreads.map((thread) => thread.id));
  const hiddenSelectedCount = selectedThreads.filter(
    (thread) => !filteredThreadIds.has(thread.id),
  ).length;
  const recoveryCapability = catalog?.capabilities?.recoveryArchive;
  const recoveryDeleteEligibility = eligibilityForMutation(
    deletionImpact.affected,
    "recoveryArchive",
  );
  const recoveryDeleteAvailable = deletionImpact.affected.length > 0
    && deletionImpact.blockedAffected.length === 0
    && recoveryDeleteEligibility.blocked.length === 0
    && capabilityAvailable(recoveryCapability);
  const recoveryDeleteReason = recoveryDeleteEligibility.reason
    ?? capabilityReason(recoveryCapability)
    ?? (
      deletionImpact.blockedAffected.length > 0
        ? "完整影响范围内存在运行、加载或受保护会话，无法建立删除前恢复包。"
        : "必须先为完整影响范围创建并验证恢复包。"
    );

  useEffect(() => {
    if (
      detailTab !== "context"
      || focusedThread === null
      || context.threadId === focusedThread.id
    ) {
      return;
    }
    void loadContext(focusedThread.id, false);
  }, [context.threadId, detailTab, focusedThread?.id]);

  if (!open) return null;

  async function loadContext(threadId: string, older: boolean) {
    const requestGeneration = contextRequestGenerationRef.current + 1;
    contextRequestGenerationRef.current = requestGeneration;
    const beforeOffset = older && context.threadId === threadId
      ? context.nextBeforeOffset
      : null;
    setContext((current) => ({
      ...(older && current.threadId === threadId ? current : EMPTY_CONTEXT),
      error: null,
      loading: true,
      threadId,
    }));
    try {
      const page = await client.readContextPage(threadId, beforeOffset, 40);
      if (contextRequestGenerationRef.current !== requestGeneration) return;
      setContext((current) => ({
        ...(older
          && current.threadId === threadId
          && current.fileIdentity !== null
          && current.fileIdentity !== page.fileIdentity
          ? {
            ...current,
            error: "会话文件在分页期间已变化。为避免混合两代上下文，请重新读取最新一页。",
            loading: false,
          }
          : {
            error: null,
            fileIdentity: page.fileIdentity,
            hasMoreBefore: page.hasMoreBefore,
            loading: false,
            messages: older
              ? mergeContextMessages(current.messages, page.messages)
              : [...page.messages].sort((left, right) => left.offset - right.offset),
            nextBeforeOffset: page.nextBeforeOffset,
            threadId,
            warnings: [...new Set([...(older ? current.warnings : []), ...(page.warnings ?? [])])],
          }),
      }));
    } catch (error) {
      if (contextRequestGenerationRef.current !== requestGeneration) return;
      setContext((current) => ({
        ...current,
        error: errorMessage(error),
        loading: false,
        threadId,
      }));
    }
  }

  function focusThread(thread: SessionManagementThread) {
    contextRequestGenerationRef.current += 1;
    setFocusedThreadId(thread.id);
    setDetailTab("overview");
    setNavigationStage((current) => nextSessionNavigationStage(current, "chooseThread"));
    if (context.threadId !== thread.id) setContext(EMPTY_CONTEXT);
  }

  function chooseCollection(nextCollection: SessionCollectionId) {
    contextRequestGenerationRef.current += 1;
    setCollection(nextCollection);
    setFocusedThreadId(null);
    setContext(EMPTY_CONTEXT);
    setNavigationStage((current) => nextSessionNavigationStage(current, "chooseCollection"));
  }

  function navigateBack() {
    setNavigationStage((current) => nextSessionNavigationStage(current, "back"));
  }

  function toggleSelection(thread: SessionManagementThread) {
    invalidatePendingDeletePreparation();
    setSelectedIds((current) => {
      const next = new Set(current);
      if (next.has(thread.id)) next.delete(thread.id);
      else next.add(thread.id);
      return next;
    });
  }

  function toggleVisibleSelection() {
    invalidatePendingDeletePreparation();
    setSelectedIds((current) => {
      const next = new Set(current);
      if (allVisibleSelected) {
        for (const thread of visibleThreads) next.delete(thread.id);
      } else {
        for (const thread of visibleThreads) next.add(thread.id);
      }
      return next;
    });
  }

  async function openDeleteConfirmation() {
    if (deletePreparationPendingRef.current) return;
    const requestGeneration = deletePreparationGenerationRef.current + 1;
    deletePreparationGenerationRef.current = requestGeneration;
    deletePreparationPendingRef.current = true;
    const frozenThreads = threads.map((thread) => ({
      ...thread,
      protectionReasons: [...thread.protectionReasons],
    }));
    const requestedIds = selectedThreads.map((thread) => thread.id);
    setDeletePreparationLoading(true);
    setMutationError(null);
    setMutationReport(null);
    try {
      const confirmation = await client.prepareDeleteConfirmation(requestedIds);
      if (
        deletePreparationGenerationRef.current !== requestGeneration
        || !deletePreparationPendingRef.current
      ) {
        return;
      }
      if (confirmation.physicalHomeKey !== sourceToken.physicalHomeKey) {
        throw new Error("后端删除确认绑定了不同的 Codex Home。");
      }
      if (!sameOrderedIds(confirmation.requestedIds, requestedIds)) {
        throw new Error("后端删除确认没有精确绑定当前选择。");
      }
      const frozenSelectedIds = new Set(confirmation.requestedIds);
      const frozenSelectedThreads = frozenThreads.filter((thread) => (
        frozenSelectedIds.has(thread.id)
      ));
      const frozenImpact = sessionDeletionImpact(frozenThreads, frozenSelectedThreads);
      if (
        !sameOrderedIds(
          confirmation.effectiveRootIds,
          frozenImpact.effectiveRoots.map((thread) => thread.id),
        )
        || !sameOrderedIds(
          confirmation.affectedIds,
          frozenImpact.affected.map((thread) => thread.id),
        )
        || !sameOrderedIds(
          confirmation.rollouts.map((snapshot) => snapshot.threadId),
          confirmation.affectedIds,
        )
      ) {
        throw new Error("官方删除范围或 rollout 快照与当前目录不一致，请刷新后重新确认。");
      }
      deletePreparationPendingRef.current = false;
      setDeleteConfirmationSnapshot({
        selectedThreads: frozenSelectedThreads,
        impact: frozenImpact,
        confirmation,
        canCreateRecovery: recoveryDeleteAvailable,
      });
      setDeleteConfirmed(false);
      setDeleteDialogOpen(true);
    } catch (error) {
      if (deletePreparationGenerationRef.current !== requestGeneration) return;
      deletePreparationPendingRef.current = false;
      setMutationError(`无法冻结永久删除确认：${errorMessage(error)}`);
      await refreshCatalog(true);
    } finally {
      if (deletePreparationGenerationRef.current === requestGeneration) {
        deletePreparationPendingRef.current = false;
        setDeletePreparationLoading(false);
      }
    }
  }

  async function executeMutation(kind: SessionManagementMutation) {
    const deleteSnapshot = kind === "delete" ? deleteConfirmationSnapshot : null;
    if (kind === "delete" && deleteSnapshot === null) {
      setMutationError("删除确认范围已经失效，请重新打开确认框。");
      return;
    }
    const confirmedImpact = deleteSnapshot?.impact ?? deletionImpact;
    if (kind === "delete" && confirmedImpact.blockedAffected.length > 0) {
      setMutationError(
        `官方删除会递归影响 ${confirmedImpact.affected.length} 个会话；其中 ${confirmedImpact.blockedAffected.length} 个正在运行、加载或受保护，已拒绝删除。`,
      );
      return;
    }
    const mutationThreads = deleteSnapshot?.selectedThreads ?? selectedThreads;
    const eligibility = eligibilityForMutation(mutationThreads, kind);
    if (eligibility.eligible.length === 0 || eligibility.blocked.length > 0) {
      setMutationError(eligibility.reason ?? "所选会话不能执行此操作。");
      return;
    }
    const ids = eligibility.eligible.map((thread) => thread.id);
    setMutation(kind);
    setMutationError(null);
    setMutationReport(null);
    let returnedReport: SessionMutationBatchResult | null = null;
    try {
      const result = kind === "archive"
        ? await client.archive(ids)
        : kind === "unarchive"
          ? await client.unarchive(ids)
          : kind === "delete"
            ? await client.delete(ids, deleteSnapshot!.confirmation)
            : await client.createRecoveryArchives(ids);
      returnedReport = {
        results: result.results ?? [],
        warnings: result.warnings ?? [],
      };
      setMutationReport(returnedReport);
      const succeeded = new Set((result.results ?? []).filter((entry) => entry.ok).map((entry) => entry.threadId));
      setSelectedIds((current) => new Set([...current].filter((id) => !succeeded.has(id))));
    } catch (error) {
      setMutationError(
        `没有获得确定的操作回执，结果待确认；已立即重新读取官方目录。${errorMessage(error)}`,
      );
    } finally {
      const refreshed = await refreshCatalog(true);
      if (returnedReport !== null && refreshed !== null) {
        setMutationReport(reconcileMutationReport(
          kind,
          returnedReport,
          refreshed,
          deleteSnapshot?.confirmation.affectedIds ?? [],
        ));
      }
      setMutation(null);
      setDeleteDialogOpen(false);
      setDeleteConfirmed(false);
      setDeleteConfirmationSnapshot(null);
    }
  }

  function onListScroll(event: ReactMouseEvent<HTMLDivElement> | React.UIEvent<HTMLDivElement>) {
    const element = event.currentTarget;
    if (element.scrollHeight - element.scrollTop - element.clientHeight < 96) {
      setVisibleLimit((current) => Math.min(filteredThreads.length, current + SESSION_DISCLOSURE_PAGE_SIZE));
    }
  }

  return (
    <div
      className="session-management-overlay"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget && mutation === null) {
          invalidateDeleteConfirmation();
          onClose();
        }
      }}
    >
      <section
        aria-label="会话管理"
        aria-modal="true"
        className="session-management-workspace"
        onKeyDown={(event) => {
          if (event.key !== "Tab" || deleteDialogOpen) return;
          const focusable = [...(dialogRef.current?.querySelectorAll<HTMLElement>(
            "button:not(:disabled), input:not(:disabled), select:not(:disabled), [tabindex]:not([tabindex=\"-1\"])",
          ) ?? [])];
          if (focusable.length === 0) return;
          const currentIndex = focusable.indexOf(document.activeElement as HTMLElement);
          if (event.shiftKey && currentIndex <= 0) {
            event.preventDefault();
            focusable.at(-1)?.focus();
          } else if (!event.shiftKey && currentIndex === focusable.length - 1) {
            event.preventDefault();
            focusable[0]?.focus();
          }
        }}
        ref={dialogRef}
        role="dialog"
      >
        <header className="session-management-head">
          <div>
            <strong>会话管理</strong>
            <span>
              {catalog
                ? `${catalog.threads.length.toLocaleString("zh-CN")} 个会话 · ${formatSessionBytes(catalog.totalBytes)} · ${catalog.codexHome}`
                : "按项目查看上下文，安全归档与清理本地会话"}
            </span>
          </div>
          <div className="session-management-head-actions">
            <button
              disabled={catalogLoading || mutation !== null}
              onClick={() => void refreshCatalog(true)}
              type="button"
            >
              {catalogLoading ? "正在刷新" : "刷新"}
            </button>
            <button
              aria-label="关闭会话管理"
              disabled={mutation !== null}
              onClick={() => {
                invalidateDeleteConfirmation();
                onClose();
              }}
              ref={closeButtonRef}
              type="button"
            >
              关闭
            </button>
          </div>
        </header>

        {catalogError ? (
          <div className="session-management-banner session-management-banner--error" role="alert">
            <div>
              <strong>{catalog ? "刷新失败，保留上次目录" : "读取会话目录失败"}</strong>
              <span>{catalogError}</span>
            </div>
            <button onClick={() => void refreshCatalog(catalog !== null)} type="button">重试</button>
          </div>
        ) : null}
        {catalogWarnings.length > 0 ? (
          <details className="session-management-banner session-management-banner--warning">
            <summary>{catalogWarnings.length} 条目录读取提醒</summary>
            <ul>{catalogWarnings.map((warning) => <li key={warning}>{warning}</li>)}</ul>
          </details>
        ) : null}
        {mutationError ? (
          <div className="session-management-banner session-management-banner--error" role="alert">
            <div><strong>操作未完成</strong><span>{mutationError}</span></div>
            <button onClick={() => setMutationError(null)} type="button">知道了</button>
          </div>
        ) : null}
        {mutationReport ? <MutationReport report={mutationReport} /> : null}

        <nav aria-label="会话层级路径" className="session-management-hierarchy">
          <button
            aria-current={navigationStage === "projects" ? "step" : undefined}
            onClick={() => setNavigationStage("projects")}
            type="button"
          >
            项目：{activeCollectionLabel}
          </button>
          <span aria-hidden="true">›</span>
          <button
            aria-current={navigationStage === "sessions" ? "step" : undefined}
            disabled={navigationStage === "projects"}
            onClick={() => setNavigationStage("sessions")}
            type="button"
          >
            会话：{filteredThreads.length}
          </button>
          <span aria-hidden="true">›</span>
          <span aria-current={navigationStage === "detail" ? "step" : undefined}>
            详情：{focusedThread?.title || "未选择"}
          </span>
        </nav>

        <div
          className="session-management-layout"
          data-navigation-stage={navigationStage}
        >
          <aside aria-label="项目与智能集合" className="session-management-sidebar">
            <SidebarSection title="智能集合">
              {collections.map((item) => (
                <CollectionButton
                  active={collection === item.id}
                  count={item.count}
                  description={item.description}
                  key={item.id}
                  label={item.label}
                  onClick={() => chooseCollection(item.id)}
                />
              ))}
            </SidebarSection>
            <SidebarSection title="项目">
              {projects.length === 0 && !catalogLoading ? (
                <p className="session-management-sidebar-empty">没有可显示的主会话项目</p>
              ) : projects.map((project) => (
                <CollectionButton
                  active={collection === project.id}
                  count={project.count}
                  description={project.cwd}
                  key={project.id}
                  label={project.label}
                  onClick={() => chooseCollection(project.id)}
                />
              ))}
            </SidebarSection>
          </aside>

          <section className="session-management-list-pane" aria-label="会话列表">
            <div className="session-management-compact-back">
              <button onClick={navigateBack} type="button">← 返回项目</button>
              <span>{activeCollectionLabel} · {filteredThreads.length} 个会话</span>
            </div>
            <div className="session-management-list-tools">
              <label className="session-management-search">
                <span className="visually-hidden">搜索全部会话元数据</span>
                <input
                  aria-label="搜索全部会话元数据"
                  onChange={(event) => setQuery(event.currentTarget.value)}
                  placeholder="搜索标题、项目、ID、模型"
                  type="search"
                  value={query}
                />
              </label>
              <select
                aria-label="会话排序"
                onChange={(event) => setSort(event.currentTarget.value as SessionSortId)}
                value={sort}
              >
                <option value="recent">最近使用</option>
                <option value="size">文件最大</option>
                <option value="leastRecent">最久未用</option>
                <option value="tokens">Token 最多</option>
              </select>
            </div>
            {collection === "large" ? (
              <div className="session-management-large-filters" aria-label="大容量筛选">
                <label>
                  <span>最小大小</span>
                  <select
                    onChange={(event) => setMinimumSizeBytes(Number(event.currentTarget.value))}
                    value={minimumSizeBytes}
                  >
                    <option value={0}>全部大小</option>
                    <option value={100 * 1024 * 1024}>100 MiB</option>
                    <option value={1024 * 1024 * 1024}>1 GiB</option>
                  </select>
                </label>
                <label>
                  <span>闲置至少</span>
                  <select
                    onChange={(event) => setIdleDays(event.currentTarget.value === "all"
                      ? null
                      : Number(event.currentTarget.value))}
                    value={idleDays ?? "all"}
                  >
                    <option value="all">不限</option>
                    <option value="7">7 天</option>
                    <option value="30">30 天</option>
                    <option value="90">90 天</option>
                  </select>
                </label>
              </div>
            ) : null}
            <div className="session-management-selection-bar">
              <label>
                <input
                  aria-label="选择当前显示的全部会话"
                  checked={allVisibleSelected}
                  disabled={visibleThreads.length === 0}
                  onChange={toggleVisibleSelection}
                  type="checkbox"
                />
                <span>当前显示 {visibleThreads.length} / {filteredThreads.length}</span>
              </label>
              <div>
                <span>
                  {selectedThreads.length > 0
                    ? `已选 ${selectedThreads.length} · ${formatSessionBytes(selectedBytes)}${hiddenSelectedCount > 0 ? ` · ${hiddenSelectedCount} 个不在当前结果` : ""}`
                    : "未选择"}
                </span>
                {selectedThreads.length > 0 ? (
                  <button
                    onClick={() => {
                      invalidatePendingDeletePreparation();
                      setSelectedIds(new Set());
                    }}
                    type="button"
                  >
                    清除选择
                  </button>
                ) : null}
              </div>
            </div>
            <div
              className="session-management-thread-list"
              onScroll={onListScroll}
              role="listbox"
            >
              {catalogLoading && catalog === null ? (
                <WorkspaceLoading />
              ) : visibleThreads.length === 0 ? (
                <WorkspaceEmpty collection={collection} query={query} />
              ) : visibleThreads.map((thread) => (
                <ThreadRow
                  focused={thread.id === focusedThreadId}
                  key={thread.id}
                  onFocus={() => focusThread(thread)}
                  onToggle={() => toggleSelection(thread)}
                  selected={selectedIds.has(thread.id)}
                  thread={thread}
                />
              ))}
              {visibleThreads.length < filteredThreads.length ? (
                <button
                  className="session-management-load-more"
                  onClick={() => setVisibleLimit((current) => current + SESSION_DISCLOSURE_PAGE_SIZE)}
                  type="button"
                >
                  继续显示 {Math.min(SESSION_DISCLOSURE_PAGE_SIZE, filteredThreads.length - visibleThreads.length)} 个
                </button>
              ) : filteredThreads.length > SESSION_DISCLOSURE_PAGE_SIZE ? (
                <span className="session-management-list-end">已显示全部 {filteredThreads.length} 个结果</span>
              ) : null}
            </div>
            <ActionBar
              catalog={catalog}
              deleteWithRecoveryAvailable={recoveryDeleteAvailable}
              deleteWithRecoveryReason={recoveryDeleteReason}
              mutation={mutation}
              preparingDelete={deletePreparationLoading}
              onArchive={() => void executeMutation("archive")}
              onCreateRecovery={() => void executeMutation("recoveryArchive")}
              onDelete={openDeleteConfirmation}
              onUnarchive={() => void executeMutation("unarchive")}
              selectedThreads={selectedThreads}
            />
          </section>

          <section className="session-management-detail" aria-label="会话详情">
            <div className="session-management-compact-back">
              <button onClick={navigateBack} type="button">← 返回会话</button>
              <span>{focusedThread?.title || "会话详情"}</span>
            </div>
            {focusedThread ? (
              <>
                <DetailHeader thread={focusedThread} />
                <div aria-label="详情分类" className="session-management-detail-tabs" role="tablist">
                  {([
                    ["overview", "概览"],
                    ["context", "上下文"],
                    ["lineage", "谱系与相似"],
                  ] as const).map(([id, label]) => (
                    <button
                      aria-selected={detailTab === id}
                      className={detailTab === id ? "is-active" : ""}
                      key={id}
                      onClick={() => setDetailTab(id)}
                      role="tab"
                      type="button"
                    >
                      {label}
                    </button>
                  ))}
                </div>
                <div className="session-management-detail-scroll" role="tabpanel">
                  {detailTab === "overview" ? (
                    <OverviewPanel catalog={catalog} thread={focusedThread} />
                  ) : detailTab === "context" ? (
                    <ContextPanel
                      context={context}
                      onLoadOlder={() => void loadContext(focusedThread.id, true)}
                      onRetry={() => void loadContext(focusedThread.id, false)}
                    />
                  ) : focusedRelations ? (
                    <LineagePanel
                      onSelect={focusThread}
                      relations={focusedRelations}
                      thread={focusedThread}
                    />
                  ) : null}
                </div>
              </>
            ) : (
              <div className="session-management-detail-empty">
                <strong>选择一个会话</strong>
                <span>查看上下文、Fork 与 Subagent 谱系、相似候选和磁盘信息。</span>
              </div>
            )}
          </section>
        </div>
      </section>

      {deleteDialogOpen && deleteConfirmationSnapshot ? (
        <DeleteConfirmation
          canCreateRecovery={deleteConfirmationSnapshot.canCreateRecovery}
          confirmed={deleteConfirmed}
          onCancel={() => {
            invalidateDeleteConfirmation();
          }}
          onConfirm={() => void executeMutation("delete")}
          onConfirmedChange={setDeleteConfirmed}
          recoveryReason={capabilityReason(recoveryCapability)
            ?? "必须先为完整影响范围创建并验证恢复包，校验完成后才能永久删除。"}
          impact={deleteConfirmationSnapshot.impact}
        />
      ) : null}
    </div>
  );
}

function SidebarSection({ children, title }: { children: React.ReactNode; title: string }) {
  return (
    <section className="session-management-sidebar-section">
      <h2>{title}</h2>
      <div>{children}</div>
    </section>
  );
}

function CollectionButton({
  active,
  count,
  description,
  label,
  onClick,
}: {
  active: boolean;
  count: number;
  description: string;
  label: string;
  onClick: () => void;
}) {
  return (
    <button
      aria-pressed={active}
      className={active ? "is-active" : ""}
      onClick={onClick}
      title={description}
      type="button"
    >
      <span><strong>{label}</strong><em>{description}</em></span>
      <b>{count.toLocaleString("zh-CN")}</b>
    </button>
  );
}

function ThreadRow({
  focused,
  onFocus,
  onToggle,
  selected,
  thread,
}: {
  focused: boolean;
  onFocus: () => void;
  onToggle: () => void;
  selected: boolean;
  thread: SessionManagementThread;
}) {
  return (
    <div
      aria-selected={focused}
      className={`session-management-thread-row${focused ? " is-focused" : ""}`}
      onClick={onFocus}
      role="option"
      tabIndex={0}
      onKeyDown={(event) => {
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          onFocus();
        }
      }}
    >
      <input
        aria-label={`选择 ${thread.title || thread.id}`}
        checked={selected}
        onChange={onToggle}
        onClick={(event) => event.stopPropagation()}
        onKeyDown={(event) => event.stopPropagation()}
        onMouseDown={(event) => event.stopPropagation()}
        onPointerDown={(event) => event.stopPropagation()}
        title="选择不会执行操作；各项批量操作会独立检查当前会话是否适用"
        type="checkbox"
      />
      <div className="session-management-thread-main">
        <div className="session-management-thread-title">
          <strong>{thread.title || "未命名会话"}</strong>
          <span className={`session-management-status session-management-status--${statusTone(thread)}`}>
            {statusLabel(thread)}
          </span>
        </div>
        <p>{thread.preview || "没有可用预览"}</p>
        <div className="session-management-thread-meta">
          <span>{projectLabel(thread.cwd)}</span>
          <span>{formatSessionBytes(thread.fileBytes)}</span>
          <span>{formatSessionTimestamp(thread.recencyAt ?? thread.updatedAt)}</span>
        </div>
        <div className="session-management-thread-badges">
          {thread.forkedFromId || thread.forkChildCount > 0 ? <span>Fork</span> : null}
          {thread.isSubagent ? <span>Subagent</span> : null}
          {thread.similarityGroupId ? <span>可能相似</span> : null}
          {thread.protectionReasons.map((reason) => <span className="is-protected" key={reason}>{reason}</span>)}
        </div>
      </div>
    </div>
  );
}

function ActionBar({
  catalog,
  deleteWithRecoveryAvailable,
  deleteWithRecoveryReason,
  mutation,
  preparingDelete,
  onArchive,
  onCreateRecovery,
  onDelete,
  onUnarchive,
  selectedThreads,
}: {
  catalog: SessionManagementCatalog | null;
  deleteWithRecoveryAvailable: boolean;
  deleteWithRecoveryReason: string;
  mutation: SessionManagementMutation | null;
  preparingDelete: boolean;
  onArchive: () => void;
  onCreateRecovery: () => void;
  onDelete: () => void;
  onUnarchive: () => void;
  selectedThreads: SessionManagementThread[];
}) {
  const archive = eligibilityForMutation(selectedThreads, "archive");
  const unarchive = eligibilityForMutation(selectedThreads, "unarchive");
  const deletion = eligibilityForMutation(selectedThreads, "delete");
  const recovery = eligibilityForMutation(selectedThreads, "recoveryArchive");
  const capabilities = catalog?.capabilities;
  const busy = mutation !== null || preparingDelete;
  return (
    <div className="session-management-actions" aria-label="批量操作">
      <button
        disabled={busy || archive.eligible.length === 0 || archive.blocked.length > 0
          || !capabilityAvailable(capabilities?.officialArchive)}
        onClick={onArchive}
        title={buttonReason(archive.reason, capabilities?.officialArchive)}
        type="button"
      >
        {mutation === "archive" ? "正在归档" : "官方归档"}
      </button>
      <button
        disabled={busy || unarchive.eligible.length === 0 || unarchive.blocked.length > 0
          || !capabilityAvailable(capabilities?.officialUnarchive)}
        onClick={onUnarchive}
        title={buttonReason(unarchive.reason, capabilities?.officialUnarchive)}
        type="button"
      >
        {mutation === "unarchive" ? "正在恢复" : "恢复到 Codex"}
      </button>
      <button
        disabled={busy || recovery.eligible.length === 0 || recovery.blocked.length > 0
          || !capabilityAvailable(capabilities?.recoveryArchive)}
        onClick={onCreateRecovery}
        title={buttonReason(recovery.reason, capabilities?.recoveryArchive)}
        type="button"
      >
        {mutation === "recoveryArchive" ? "正在压缩" : "创建深度压缩恢复包"}
      </button>
      <button
        className="is-danger"
        disabled={busy || deletion.eligible.length === 0 || deletion.blocked.length > 0
          || !capabilityAvailable(capabilities?.officialDelete)
          || !deleteWithRecoveryAvailable}
        onClick={onDelete}
        title={buttonReason(
          deletion.reason ?? (!deleteWithRecoveryAvailable ? deleteWithRecoveryReason : null),
          capabilities?.officialDelete,
        )}
        type="button"
      >
        {preparingDelete
          ? "正在冻结确认"
          : mutation === "delete"
            ? "正在备份并删除"
            : "恢复包后删除"}
      </button>
    </div>
  );
}

function DetailHeader({ thread }: { thread: SessionManagementThread }) {
  return (
    <header className="session-management-detail-head">
      <div>
        <strong>{thread.title || "未命名会话"}</strong>
        <span title={thread.cwd}>{thread.cwd || "未知项目"}</span>
      </div>
      <span className={`session-management-status session-management-status--${statusTone(thread)}`}>
        {statusLabel(thread)}
      </span>
    </header>
  );
}

function OverviewPanel({
  catalog,
  thread,
}: {
  catalog: SessionManagementCatalog | null;
  thread: SessionManagementThread;
}) {
  const capabilities = catalog?.capabilities;
  return (
    <div className="session-management-overview">
      <DefinitionGroup title="会话">
        <Definition label="会话 ID" value={thread.id} copyable />
        <Definition label="身份" value={thread.isSubagent ? "Subagent" : thread.forkedFromId ? "Fork 分支" : "主会话"} />
        <Definition label="状态" value={statusLabel(thread)} />
        <Definition label="模型" value={thread.model || "未知"} />
        <Definition label="来源" value={thread.source || "未知"} />
      </DefinitionGroup>
      <DefinitionGroup title="时间与磁盘">
        <Definition label="创建" value={formatSessionTimestamp(thread.createdAt)} />
        <Definition label="最后活动" value={formatSessionTimestamp(thread.recencyAt ?? thread.updatedAt)} />
        <Definition label="文件修改" value={formatSessionTimestamp(thread.fileModifiedAt)} />
        <Definition label="文件大小" value={formatSessionBytes(thread.fileBytes)} />
        <Definition label="Token 元数据" value={thread.tokensUsed?.toLocaleString("zh-CN") ?? "—"} />
      </DefinitionGroup>
      <DefinitionGroup title="谱系">
        <Definition label="Session Tree" value={thread.sessionId || "未知"} />
        <Definition label="Fork 来源" value={thread.forkedFromId || "无"} />
        <Definition label="Subagent 父会话" value={thread.parentThreadId || "无"} />
        <Definition label="子分支 / Subagent" value={`${thread.forkChildCount} / ${thread.spawnChildCount}`} />
      </DefinitionGroup>
      {thread.similarityReason ? (
        <section className="session-management-detail-note">
          <strong>可能相似</strong>
          <span>{thread.similarityReason}</span>
          <p>这是本地指纹生成的候选，不代表重复，也不会自动删除。</p>
        </section>
      ) : null}
      {thread.protectionReasons.length > 0 ? (
        <section className="session-management-detail-note session-management-detail-note--protected">
          <strong>受保护，危险操作已禁用</strong>
          <ul>{thread.protectionReasons.map((reason) => <li key={reason}>{reason}</li>)}</ul>
        </section>
      ) : null}
      <section className="session-management-recovery-card">
        <header>
          <strong>深度压缩恢复包</strong>
          <span>Token Bar 恢复材料，与 Codex 官方归档分开。</span>
        </header>
        <div>
          <button
            disabled
            title={capabilityReason(capabilities?.recoveryRestore) ?? "本版本暂不支持安全恢复"}
            type="button"
          >
            从恢复包还原
          </button>
          <button
            disabled
            title={capabilityReason(capabilities?.recoveryReclaim) ?? "本版本暂不支持安全释放空间"}
            type="button"
          >
            压缩后释放空间
          </button>
        </div>
        <p>
          {capabilityReason(capabilities?.recoveryRestore)
            ?? capabilityReason(capabilities?.recoveryReclaim)
            ?? "本轮只开放创建、校验和导出恢复包，不会删除原会话。"}
        </p>
      </section>
    </div>
  );
}

function DefinitionGroup({ children, title }: { children: React.ReactNode; title: string }) {
  return (
    <section className="session-management-definition-group">
      <h2>{title}</h2>
      <dl>{children}</dl>
    </section>
  );
}

function Definition({
  copyable = false,
  label,
  value,
}: {
  copyable?: boolean;
  label: string;
  value: string;
}) {
  const [copied, setCopied] = useState(false);
  return (
    <div>
      <dt>{label}</dt>
      <dd title={value}>{value}</dd>
      {copyable ? (
        <button
          aria-label={`复制${label}`}
          onClick={() => {
            void navigator.clipboard?.writeText(value).then(() => {
              setCopied(true);
              window.setTimeout(() => setCopied(false), 1_200);
            });
          }}
          type="button"
        >
          {copied ? "已复制" : "复制"}
        </button>
      ) : null}
    </div>
  );
}

function ContextPanel({
  context,
  onLoadOlder,
  onRetry,
}: {
  context: ContextState;
  onLoadOlder: () => void;
  onRetry: () => void;
}) {
  return (
    <div className="session-management-context">
      {context.fileIdentity ? (
        <div className="session-management-context-source" title={context.fileIdentity}>
          当前文件身份：{context.fileIdentity}
        </div>
      ) : null}
      {context.warnings.length > 0 ? (
        <details className="session-management-context-warnings">
          <summary>{context.warnings.length} 条上下文读取提醒</summary>
          <ul>{context.warnings.map((warning) => <li key={warning}>{warning}</li>)}</ul>
        </details>
      ) : null}
      {context.error ? (
        <div className="session-management-context-error" role="alert">
          <strong>上下文读取失败</strong>
          <span>{context.error}</span>
          <button onClick={onRetry} type="button">重试</button>
        </div>
      ) : null}
      {context.loading && context.messages.length === 0 ? (
        <WorkspaceLoading label="正在读取所选会话上下文" />
      ) : (
        <>
          {context.hasMoreBefore ? (
            <button
              className="session-management-load-older"
              disabled={context.loading}
              onClick={onLoadOlder}
              type="button"
            >
              {context.loading ? "正在读取更早内容" : "加载更早上下文"}
            </button>
          ) : null}
          {context.messages.length === 0 && !context.loading && !context.error ? (
            <div className="session-management-context-empty">这个会话没有可显示的上下文消息。</div>
          ) : context.messages.map((message) => (
            <article
              className={`session-management-message session-management-message--${messageTone(message.role)}`}
              key={`${message.offset}:${message.id}`}
            >
              <header>
                <strong>{roleLabel(message.role)}</strong>
                <span>{message.kind}{message.timestamp ? ` · ${formatSessionTimestamp(message.timestamp)}` : ""}</span>
              </header>
              <pre>{message.content || "（空内容）"}</pre>
            </article>
          ))}
        </>
      )}
    </div>
  );
}

function LineagePanel({
  onSelect,
  relations,
  thread,
}: {
  onSelect: (thread: SessionManagementThread) => void;
  relations: ReturnType<typeof relatedThreads>;
  thread: SessionManagementThread;
}) {
  return (
    <div className="session-management-lineage">
      <RelatedGroup
        empty="没有可读取的 Fork 来源"
        onSelect={onSelect}
        threads={relations.forkParent ? [relations.forkParent] : []}
        title="Fork 来源"
      />
      <RelatedGroup
        empty={thread.forkChildCount > 0 ? "后端记录了子分支，但本次目录未返回其详情" : "没有子分支"}
        onSelect={onSelect}
        threads={relations.forkChildren}
        title="Fork 子分支"
      />
      <RelatedGroup
        empty="没有 Subagent 父会话"
        onSelect={onSelect}
        threads={relations.subagentParent ? [relations.subagentParent] : []}
        title="Subagent 父会话"
      />
      <RelatedGroup
        empty={thread.spawnChildCount > 0 ? "后端记录了 Subagent，但本次目录未返回其详情" : "没有 Subagent"}
        onSelect={onSelect}
        threads={relations.subagents}
        title="Subagent"
      />
      <RelatedGroup
        empty="没有本地指纹相似候选"
        onSelect={onSelect}
        threads={relations.similar}
        title="可能相似"
      />
      {thread.similarityReason ? (
        <p className="session-management-lineage-note">
          匹配依据：{thread.similarityReason}。候选只供人工比较，不自动视为重复。
        </p>
      ) : null}
    </div>
  );
}

function RelatedGroup({
  empty,
  onSelect,
  threads,
  title,
}: {
  empty: string;
  onSelect: (thread: SessionManagementThread) => void;
  threads: SessionManagementThread[];
  title: string;
}) {
  return (
    <section className="session-management-related-group">
      <h2>{title}<span>{threads.length}</span></h2>
      {threads.length === 0 ? <p>{empty}</p> : threads.map((thread) => (
        <button key={thread.id} onClick={() => onSelect(thread)} type="button">
          <span><strong>{thread.title || "未命名会话"}</strong><em>{projectLabel(thread.cwd)}</em></span>
          <b>{formatSessionBytes(thread.fileBytes)}</b>
        </button>
      ))}
    </section>
  );
}

function DeleteConfirmation({
  canCreateRecovery,
  confirmed,
  onCancel,
  onConfirm,
  onConfirmedChange,
  recoveryReason,
  impact,
}: {
  canCreateRecovery: boolean;
  confirmed: boolean;
  onCancel: () => void;
  onConfirm: () => void;
  onConfirmedChange: (confirmed: boolean) => void;
  recoveryReason: string;
  impact: SessionDeletionImpact;
}) {
  const affectedBlocked = impact.blockedAffected.length > 0;
  const dialogRef = useRef<HTMLElement>(null);
  const cancelButtonRef = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    const previousFocus = document.activeElement instanceof HTMLElement
      ? document.activeElement
      : null;
    window.requestAnimationFrame(() => cancelButtonRef.current?.focus());
    return () => previousFocus?.focus();
  }, []);

  return (
    <div className="session-management-confirm-overlay">
      <section
        aria-describedby="session-management-delete-description"
        aria-labelledby="session-management-delete-title"
        aria-modal="true"
        className="session-management-confirm"
        onKeyDown={(event) => {
          if (event.key !== "Tab") return;
          const focusable = [...(dialogRef.current?.querySelectorAll<HTMLElement>(
            "button:not(:disabled), input:not(:disabled), [tabindex]:not([tabindex=\"-1\"])",
          ) ?? [])];
          if (focusable.length === 0) return;
          const currentIndex = focusable.indexOf(document.activeElement as HTMLElement);
          if (event.shiftKey && currentIndex <= 0) {
            event.preventDefault();
            focusable.at(-1)?.focus();
          } else if (!event.shiftKey && currentIndex === focusable.length - 1) {
            event.preventDefault();
            focusable[0]?.focus();
          }
        }}
        ref={dialogRef}
        role="alertdialog"
      >
        <header>
          <strong id="session-management-delete-title">
            创建完整恢复包后永久删除 {impact.affected.length} 个会话？
          </strong>
          <span id="session-management-delete-description">
            勾选 {impact.requested.length} 个，归并为 {impact.effectiveRoots.length} 个删除根；
            另含 {impact.indirectDescendants.length} 个 spawned 后代，文件合计
            {" "}{formatSessionBytes(impact.totalBytes)}。Token Bar 会先逐个创建并完整校验恢复包，
            全部通过后才调用 Codex 官方永久删除命令。
          </span>
        </header>
        <dl className="session-management-delete-impact">
          <div><dt>实际影响</dt><dd>{impact.affected.length} 个会话</dd></div>
          <div><dt>间接后代</dt><dd>{impact.indirectDescendants.length} 个</dd></div>
          <div><dt>外部 Fork 引用</dt><dd>{impact.externalForkReferences.length} 个（不会递归删除）</dd></div>
          <div><dt>总文件大小</dt><dd>{formatSessionBytes(impact.totalBytes)}</dd></div>
        </dl>
        <details className="session-management-delete-scope">
          <summary>核对完整影响范围（{impact.affected.length}）</summary>
          <ul>
            {impact.affected.map((thread) => (
              <li key={thread.id}>
                <strong>{thread.title || "未命名会话"}</strong>
                <span>{thread.id} · {formatSessionBytes(thread.fileBytes)}</span>
              </li>
            ))}
          </ul>
        </details>
        {affectedBlocked ? (
          <p className="session-management-delete-blocked" role="alert">
            {impact.blockedAffected.length} 个受影响会话正在运行、加载或受保护；本次删除已安全关闭。
          </p>
        ) : null}
        <div className="session-management-delete-options" aria-label="强制删除前恢复策略">
          <div className={`session-management-delete-required${canCreateRecovery ? "" : " is-disabled"}`}>
            <span>
              <strong>完整恢复包是永久删除的强制前置条件</strong>
              <em>
                {canCreateRecovery
                  ? `将为全部 ${impact.affected.length} 个受影响会话创建恢复包，并在每个删除根执行前再次核验。`
                  : recoveryReason}
              </em>
            </span>
          </div>
        </div>
        <label className="session-management-delete-acknowledgement">
          <input
            checked={confirmed}
            onChange={(event) => onConfirmedChange(event.currentTarget.checked)}
            type="checkbox"
          />
          <span>我已核对完整影响范围，确认先创建并验证全部恢复包，再执行永久删除。</span>
        </label>
        <div className="session-management-confirm-actions">
          <button onClick={onCancel} ref={cancelButtonRef} type="button">取消</button>
          <button
            className="is-danger"
            disabled={!confirmed || !canCreateRecovery || affectedBlocked}
            onClick={onConfirm}
            type="button"
          >
            确认删除
          </button>
        </div>
      </section>
    </div>
  );
}

function MutationReport({ report }: { report: SessionMutationBatchResult }) {
  const succeeded = report.results.filter((entry) => entry.ok);
  const failed = report.results.filter((entry) => !entry.ok);
  return (
    <details
      className={`session-management-banner${failed.length > 0 ? " session-management-banner--warning" : " session-management-banner--success"}`}
      open={failed.length > 0}
    >
      <summary>
        操作完成：成功 {succeeded.length}，失败 {failed.length}
        {report.warnings.length > 0 ? `，另有 ${report.warnings.length} 条提醒` : ""}
      </summary>
      <ul>
        {failed.map((entry) => (
          <li key={entry.threadId}>{entry.threadId}：{entry.message || "未知错误"}</li>
        ))}
        {succeeded
          .filter((entry) => entry.recoveryArchivePath)
          .map((entry) => (
            <li key={entry.threadId}>
              {entry.threadId}：恢复包已创建于 {entry.recoveryArchivePath}
            </li>
          ))}
        {report.warnings.map((warning) => <li key={warning}>{warning}</li>)}
      </ul>
    </details>
  );
}

function reconcileMutationReport(
  mutation: SessionManagementMutation,
  report: SessionMutationBatchResult,
  catalog: SessionManagementCatalog,
  deleteAffectedIds: readonly string[],
): SessionMutationBatchResult {
  if (mutation === "recoveryArchive") return report;
  const byId = new Map(catalog.threads.map((thread) => [thread.id, thread]));
  const diagnostics: string[] = [];
  if (mutation === "delete") {
    const remainingAffectedIds = deleteAffectedIds.filter((threadId) => byId.has(threadId));
    if (remainingAffectedIds.length > 0) {
      diagnostics.push(
        `刷新目录仍显示删除影响范围中的 ${remainingAffectedIds.length} 个会话（${remainingAffectedIds.join("、")}）；目录仅供诊断，操作结果仍以后端回执为准。`,
      );
    } else if (report.results.some((entry) => !entry.ok)) {
      diagnostics.push(
        "刷新目录暂未显示删除影响范围，但目录可能来自降级数据；后端失败或不确定回执保持不变。",
      );
    }
  }
  for (const entry of report.results) {
    if (mutation === "delete") continue;
    const current = byId.get(entry.threadId);
    const catalogLooksComplete = mutation === "archive"
      ? current?.archived === true
      : current !== undefined && !current.archived;
    if (!entry.ok && catalogLooksComplete) {
      diagnostics.push(
        `${entry.threadId}：刷新目录看似已达到目标状态，但目录可能来自降级数据；后端失败或不确定回执保持不变。`,
      );
    } else if (entry.ok && !catalogLooksComplete) {
      diagnostics.push(
        `${entry.threadId}：后端返回成功，但刷新目录尚未显示目标状态；目录仅供诊断。`,
      );
    }
  }
  return {
    ...report,
    // The backend receipt is authoritative. A catalog refresh can be partial or
    // degraded, so it may add diagnostics but can never promote or demote an
    // item result.
    results: report.results,
    warnings: [...new Set([...report.warnings, ...diagnostics])],
  };
}

function WorkspaceLoading({ label = "正在读取完整会话目录" }: { label?: string }) {
  return (
    <div className="session-management-loading" aria-live="polite">
      <span aria-hidden="true" />
      <strong>{label}</strong>
      <p>界面已经可用；本地元数据会在后台逐步返回。</p>
    </div>
  );
}

function WorkspaceEmpty({
  collection,
  query,
}: {
  collection: SessionCollectionId;
  query: string;
}) {
  return (
    <div className="session-management-empty">
      <strong>{query.trim() ? "没有匹配的会话" : "这个集合目前为空"}</strong>
      <span>
        {query.trim()
          ? "搜索作用于后端返回的完整元数据目录，可以尝试标题、项目路径、会话 ID 或模型。"
          : collection === "subagents"
            ? "Subagent 不会混进普通项目列表；发现后会集中显示在这里。"
            : "刷新后仍为空时，可查看目录读取提醒。"}
      </span>
    </div>
  );
}

function capabilityAvailable(capability: SessionManagementCapability | undefined): boolean {
  return capability?.available === true;
}

function capabilityReason(capability: SessionManagementCapability | undefined): string | null {
  return capability?.reason?.trim() || null;
}

function buttonReason(
  eligibilityReason: string | null,
  capability: SessionManagementCapability | undefined,
): string | undefined {
  return eligibilityReason
    ?? capabilityReason(capability)
    ?? (capabilityAvailable(capability) ? undefined : "当前后端未开放此能力");
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function sameOrderedIds(left: readonly string[], right: readonly string[]): boolean {
  return left.length === right.length
    && left.every((value, index) => value === right[index]);
}

function statusLabel(thread: SessionManagementThread): string {
  const normalized = thread.status.toLocaleLowerCase().replace(/[^a-z]/g, "");
  const status = normalized === "notloaded"
    ? "未加载"
    : normalized.includes("active") || normalized.includes("running")
      ? "运行中"
      : normalized.includes("loaded")
        ? "已加载"
        : normalized.includes("error")
          ? "系统错误"
          : normalized.includes("idle")
            ? "空闲"
            : thread.status || "未知";
  return thread.archived ? `官方归档 · ${status}` : status;
}

function statusTone(thread: SessionManagementThread): string {
  const normalized = thread.status.toLocaleLowerCase().replace(/[^a-z]/g, "");
  if (normalized.includes("active") || normalized.includes("running") || normalized.includes("loaded")) {
    return "active";
  }
  if (normalized.includes("error")) return "error";
  if (thread.archived) return "archived";
  return "idle";
}

function roleLabel(role: string): string {
  const normalized = role.toLocaleLowerCase();
  if (normalized.includes("user")) return "用户";
  if (normalized.includes("assistant")) return "Codex";
  if (normalized.includes("tool")) return "工具";
  if (normalized.includes("system")) return "系统";
  return role || "消息";
}

function messageTone(role: string): string {
  const normalized = role.toLocaleLowerCase();
  if (normalized.includes("user")) return "user";
  if (normalized.includes("assistant")) return "assistant";
  if (normalized.includes("tool")) return "tool";
  return "system";
}
