import { describe, expect, it } from '@ohos/hypium';
import { ModelTurn, ToolCall, ToolDefinition } from '../main/ets/model/Agent';
import { defaultConfig } from '../main/ets/model/Conversation';
import { ProviderInfo } from '../main/ets/model/Provider';
import { TeamPlan, TeamRun, TeamTaskRecord, defaultTeamMembers, parseTeamPlan, recoverTeams, teamPlan, validateTeamPlan } from '../main/ets/model/Team';
import { AgentRuntime } from '../main/ets/services/AgentRuntime';
import { TeamCoordinator, TeamExecution, TeamToolLane } from '../main/ets/services/TeamCoordinator';
import { ToolSet } from '../main/ets/services/ToolSet';
import { AgentTools } from '../main/ets/services/AgentLoop';
import { Cancellation } from '../main/ets/services/Cancellation';
import { CredentialReader, ModelProvider, ProviderRequest } from '../main/ets/services/providers/Provider';
import { ProviderRegistry } from '../main/ets/services/providers/ProviderRegistry';

class Gate {
  private release: () => void = () => {};
  promise: Promise<void> = new Promise<void>((resolve) => { this.release = resolve; });
  open(): void { this.release(); }
}
class TeamKeys implements CredentialReader { async read(_alias: string): Promise<string> { return ''; } }
class BlockingTools implements AgentTools {
  entered: Gate = new Gate(); release: Gate = new Gate(); count: number = 0;
  definitions(): ToolDefinition[] { return []; }
  async execute(_call: ToolCall, _signal: Cancellation): Promise<string> { this.count++; this.entered.open(); await this.release.promise; return 'ok'; }
}
class TeamProvider implements ModelProvider {
  readonly info: ProviderInfo = { id: 'test', name: 'Test', protocol: 'test', defaultBaseUrl: 'https://example.com', defaultModel: 'model' };
  requests: ProviderRequest[] = [];
  respond: (request: ProviderRequest, signal: Cancellation) => Promise<string> = async () => '完成';
  endpoint(url: string): string { return url; }
  async stream(request: ProviderRequest, signal: Cancellation, onText: (text: string) => void): Promise<ModelTurn> {
    this.requests.push(request); const text = await this.respond(request, signal); signal.check(); onText(text);
    return { content: text, toolCalls: [] };
  }
}
function fixturePlan(): TeamPlan {
  return { tasks: [
    { id: 'a', title: '研究A', memberId: 'researcher', instructions: '收集A', dependencies: [] },
    { id: 'b', title: '分析B', memberId: 'analyst', instructions: '收集B', dependencies: [] },
    { id: 'final', title: '汇总', memberId: 'editor', instructions: '汇总A和B', dependencies: ['a', 'b'] }
  ], finalTaskId: 'final' };
}
function fixtureRun(): TeamRun {
  return { id: 'run1', goal: '测试目标', members: defaultTeamMembers(), concurrency: 2, model: { providerId: 'test', modelId: 'model' },
    revision: 0, status: 'planned', error: '', createdAt: 1, finalTaskId: 'final', planning: { content: '', steps: [] },
    tasks: fixturePlan().tasks.map((task): TeamTaskRecord => { return { task: task, status: 'pending', attempts: [] }; }) };
}
class Fixture {
  provider: TeamProvider = new TeamProvider();
  run: TeamRun = fixtureRun();
  coordinator: TeamCoordinator = new TeamCoordinator();
  options: TeamExecution;
  saves: string[] = [];
  constructor() {
    const registry = new ProviderRegistry(); registry.register(this.provider);
    const config = defaultConfig(); config.configured = true; config.providerId = 'test'; config.model = 'model';
    let sequence = 0;
    const keys = new TeamKeys();
    this.options = { runtime: () => new AgentRuntime(registry, keys), tools: () => new ToolSet([]), config: config,
      createId: () => 'attempt-' + ++sequence, checkpoint: async () => { this.saves.push(JSON.stringify(this.run)); }, changed: () => {} };
  }
  execute(): Promise<void> { return this.coordinator.execute(this.run, this.options); }
}
function rejectsPlan(plan: TeamPlan, fragment: string): void {
  let error = ''; try { validateTeamPlan(plan, defaultTeamMembers()); } catch (caught) { error = (caught as Error).message; }
  expect(error.includes(fragment)).assertTrue();
}

