import { modelUsageLabel as shortModelName } from "../components/modelUsagePresentation";
import { modelUsageColor } from "../components/modelUsagePresentation";
import { useSpeedPalette } from "../components/liveRate/useSpeedPalette";
import { taskClientLabel, type TaskDetailMember, type TaskDetailSummary } from "./runningTaskPresentation";

/** Existing task cards shared by every selected client. */
export function RunningTaskDetails({ running }: { running: TaskDetailSummary }) {
  useSpeedPalette();
  const hasCounts = running.status === "ready" || running.status === "stale";
  const partial = Boolean(running.sourceIssues?.length);
  return <>
    <div className="qs-task-totals" aria-label="运行任务合计">
      <span>主任务 <strong>{hasCounts ? running.mainThreads ?? "未知" : "未知"}</strong></span>
      <span>子代理 <strong>{hasCounts ? running.subagents ?? "未知" : "未知"}</strong></span>
    </div>
    {partial && <p className="qs-warning" role="status">{running.sourceIssues!.join("；")}。合计仅包含已读到的任务。</p>}
    {running.status !== "ready" && <p className="qs-warning">{running.status === "stale" ? "运行快照已过期" : running.status === "scanning" ? "正在读取运行任务…" : "运行状态尚不可用"}</p>}
    {hasCounts && running.groups.map(group => <section className="qs-task-group" key={group.mainThread.threadId} data-task-source={group.mainThread.client}>
      <div className="qs-main-task">
        <div className="qs-task-heading">
          <div className="qs-task-badges"><span className="qs-role-label">主任务</span><TaskSource member={group.mainThread}/></div>
          <span>{group.subagents.length} 个子代理</span>
        </div>
        <TaskMember member={group.mainThread} fallbackTitle="未命名主任务" />
      </div>
      {group.subagents.length > 0 && <div className="qs-child-tasks">
        {group.subagents.map(member => <section className="qs-child-task" key={member.threadId}>
          <span className="qs-role-label qs-child-label">子代理</span>
          <TaskMember member={member} fallbackTitle="未命名子代理" />
        </section>)}
      </div>}
    </section>)}
    {hasCounts && running.unassignedSubagents.length > 0 && <section className="qs-unassigned-tasks">
      <div className="qs-task-heading"><strong>未关联主任务</strong><span>{running.unassignedSubagents.length} 个子代理</span></div>
      <p className="qs-muted">未获得可靠的主任务关联。</p>
      {running.unassignedSubagents.map(member => <section className="qs-child-task" key={member.threadId} data-task-source={member.client}>
        <div className="qs-task-badges"><span className="qs-role-label qs-child-label">子代理</span><TaskSource member={member}/></div>
        <TaskMember member={member} fallbackTitle="未命名子代理" />
      </section>)}
    </section>}
    {running.status === "ready" && running.total === 0 && <p className="qs-empty">{partial ? "已读到的来源当前没有运行任务；其余来源待核验。" : "当前没有运行中的会话"}</p>}
    {hasCounts && (running.total ?? 0) > 0 && !running.groups.length && !running.unassignedSubagents.length && <p className="qs-muted">已读取运行数量，尚无任务层级明细</p>}
    {running.detail && <details className="qs-diagnostic"><summary>运行状态说明</summary><p>{running.detail}</p></details>}
  </>;
}

function TaskSource({ member }: { member: TaskDetailMember }) {
  return member.client ? <span className="qs-task-source">{taskClientLabel(member.client)}</span> : null;
}

function TaskMember({ member, fallbackTitle }: { member: TaskDetailMember; fallbackTitle: string }) {
  const phase = member.phase === "generating" ? "生成中" : member.phase === "tools" ? "工具执行中" : null;
  return <>
    <h4 className="qs-task-title" title={member.title || fallbackTitle}>{member.title || fallbackTitle}</h4>
    <div className="qs-task-metadata">
      <div><span>模型</span><strong style={{color: modelUsageColor(member.model ?? "unknown")}}>{shortModelName(member.model)}</strong></div>
      <div><span>推理强度</span><strong>{member.reasoningEffort || "未知"}</strong></div>
      {phase && <div><span>状态</span><strong>{phase}</strong></div>}
    </div>
  </>;
}
