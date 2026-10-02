import { t } from './I18n';
import { AgentTurn, interruptTools, validateSteps } from './Agent';
import { ModelReference, validateReference } from './ProviderProfiles';

export interface TeamMember { id: string; name: string; instructions: string; toolProfile?: string; }
export interface TeamArtifact { path: string; content: string; }
export interface TeamHandoff { summary: string; unresolved: string[]; artifacts: TeamArtifact[]; sequence: number; }
export interface TeamTask { id: string; title: string; memberId: string; instructions: string; dependencies: string[]; }
export interface TeamPlan { tasks: TeamTask[]; finalTaskId: string; }
export interface TeamAttempt { id: string; status: string; startedAt: number; finishedAt?: number; error: string; turn: AgentTurn; handoff?: TeamHandoff; }
export interface TeamTaskRecord { task: TeamTask; status: string; attempts: TeamAttempt[]; }
export interface TeamRun {
  ownerMessageId?: string;
  sequence?: number;
  id: string; goal: string; members: TeamMember[]; concurrency: number; model: ModelReference;
  revision: number; status: string; error: string; createdAt: number;
  finalTaskId: string; tasks: TeamTaskRecord[]; planning: AgentTurn;
}
export function defaultTeamMembers(): TeamMember[] {
  return [{ id: 'researcher', name: '研究员', instructions: '查找资料，整理事实和出处，标出缺失信息。' },
    { id: 'analyst', name: '分析员', instructions: '分析证据、比较方案，指出风险与未解决问题。' },
    { id: 'editor', name: '编辑', instructions: '核对前置结果，汇总为清晰的最终交付物。' }];
}
function bounded(value: string, max: number): boolean { return typeof value === 'string' && value.trim().length > 0 && value.length <= max; }
function identifier(value: string): boolean { return typeof value === 'string' && /^[a-zA-Z0-9_-]{1,120}$/.test(value); }
export function validateTeamMembers(members: TeamMember[]): void {
  if (!Array.isArray(members) || members.length < 1 || members.length > 8) { throw new Error(t("团队需要 1 至 8 位成员。")); }
  const ids = new Set<string>();
  for (const member of members) {
    if (!member || !identifier(member.id) || ids.has(member.id) || !bounded(member.name, 60) || !bounded(member.instructions, 4000)) { throw new Error(t("成员 ID、名称或职责无效。")); }
    ids.add(member.id);
    if (member.toolProfile !== undefined && !['research', 'execution', 'review'].includes(member.toolProfile)) { throw new Error(t("员工工具权限无效。")); }
  }
}
export function validateTeamPlan(plan: TeamPlan, members: TeamMember[], chat: boolean = false): void {
  validateTeamMembers(members);
  if (!plan || !Array.isArray(plan.tasks) || plan.tasks.length < 1 || plan.tasks.length > 32) { throw new Error(t("计划需要 1 至 32 个任务。")); }
  const ids = new Set<string>();
  for (const task of plan.tasks) {
    if (!task || !identifier(task.id) || ids.has(task.id) || !bounded(task.title, 160) || !bounded(task.instructions, 8000) ||
      !members.some((member) => member.id === task.memberId) || !Array.isArray(task.dependencies) || task.dependencies.length > 32) { throw new Error(t("任务 ID、负责人、标题或指令无效。")); }
    ids.add(task.id);
  }
  for (const task of plan.tasks) {
    if (new Set(task.dependencies).size !== task.dependencies.length || task.dependencies.some((id) => !ids.has(id) || id === task.id)) { throw new Error(t("任务依赖不存在、重复或指向自身。")); }
  }
  if (!chat && !ids.has(plan.finalTaskId)) { throw new Error(t("请选择有效的最终任务。")); }
  if (chat && plan.finalTaskId !== '') { throw new Error(t("聊天团队由主 Agent 汇总，不设置最终员工。")); }
  const done = new Set<string>();
  while (done.size < plan.tasks.length) {
    const ready = plan.tasks.filter((task) => !done.has(task.id) && task.dependencies.every((id) => done.has(id)));
    if (!ready.length) { throw new Error(t("任务依赖存在循环。")); }
    ready.forEach((task) => done.add(task.id));
  }
  const connected = new Set<string>([plan.finalTaskId]);
  if (chat) { return; }
  for (let i = 0; i < plan.tasks.length; i++) {
    for (const task of plan.tasks) { if (connected.has(task.id)) { task.dependencies.forEach((id) => connected.add(id)); } }
  }
  if (connected.size !== plan.tasks.length) { throw new Error(t("所有任务必须通过依赖关系汇入最终任务。")); }
}
export function parseTeamPlan(text: string, members: TeamMember[]): TeamPlan {
  const clean = text.trim().replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, '');
  const plan = JSON.parse(clean) as TeamPlan; validateTeamPlan(plan, members); return plan;
}
export function teamPlan(run: TeamRun): TeamPlan { return { tasks: run.tasks.map((record) => record.task), finalTaskId: run.finalTaskId }; }
export function lastAttempt(record: TeamTaskRecord): TeamAttempt | undefined { return record.attempts[record.attempts.length - 1]; }
export function teamStatus(status: string): string {
  const names: Record<string, string> = { 'planned': t("待确认"), 'running': t("执行中"), 'paused': t("已暂停"), 'completed': t("已完成"), 'failed': t("失败"),
    'cancelled': t("已停止"), 'interrupted': t("已中断"), 'pending': t("等待执行"), 'succeeded': t("成功") };
  return names[status] || status;
}
export function recoverTeams(runs: TeamRun[]): void {
  if (!Array.isArray(runs)) { throw new Error(t("团队记录格式损坏。")); }
  const ids = new Set<string>();
  for (const run of runs) {
    if (!run || !identifier(run.id) || ids.has(run.id) || !bounded(run.goal, 12000) || !Number.isInteger(run.revision) || run.revision < 0 ||
      !Number.isInteger(run.concurrency) || run.concurrency < 1 || run.concurrency > 4 || !Array.isArray(run.tasks) ||
      !['planned', 'running', 'paused', 'completed', 'failed', 'cancelled', 'interrupted'].includes(run.status)) { throw new Error(t("团队记录损坏。")); }
    ids.add(run.id); validateReference(run.model); validateTeamPlan(teamPlan(run), run.members, run.ownerMessageId !== undefined);
    if (run.ownerMessageId !== undefined && (!identifier(run.ownerMessageId) || !Number.isInteger(run.sequence) || (run.sequence || 0) < 0)) { throw new Error(t("聊天团队归属无效。")); }
    if (!run.planning || typeof run.planning.content !== 'string') { throw new Error(t("规划记录损坏。")); }
    validateSteps(run.planning.steps);
    for (const record of run.tasks) {
      if (!Array.isArray(record.attempts) || !['pending', 'running', 'succeeded', 'failed', 'cancelled', 'interrupted'].includes(record.status)) { throw new Error(t("任务记录损坏。")); }
      for (const attempt of record.attempts) {
        if (!attempt || !identifier(attempt.id) || !attempt.turn || typeof attempt.turn.content !== 'string' ||
          !['running', 'succeeded', 'failed', 'cancelled', 'interrupted'].includes(attempt.status)) { throw new Error(t("任务执行记录损坏。")); }
        validateSteps(attempt.turn.steps); interruptTools(attempt.turn.steps);
        if (attempt.handoff) {
          const handoff = attempt.handoff;
          if (!bounded(handoff.summary, 12000) || !Array.isArray(handoff.unresolved) || handoff.unresolved.some((item) => !bounded(item, 2000)) ||
            !Array.isArray(handoff.artifacts) || handoff.artifacts.length > 8 || handoff.artifacts.some((item) => !item || !bounded(item.path, 1024) || typeof item.content !== 'string' || item.content.length > 65536) ||
            !Number.isInteger(handoff.sequence) || handoff.sequence < 1 || handoff.sequence > (run.sequence || 0)) { throw new Error(t("员工交接记录损坏。")); }
        }
        if (attempt.status === 'running') { attempt.status = 'interrupted'; attempt.error = '应用退出时执行尚未完成；检查文件后可手动重试。'; }
      }
      if (record.status === 'running') { record.status = 'interrupted'; }
      if (record.status === 'succeeded' && lastAttempt(record)?.status !== 'succeeded') { throw new Error(t("任务完成状态与记录不一致。")); }
    }
    if (run.status === 'running') { run.status = 'interrupted'; run.error = '应用退出，团队已中断，不会自动重放任务。'; run.revision++; }
    if (run.status === 'completed' && run.tasks.some((record) => record.status !== 'succeeded')) { throw new Error(t("团队完成状态与任务不一致。")); }
  }
}

export function teamCommand(text: string): string | undefined {
  const match = /^\s*(?:\/team|@team)(?:\s+|$)/i.exec(text);
  return match ? text.slice(match[0].length).trim() : undefined;
}