export default function teamTests(): void {
  describe('Teams', () => {
    it('validates_cycle_missing_owner_and_disconnected_plan', 0, () => {
      const cycle = fixturePlan(); cycle.tasks[0].dependencies = ['final']; rejectsPlan(cycle, '循环');
      const missing = fixturePlan(); missing.tasks[1].dependencies = ['missing']; rejectsPlan(missing, '依赖');
      const owner = fixturePlan(); owner.tasks[0].memberId = 'nobody'; rejectsPlan(owner, '负责人');
      const disconnected = fixturePlan(); disconnected.tasks[2].dependencies = ['a']; rejectsPlan(disconnected, '汇入');
    });
    it('parses_fenced_json_without_accepting_extra_prose', 0, () => {
      expect(parseTeamPlan('```json\n' + JSON.stringify(fixturePlan()) + '\n```', defaultTeamMembers()).tasks.length).assertEqual(3);
      let error = ''; try { parseTeamPlan('Here is your plan: ' + JSON.stringify(fixturePlan()), defaultTeamMembers()); } catch (caught) { error = (caught as Error).message; }
      expect(error.length > 0).assertTrue();
    });
    it('parallel_workers_wait_for_dependencies_and_receive_handoffs', 0, async () => {
      const f = new Fixture(); const entered = new Gate(); const release = new Gate(); let started = 0;
      f.provider.respond = async (request) => {
        started++; if (started <= 2) { if (started === 2) { entered.open(); } await release.promise; return '上游证据'; }
        expect(request.messages[1].content.includes('上游证据')).assertTrue(); return '最终报告';
      };
      const work = f.execute(); await entered.promise;
      expect(f.run.tasks[0].status).assertEqual('running'); expect(f.run.tasks[1].status).assertEqual('running'); expect(f.run.tasks[2].status).assertEqual('pending');
      release.open(); await work;
      expect(f.run.status).assertEqual('completed'); expect(f.run.tasks[2].attempts[0].turn.content).assertEqual('最终报告');
      expect(f.saves.length > 5).assertTrue();
    });
    it('one_member_never_runs_two_tasks_at_once', 0, async () => {
      const f = new Fixture(); f.run.tasks[1].task.memberId = 'researcher';
      let active = 0; let peak = 0;
      f.provider.respond = async () => { active++; peak = Math.max(peak, active); await Promise.resolve(); active--; return 'done'; };
      await f.execute(); expect(peak).assertEqual(1); expect(f.run.status).assertEqual('completed');
    });
    it('pause_drains_current_workers_and_resume_preserves_success', 0, async () => {
      const f = new Fixture(); const entered = new Gate(); const release = new Gate(); f.run.concurrency = 1;
      f.provider.respond = async () => { entered.open(); await release.promise; return 'done'; };
      const work = f.execute(); await entered.promise; f.coordinator.pause(); release.open(); await work;
      expect(f.run.status).assertEqual('paused'); expect(f.provider.requests.length).assertEqual(1);
      await f.execute(); expect(f.run.status).assertEqual('completed'); expect(f.run.tasks[0].attempts.length).assertEqual(1);
    });
    it('stop_cancels_active_and_does_not_start_dependents', 0, async () => {
      const f = new Fixture(); const entered = new Gate(); f.run.concurrency = 1;
      f.provider.respond = async (_request, signal) => { entered.open(); await new Promise<void>((resolve) => { signal.onCancel(resolve); }); signal.check(); return ''; };
      const work = f.execute(); await entered.promise; f.coordinator.stop(); await work;
      expect(f.run.status).assertEqual('cancelled'); expect(f.run.tasks[0].status).assertEqual('cancelled'); expect(f.run.tasks[2].attempts.length).assertEqual(0);
    });
    it('failure_blocks_dependencies_and_requires_explicit_retry', 0, async () => {
      const f = new Fixture(); f.run.concurrency = 1; f.provider.respond = async () => { throw new Error('offline'); };
      await f.execute(); expect(f.run.status).assertEqual('failed'); expect(f.run.tasks[2].attempts.length).assertEqual(0);
      let error = ''; try { await f.execute(); } catch (caught) { error = (caught as Error).message; }
      expect(error.includes('重试')).assertTrue();
      f.run.tasks[0].status = 'pending'; f.provider.respond = async () => 'recovered'; await f.execute();
      expect(f.run.tasks[0].attempts.length).assertEqual(2); expect(f.run.tasks[0].attempts[0].status).assertEqual('failed'); expect(f.run.status).assertEqual('completed');
    });
    it('failed_initial_checkpoint_prevents_any_model_request', 0, async () => {
      const f = new Fixture(); f.options.checkpoint = async () => { throw new Error('disk full'); };
      try { await f.execute(); } catch (_) {}
      expect(f.provider.requests.length).assertEqual(0); expect(f.run.status).assertEqual('failed');
    });
    it('restart_marks_running_work_interrupted_without_replaying', 0, () => {
      const run = fixtureRun(); run.status = 'running'; run.tasks[0].status = 'running';
      run.tasks[0].attempts.push({ id: 'attempt1', status: 'running', startedAt: 1, error: '', turn: { content: '部分内容', steps: [] } });
      recoverTeams([run]); expect(run.status).assertEqual('interrupted'); expect(run.tasks[0].status).assertEqual('interrupted');
      expect(run.tasks[0].attempts[0].turn.content).assertEqual('部分内容'); expect(run.tasks[1].status).assertEqual('pending');
      validateTeamPlan(teamPlan(run), run.members);
    });
    it('shared_tool_lane_serializes_and_skips_cancelled_waiters', 0, async () => {
      const lane = new TeamToolLane();
      const call: ToolCall = { id: 'c', type: 'function', function: { name: 'test', arguments: '{}' } };
      const tools = new ToolSet([]);
      const blocking = new BlockingTools();
      const first = lane.execute(blocking, call, new Cancellation());
      await blocking.entered.promise; const signal = new Cancellation();
      const second = lane.execute(tools, call, signal).catch(() => 'cancelled'); signal.cancel(); blocking.release.open();
      expect(await first).assertEqual('ok'); expect(await second).assertEqual('cancelled'); expect(blocking.count).assertEqual(1);
    });
  });
}
