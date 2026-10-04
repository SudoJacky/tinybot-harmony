import { t } from '../model/I18n';
import { teamWorkerInstructions } from '../model/SystemPrompt';
import { ModelMessage, ToolCall, ToolDefinition } from '../model/Agent';
import { ModelConfig } from '../model/Conversation';
import { TeamAttempt, TeamRun, TeamTaskRecord, lastAttempt, teamPlan, validateTeamPlan } from '../model/Team';
import { AgentTools } from './AgentLoop';
import { AgentRuntime } from './AgentRuntime';
import { Cancellation } from './Cancellation';
import { UsageOrigin } from '../model/Usage';
interface TeamEvidence { taskId: string; title: string; output: string; }

// Parallel model requests share a serialized tool lane: file mutations and approval dialogs never overlap.
export class TeamToolLane {
  private tail: Promise<void> = Promise.resolve();
  execute(tools: AgentTools, call: ToolCall, cancellation: Cancellation): Promise<string> {
    const work = this.tail.then(() => { cancellation.check(); return tools.execute(call, cancellation); });
    this.tail = work.then(() => {}, () => {}); return work;
  }
}
export class TeamTools implements AgentTools {
  private inner: AgentTools; private lane: TeamToolLane;
  constructor(inner: AgentTools, lane: TeamToolLane) { this.inner = inner; this.lane = lane; }
  definitions(): ToolDefinition[] { return this.inner.definitions(); }
  execute(call: ToolCall, cancellation: Cancellation): Promise<string> { return this.lane.execute(this.inner, call, cancellation); }
}
export interface TeamExecution {
  usageOrigin?: UsageOrigin;
  runtime: () => AgentRuntime; tools: (record: TeamTaskRecord, attempt: TeamAttempt) => AgentTools; config: ModelConfig;
  complete?: (record: TeamTaskRecord, attempt: TeamAttempt) => void;
  lane?: TeamToolLane;
  createId: () => string; checkpoint: () => Promise<void>; changed: () => void;
}
export class TeamCoordinator {
  private workers: Map<string, AgentRuntime> = new Map<string, AgentRuntime>();
  private paused: boolean = false;
  private stopped: boolean = false;
  private executing: boolean = false;
  private closing: boolean = false;
  private updates: number = 0;
  private updateListeners: Set<() => void> = new Set<() => void>();
  get accepting(): boolean { return this.executing && !this.closing && !this.stopped && !this.paused; }
  holdDispatch(): () => void {
    if (!this.accepting) { throw new Error(t("调度器正在收尾，请等待后再追加。")); }
    this.updates++;
    return () => { this.updates--; this.updateListeners.forEach((notify) => notify()); this.updateListeners.clear(); };
  }
  pause(): void { this.paused = true; }
  stop(): void { this.stopped = true; this.workers.forEach((runtime) => runtime.abort()); }
  async execute(run: TeamRun, execution: TeamExecution): Promise<void> {
    if (this.executing) { throw new Error(t("团队正在执行。")); }
    validateTeamPlan(teamPlan(run), run.members, run.ownerMessageId !== undefined);
    if (run.tasks.some((record) => ['failed', 'cancelled', 'interrupted', 'running'].includes(record.status))) { throw new Error(t("请先检查并重试失败或中断的任务。")); }
    if (run.tasks.every((record) => record.status === 'succeeded')) { throw new Error(t("团队已完成。")); }
    this.executing = true; this.closing = false; this.paused = false; this.stopped = false;
    const pending = new Map<string, Promise<void>>(); const members = new Set<string>(); const lane = execution.lane || new TeamToolLane();
    let failure = '';
    run.status = 'running'; run.error = ''; run.revision++; execution.changed();
    try {
      await execution.checkpoint();
      while (true) {
        if (this.updates > 0) { await new Promise<void>((resolve) => { this.updateListeners.add(resolve); }); continue; }
        if (!this.paused && !this.stopped && !failure) {
          for (const record of run.tasks) {
            if (pending.size >= run.concurrency) { break; }
            if (record.status !== 'pending' || members.has(record.task.memberId) ||
              !record.task.dependencies.every((id) => run.tasks.find((item) => item.task.id === id)?.status === 'succeeded')) { continue; }
            members.add(record.task.memberId);
            const work = this.attempt(run, record, execution, lane).catch((error: Error) => {
              failure = error.message; this.stop();
            }).finally(() => { members.delete(record.task.memberId); pending.delete(record.task.id); });
            pending.set(record.task.id, work);
          }
        }
        if (!pending.size) { break; }
        await Promise.race(Array.from(pending.values()));
      }
      this.closing = true;
      run.status = failure ? 'failed' : this.stopped ? 'cancelled' : run.tasks.every((record) => record.status === 'succeeded') ? 'completed' : 'paused';
      run.error = failure;
    } catch (error) { this.stop(); await Promise.all(Array.from(pending.values())); run.status = 'failed'; run.error = (error as Error).message; }
    finally {
      this.executing = false; run.revision++; execution.changed(); await execution.checkpoint();
    }
  }
  private async attempt(run: TeamRun, record: TeamTaskRecord, execution: TeamExecution, lane: TeamToolLane): Promise<void> {
    const runtime = execution.runtime(); this.workers.set(record.task.id, runtime);
    const attempt: TeamAttempt = { id: execution.createId(), status: 'running', startedAt: Date.now(), error: '', turn: { content: '', steps: [] } };
    record.attempts.push(attempt); record.status = 'running'; run.revision++;
    const member = run.members.find((item) => item.id === record.task.memberId);
    const evidence = record.task.dependencies.map((id): TeamEvidence => {
      const source = run.tasks.find((item) => item.task.id === id) as TeamTaskRecord;
      return { taskId: id, title: source.task.title, output: lastAttempt(source)?.handoff?.summary || lastAttempt(source)?.turn.content || '' };
    });
    const messages: ModelMessage[] = [
      { role: 'system', content: execution.config.systemPrompt + '\n你是团队成员 ' + member?.name + '（' + member?.id + '）。职责：' + member?.instructions +
        teamWorkerInstructions(!!run.ownerMessageId) },
      { role: 'user', content: JSON.stringify({ goal: run.goal, teamMembers: run.members, task: record.task, dependencyResults: evidence }) }
    ];
    let lastTextUpdate = 0;
    const unsubscribe = runtime.subscribe((event) => {
      attempt.turn = event.run.turn;
      if (!['text_delta', 'reasoning_delta'].includes(event.type) || Date.now() - lastTextUpdate >= 100) { lastTextUpdate = Date.now(); execution.changed(); }
    });
    try {
      await execution.checkpoint();
      if (this.stopped) { record.status = 'cancelled'; attempt.status = 'cancelled'; return; }
      const result = await runtime.run({ sessionId: attempt.id, config: execution.config, messages: messages,
        usageOrigin: { threadId: execution.usageOrigin?.threadId, threadTitle: execution.usageOrigin?.threadTitle,
          turnId: execution.usageOrigin?.turnId, turnLabel: execution.usageOrigin?.turnLabel, skill: execution.usageOrigin?.skill,
          purpose: 'team_task', teamId: run.id, taskId: record.task.id, taskTitle: record.task.title,
          memberName: member?.name, attemptId: attempt.id, attempt: record.attempts.length },
        tools: new TeamTools(execution.tools(record, attempt), lane) }, { prepare: async () => {}, checkpoint: execution.checkpoint });
      attempt.turn = result.turn; attempt.status = result.status === 'complete' ? 'succeeded' : result.status === 'stopped' ? 'cancelled' : 'failed';
      attempt.error = result.error; record.status = attempt.status;
      if (attempt.status === 'succeeded') { execution.complete?.(record, attempt); }
      if (attempt.status === 'failed' || (attempt.status === 'cancelled' && !this.stopped)) { throw new Error(record.task.title + '：' + (result.error || t("任务中断"))); }
    } catch (error) { attempt.status = 'failed'; record.status = 'failed'; attempt.error = (error as Error).message; throw new Error(attempt.error); }
    finally {
      attempt.finishedAt = Date.now(); run.revision++; unsubscribe(); this.workers.delete(record.task.id); execution.changed(); await execution.checkpoint();
    }
  }
}
