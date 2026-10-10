import { describe, expect, it } from '@ohos/hypium';
import { getLocale, setLocale } from '../main/ets/model/I18n';
import { employeeName } from '../main/ets/model/TeamNames';
import { ModelTurn, ToolCall, ToolDefinition } from '../main/ets/model/Agent';
import { defaultConfig, ThreadData } from '../main/ets/model/Conversation';
import { ProviderInfo } from '../main/ets/model/Provider';
import { TeamRun, TeamTask, recoverTeams, teamCommand } from '../main/ets/model/Team';
import { AgentTools } from '../main/ets/services/AgentLoop';
import { AgentRuntime } from '../main/ets/services/AgentRuntime';
import { Cancellation } from '../main/ets/services/Cancellation';
import { ChatTeamTools } from '../main/ets/services/ChatTeamTools';
import { CredentialReader, ModelProvider, ProviderRequest } from '../main/ets/services/providers/Provider';
import { ProviderRegistry } from '../main/ets/services/providers/ProviderRegistry';
import { textPage } from '../main/ets/model/TextPage';

class Gate {
  private release: () => void = () => {};
  promise: Promise<void> = new Promise<void>((resolve) => { this.release = resolve; });
  open(): void { this.release(); }
}
class Keys implements CredentialReader { async read(_alias: string): Promise<string> { return ''; } }
class BaseTools implements AgentTools {
  files: Map<string, string> = new Map<string, string>();
  calls: string[] = [];
  definitions(): ToolDefinition[] {
    return ['read_file', 'write_file', 'mcp_call', 'publish_data_view', 'read_web', 'execute_code'].map((name): ToolDefinition => {
      return { type: 'function', function: { name: name, description: name, parameters: { type: 'object', properties: {}, required: [], additionalProperties: false } } };
    });
  }
  async execute(call: ToolCall, signal: Cancellation): Promise<string> {
    signal.check(); this.calls.push(call.function.name);
    const args = JSON.parse(call.function.arguments) as FileArgs;
    if (call.function.name === 'read_file') { if (!this.files.has(args.path)) { throw new Error('missing file'); } return JSON.stringify(textPage(this.files.get(args.path) as string, args.offset, undefined, args.column)); }
    if (call.function.name === 'write_file') { this.files.set(args.path, args.content || ''); }
    return '{}';
  }
}
interface FileArgs { path: string; content?: string; offset?: number; column?: number; }
interface Assignment { task: TaskInput; }
interface TaskInput { id: string; }
interface RecruitReply { runId: string; }
interface Page { status: string; afterSequence: number; results: ResultItem[]; }
interface ResultItem { entryId: string; summary: string; }
class Employees implements ModelProvider {
  readonly info: ProviderInfo = { id: 'test', name: 'Test', protocol: 'test', defaultBaseUrl: 'https://example.com', defaultModel: 'model' };
  requests: ProviderRequest[] = [];
  entered: Gate = new Gate(); gate?: Gate;
  noHandoff: boolean = false; fail: boolean = false; artifacts: string[] = [];
  endpoint(url: string): string { return url; }
  async stream(request: ProviderRequest, signal: Cancellation, onText: (text: string) => void): Promise<ModelTurn> {
    this.requests.push(request); this.entered.open();
    if (this.gate) {
      const remove = signal.onCancel(() => this.gate?.open()); await this.gate.promise; remove(); signal.check();
    }
    if (this.fail) { throw new Error('employee offline'); }
    const task = (JSON.parse(request.messages[1].content) as Assignment).task;
    if (this.noHandoff || request.messages.some((message) => message.role === 'tool')) { onText('员工内部草稿'); return { content: '员工内部草稿', toolCalls: [] }; }
    return { content: '', toolCalls: [call('team_complete_task', JSON.stringify({ summary: task.id + '-result', unresolved: [], artifacts: this.artifacts }))] };
  }
}
function call(name: string, args: string = '{}'): ToolCall { return { id: 'call_' + name, type: 'function', function: { name: name, arguments: args } }; }
function recruitArgs(id: string = 'a', member: string = 'worker', runId?: string): string {
  const args: ProfileRecruit = { runId: runId, goal: runId ? undefined : '协作测试', members: runId ? [] : [{ id: member, displayName: '员工', instructions: '明确完成分配任务' }],
    tasks: [{ id: id, title: id, memberId: member, instructions: '完成任务并交接', dependencies: [] }] };
  return JSON.stringify(args);
}
class Fixture {
  thread: ThreadData = { id: 'thread', title: 'test', updatedAt: 1, messages: [] };
  provider: Employees = new Employees(); base: BaseTools = new BaseTools(); host: ChatTeamTools;
  beforeSave: (snapshot: ThreadData) => Promise<void> = async () => {};
  saved: string = ''; writes: number = 0;
  constructor() {
    const registry = new ProviderRegistry(); registry.register(this.provider); const keys = new Keys();
    const config = defaultConfig(); config.configured = true; config.providerId = 'test'; config.model = 'model';
    let id = 0; let tail: Promise<void> = Promise.resolve();
    this.host = new ChatTeamTools({ thread: this.thread, messageId: 'parent-message', config: config, base: () => this.base,
      runtime: () => new AgentRuntime(registry, keys), createId: () => 'id-' + ++id, changed: () => {}, checkpoint: () => {
        const text = JSON.stringify(this.thread);
        const save = tail.then(async () => { await this.beforeSave(JSON.parse(text) as ThreadData); this.saved = text; this.writes++; });
        tail = save.catch(() => {}); return save;
      } });
  }
  async recruit(args: string = recruitArgs()): Promise<string> { return (JSON.parse(await this.host.execute(call('team_recruit', args), new Cancellation())) as RecruitReply).runId; }
  async wait(id: string, cursor: number = 0, all: boolean = true, signal: Cancellation = new Cancellation()): Promise<Page> {
    return JSON.parse(await this.host.execute(call('team_wait', JSON.stringify({ runId: id, afterSequence: cursor, waitFor: all ? 'all_tasks' : 'next_result' })), signal)) as Page;
  }
}
async function rejection(action: () => Promise<string>, fragment: string): Promise<void> {
  let error = ''; try { await action(); } catch (caught) { error = (caught as Error).message; } expect(error.includes(fragment)).assertTrue();
}

