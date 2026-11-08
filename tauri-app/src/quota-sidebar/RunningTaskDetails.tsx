import { modelUsageLabel as shortModelName } from "../components/modelUsagePresentation";
import { modelUsageColor } from "../components/modelUsagePresentation";
import { useSpeedPalette } from "../components/liveRate/useSpeedPalette";
import { taskClientLabel, type TaskDetailMember, type TaskDetailSummary } from "./runningTaskPresentation";

/** Compact hierarchy shared by every selected client; no source I/O in render. */
export function RunningTaskDetails({ running }: { running: TaskDetailSummary }) {
  useSpeedPalette();
  const hasCounts = running.status === "ready" || running.status === "stale";
  const partial = Boolean(running.sourceIssues?.length);
  const members=[...running.groups.flatMap(g=>[g.mainThread,...g.subagents]),...running.unassignedSubagents];
  const showClient=new Set(members.map(m=>m.client??'codex')).size>1;
  return <>
    <div className="qs-task-totals" aria-label="运行任务合计">
      <span>主任务 <strong>{hasCounts ? running.mainThreads ?? "未知" : "未知"}</strong></span>
      <span>子代理 <strong>{hasCounts ? running.subagents ?? "未知" : "未知"}</strong></span>
    </div>
    {partial && <p className="qs-warning" role="status">{running.sourceIssues!.join("；")}。合计仅包含已读到的任务。</p>}
    {running.status !== "ready" && <p className="qs-warning">{running.status === "stale" ? "运行快照已过期" : running.status === "scanning" ? "正在读取运行任务…" : "运行状态尚不可用"}</p>}
    {hasCounts && running.groups.map(group => <section className="qs-task-group" key={group.mainThread.threadId} data-task-source={group.mainThread.client}>
      <div className="qs-main-task">
        <h4 className="qs-task-title" title={taskDetail(group.mainThread)}>{taskTitle(group.mainThread)}</h4>
        <div className="qs-task-heading">
          <TaskMetadata member={group.mainThread}/>
          <span className="qs-task-tail">{showClient&&<TaskSource member={group.mainThread}/>} {group.subagents.length>0&&<span>{group.subagents.length} 子代理</span>}</span>
        </div>
      </div>
      {group.subagents.length > 0 && <div className="qs-child-tasks">
        {group.subagents.map(member => <ChildTask key={member.threadId} member={member}/>)}
      </div>}
    </section>)}
    {hasCounts && running.unassignedSubagents.length > 0 && <section className="qs-unassigned-tasks">
      <div className="qs-task-heading"><strong>未关联主任务</strong><span>{running.unassignedSubagents.length} 个子代理</span></div>
      <p className="qs-muted">未获得可靠的主任务关联。</p>
      {running.unassignedSubagents.map(member => <ChildTask key={member.threadId} member={member}/>)}
    </section>}
    {running.status === "ready" && running.total === 0 && <p className="qs-empty">{partial ? "已读到的来源当前没有运行任务；其余来源待核验。" : "当前没有运行中的会话"}</p>}
    {hasCounts && (running.total ?? 0) > 0 && !running.groups.length && !running.unassignedSubagents.length && <p className="qs-muted">已读取运行数量，尚无任务层级明细</p>}
    {running.detail && <details className="qs-diagnostic"><summary>运行状态说明</summary><p>{running.detail}</p></details>}
  </>;
}

function TaskSource({ member }: { member: TaskDetailMember }) {
  return member.client ? <span className="qs-task-source">{taskClientLabel(member.client)}</span> : null;
}

function taskTitle(member:TaskDetailMember,child=false):string {
  const title=member.title?.split(/\r?\n/).map(s=>s.trim().replace(/^#+\s*/,'' )).find(Boolean);
  if(title)return title;
  let id=member.threadId;
  try{const parts=JSON.parse(id);if(Array.isArray(parts)&&typeof parts[1]==='string')id=parts[1];}catch{/* plain Codex ID */}
  return `${child?'子代理':'任务'} · ${(id.split(':').at(-1)??id).slice(0,8)}`;
}
function phase(member:TaskDetailMember){return member.phase==='generating'?'生成中':member.phase==='tools'?'工具':null;}
function taskDetail(member:TaskDetailMember,child=false){
  return [taskTitle(member,child),shortModelName(member.model),member.reasoningEffort||'未提供推理强度',phase(member),taskClientLabel(member.client??'codex')].filter(Boolean).join(' · ');
}
function TaskMetadata({member}:{member:TaskDetailMember}){
  return <div className="qs-task-metadata" title={taskDetail(member)}>
    <i className="qs-task-model-dot" style={{backgroundColor:modelUsageColor(member.model??'unknown')}}/>
    <strong className="qs-task-model" style={{color:modelUsageColor(member.model??'unknown')}}>{shortModelName(member.model)}</strong>
    <span className="qs-task-effort">{member.reasoningEffort||phase(member)||'—'}</span>
  </div>;
}
function ChildTask({member}:{member:TaskDetailMember}){
  return <section className="qs-child-task" data-task-source={member.client} title={taskDetail(member,true)} aria-label={'子代理 · '+taskDetail(member,true)}>
    <span className="qs-task-branch" aria-hidden="true">↳</span>
    <span className="qs-task-title" title={taskTitle(member,true)}>{taskTitle(member,true)}</span>
    <TaskMetadata member={member}/>
  </section>;
}