export default function chatTeamTests(): void {
  describe('ChatTeam', () => {
    it('assigns_missing_names_and_returns_the_same_persisted_identity', 0, async () => {
      const f = new Fixture();
      const args = recruitArgs().replace(',"displayName":"员工"', '');
      const id = await f.recruit(args); await f.wait(id);
      const member = f.thread.teams![0].members[0];
      expect(member.name).assertEqual(employeeName(member.id, getLocale(), []));
      expect(f.host.page(id, 0).members[0].displayName).assertEqual(member.name);
      expect(f.provider.requests[0].messages[0].content.includes(member.name)).assertTrue();
      const restored = (JSON.parse(f.saved) as ThreadData).teams!;
      recoverTeams(restored); expect(restored[0].members[0].name).assertEqual(member.name);
      await f.host.close();
    });
    it('reserves_explicit_names_and_avoids_collisions_when_appending', 0, async () => {
      const f = new Fixture(); const explicit = employeeName('a', getLocale(), []);
      const id = await f.recruit(JSON.stringify({ goal: 'naming',
        members: [{ id: 'a', displayName: '  ', instructions: 'work' }, { id: 'named', displayName: explicit, instructions: 'work' }],
        tasks: [{ id: 'a', title: 'a', memberId: 'a', instructions: 'work', dependencies: [] }] } as ProfileRecruit));
      await f.wait(id); await Promise.resolve();
      const first = f.thread.teams![0].members[0].name;
      expect(first === explicit).assertFalse();
      expect(f.thread.teams![0].members[1].name).assertEqual(explicit);
      const reply = await f.host.execute(call('team_recruit', JSON.stringify({ runId: id,
        members: [{ id: 'i', displayName: '', instructions: 'work' }],
        tasks: [{ id: 'i', title: 'i', memberId: 'i', instructions: 'work', dependencies: [] }] } as ProfileRecruit)), new Cancellation());
      await f.wait(id);
      const names = f.thread.teams![0].members.map((member) => member.name);
      expect(new Set(names).size).assertEqual(3);
      expect(reply.includes(names[2])).assertTrue();
      expect(names[0]).assertEqual(first); await f.host.close();
    });
    it('uses_english_fallback_without_renaming_existing_employees_on_language_change', 0, async () => {
      const previous = getLocale(); const f = new Fixture();
      try {
        setLocale('en');
        const id = await f.recruit(recruitArgs().replace('"displayName":"员工"', '"displayName":""'));
        await f.wait(id);
        const name = f.thread.teams![0].members[0].name;
        expect(/^[A-Za-z ]+$/.test(name)).assertTrue();
        setLocale('zh-CN'); expect(f.host.page(id, 0).members[0].displayName).assertEqual(name);
      } finally { setLocale(previous); await f.host.close(); }
    });
    it('recognizes_explicit_team_commands_only', 0, () => {
      expect(teamCommand('/team 招募研究员')).assertEqual('招募研究员'); expect(teamCommand('@team work')).assertEqual('work');
      expect(teamCommand('/team')).assertEqual(''); expect(teamCommand('/teams work')).assertUndefined(); expect(teamCommand('解释 /team')).assertUndefined();
    });
    it('recruits_immediately_and_publishes_only_committed_handoffs', 0, async () => {
      const f = new Fixture(); f.provider.gate = new Gate(); const id = await f.recruit(); await f.provider.entered.promise;
      expect(f.host.page(id, 0).results.length).assertEqual(0); expect(f.thread.teams![0].ownerMessageId).assertEqual('parent-message');
      let returned = false; const waiting = f.wait(id).then((page) => { returned = true; return page; }); await Promise.resolve(); expect(returned).assertFalse();
      f.provider.gate.open(); const page = await waiting;
      expect(page.status).assertEqual('completed'); expect(page.results[0].summary).assertEqual('a-result');
      expect(JSON.stringify(page).includes('员工内部草稿')).assertFalse(); expect((await f.wait(id, page.afterSequence)).results.length).assertEqual(0);
      await f.host.close();
    });
    it('appends_tasks_while_worker_runs_without_rewriting_attempts', 0, async () => {
      const f = new Fixture(); f.provider.gate = new Gate(); const id = await f.recruit(); await f.provider.entered.promise;
      expect(await f.recruit(recruitArgs('b', 'worker', id))).assertEqual(id);
      expect(f.thread.teams![0].tasks.length).assertEqual(2); f.provider.gate.open(); const page = await f.wait(id);
      expect(page.results.length).assertEqual(2); expect(f.thread.teams![0].tasks[0].attempts.length).assertEqual(1); await f.host.close();
    });
    it('can_recruit_a_second_wave_into_completed_run', 0, async () => {
      const f = new Fixture(); const id = await f.recruit(); const first = await f.wait(id); await Promise.resolve();
      await f.recruit(recruitArgs('b', 'worker', id)); const second = await f.wait(id, first.afterSequence);
      expect(second.results.length).assertEqual(1); expect(second.results[0].summary).assertEqual('b-result'); await f.host.close();
    });
    it('rejects_foreign_runs_cycles_and_duplicate_tasks', 0, async () => {
      const f = new Fixture(); const id = await f.recruit(); await f.wait(id);
      await rejection(() => f.host.execute(call('team_inspect', '{"runId":"foreign"}'), new Cancellation()), '当前聊天');
      await rejection(() => f.host.execute(call('team_recruit', recruitArgs('a', 'worker', id)), new Cancellation()), '任务 ID');
      expect(f.thread.teams![0].tasks.length).assertEqual(1); await f.host.close();
    });
    it('worker_cannot_recruit_or_publish_final_views_and_review_is_readonly', 0, async () => {
      const f = new Fixture(); const args = JSON.parse(recruitArgs()) as ProfileRecruit;
      args.members[0].toolProfile = 'review'; const id = await f.recruit(JSON.stringify(args)); await f.wait(id);
      const names = f.provider.requests[0].tools.map((tool) => tool.function.name);
      expect(names.includes('team_recruit')).assertFalse(); expect(names.includes('publish_data_view')).assertFalse();
      expect(names.includes('execute_code')).assertTrue();
      expect(names.includes('write_file')).assertFalse(); expect(names.includes('mcp_call')).assertFalse(); expect(names.includes('read_file')).assertTrue(); await f.host.close();
    });
    it('missing_handoff_is_failed_even_if_employee_finishes_text', 0, async () => {
      const f = new Fixture(); f.provider.noHandoff = true; const id = await f.recruit(); const page = await f.wait(id);
      expect(page.results.length).assertEqual(0); expect(f.thread.teams![0].tasks[0].status).assertEqual('failed'); await f.host.close();
    });
    it('parent_finish_waits_and_requests_integration_in_same_turn', 0, async () => {
      const f = new Fixture(); f.provider.gate = new Gate(); await f.recruit(); await f.provider.entered.promise;
      const finish = f.host.beforeFinish(new Cancellation()); f.provider.gate.open();
      expect((await finish || '').includes('a-result')).assertTrue(); expect(await f.host.beforeFinish(new Cancellation())).assertUndefined(); await f.host.close();
    });
    it('cancel_interrupts_wait_and_all_children_without_replay', 0, async () => {
      const f = new Fixture(); f.provider.gate = new Gate(); const id = await f.recruit(); await f.provider.entered.promise;
      const signal = new Cancellation(); const waiting = f.wait(id, 0, true, signal).then(() => false, () => true);
      f.host.stop(); signal.cancel(); expect(await waiting).assertTrue(); await f.host.close();
      expect(f.thread.teams![0].status).assertEqual('cancelled'); expect(f.thread.teams![0].tasks[0].attempts.length).assertEqual(1);
    });
    it('save_failure_before_recruitment_prevents_any_worker_request', 0, async () => {
      const f = new Fixture(); f.beforeSave = async () => { throw new Error('disk full'); };
      await rejection(() => f.recruit(), 'disk full'); expect(f.provider.requests.length).assertEqual(0); await f.host.close();
    });
    it('wait_does_not_observe_handoff_until_save_completes', 0, async () => {
      const f = new Fixture(); const entered = new Gate(); const release = new Gate();
      f.beforeSave = async (snapshot) => { if (snapshot.teams![0]?.tasks[0].status === 'succeeded') { entered.open(); await release.promise; } };
      const id = await f.recruit(); await entered.promise; expect(f.host.page(id, 0).results.length).assertEqual(0);
      release.open(); expect((await f.wait(id)).results.length).assertEqual(1); await f.host.close();
    });
    it('verified_artifact_reads_reject_changed_files', 0, async () => {
      const f = new Fixture(); f.base.files.set('report.md', 'original'); f.provider.artifacts = ['report.md'];
      const id = await f.recruit(); const page = await f.wait(id); const args = JSON.stringify({ runId: id, entryId: page.results[0].entryId, artifactIndex: 0 });
      expect((await f.host.execute(call('team_read_result', args), new Cancellation())).includes('original')).assertTrue();
      f.base.files.set('report.md', 'changed'); await rejection(() => f.host.execute(call('team_read_result', args), new Cancellation()), '已变化'); await f.host.close();
    });
    it('handoff_reads_all_pages_and_detects_changes_beyond_the_first_page', 0, async () => {
      const f = new Fixture(); const content = '中文'.repeat(20000) + '\nORIGINAL';
      f.base.files.set('report.md', content); f.provider.artifacts = ['report.md'];
      const id = await f.recruit(); const page = await f.wait(id);
      expect(page.results.length).assertEqual(1);
      expect(f.thread.teams![0].tasks[0].attempts[0].handoff?.artifacts[0].content).assertEqual(content);
      recoverTeams(JSON.parse(JSON.stringify(f.thread.teams)) as TeamRun[]);
      f.base.files.set('report.md', content.replace('ORIGINAL', 'CHANGED'));
      await rejection(() => f.host.execute(call('team_read_result', JSON.stringify({ runId: id, entryId: page.results[0].entryId, artifactIndex: 0 })), new Cancellation()), '已变化');
      await f.host.close();
    });
    it('rejects_oversized_handoff_without_saving_a_partial_artifact', 0, async () => {
      const f = new Fixture(); f.base.files.set('report.md', 'x'.repeat(65537)); f.provider.artifacts = ['report.md'];
      const id = await f.recruit(); const page = await f.wait(id);
      expect(page.results.length).assertEqual(0);
      expect(f.thread.teams![0].tasks[0].attempts[0].handoff).assertUndefined();
      recoverTeams(JSON.parse(JSON.stringify(f.thread.teams)) as TeamRun[]); await f.host.close();
    });
    it('chat_run_survives_load_and_running_work_becomes_interrupted', 0, async () => {
      const f = new Fixture(); const id = await f.recruit(); await f.wait(id); await f.host.close();
      const runs = JSON.parse(JSON.stringify(f.thread.teams)) as TeamRun[]; recoverTeams(runs);
      expect(runs[0].finalTaskId).assertEqual(''); expect(runs[0].tasks[0].attempts[0].handoff?.summary).assertEqual('a-result');
      runs[0].status = 'running'; runs[0].tasks[0].status = 'running'; runs[0].tasks[0].attempts[0].status = 'running'; recoverTeams(runs);
      expect(runs[0].status).assertEqual('interrupted');
    });
  });
}
interface ProfileMember { id: string; displayName: string; instructions: string; toolProfile?: string; }
interface ProfileRecruit { goal?: string; runId?: string; members: ProfileMember[]; tasks: TeamTask[]; }
