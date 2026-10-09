import { describe, expect, it } from '@ohos/hypium';
import { AgentTurn, ModelMessage, ModelTurn, ToolCall, ToolDefinition, ToolExecutionMode } from '../main/ets/model/Agent';
import { emptyData, parseAppData, requestHistory } from '../main/ets/model/Conversation';
import { AgentTools, LoopObserver, runAgentLoop } from '../main/ets/services/AgentLoop';
import { Cancellation } from '../main/ets/services/Cancellation';
import { ModelSession } from '../main/ets/services/providers/Provider';
import { TeamToolLane, TeamTools } from '../main/ets/services/TeamCoordinator';
import { WorkspaceTools, WorkspaceFiles } from '../main/ets/services/WorkspaceTools';
import { ToolSet } from '../main/ets/services/ToolSet';
import { RuleTools } from '../main/ets/services/RuleTools';
import { chatRequest } from '../main/ets/services/providers/ChatCompletionsProtocol';
import { responsesRequest, anthropicRequest } from '../main/ets/services/providers/WireProtocols';

class Gate {
  private release: () => void = () => {};
  promise: Promise<void> = new Promise<void>((resolve) => { this.release = resolve; });
  open(): void { this.release(); }
}
function call(id: string, name: string = 'read'): ToolCall {
  return { id: id, type: 'function', function: { name: name, arguments: '{}' } };
}
function definition(name: string, mode?: ToolExecutionMode): ToolDefinition {
  return { type: 'function', executionMode: mode, function: { name: name, description: name,
    parameters: { type: 'object', properties: {}, required: [], additionalProperties: false } } };
}
class BatchModel implements ModelSession {
  calls: ToolCall[];
  requests: ModelMessage[][] = [];
  constructor(calls: ToolCall[]) { this.calls = calls; }
  async stream(messages: ModelMessage[], _tools: ToolDefinition[], cancellation: Cancellation,
    _onText: (text: string) => void): Promise<ModelTurn> {
    cancellation.check(); this.requests.push(JSON.parse(JSON.stringify(messages)) as ModelMessage[]);
    return { content: this.requests.length === 1 ? '' : 'done', toolCalls: this.requests.length === 1 ? this.calls : [] };
  }
}
class GatedTools implements AgentTools {
  starts: string[] = [];
  failures: string[] = [];
  gates: Map<string, Gate> = new Map<string, Gate>();
  entered: Map<string, Gate> = new Map<string, Gate>();
  beforeStart: (id: string) => void = () => {};
  constructor(ids: string[]) { ids.forEach((id) => { this.gates.set(id, new Gate()); this.entered.set(id, new Gate()); }); }
  definitions(): ToolDefinition[] { return [definition('read'), definition('write', 'sequential')]; }
  async execute(tool: ToolCall, cancellation: Cancellation): Promise<string> {
    cancellation.check(); this.beforeStart(tool.id); this.starts.push(tool.id); this.entered.get(tool.id)!.open();
    await this.gates.get(tool.id)!.promise;
    if (this.failures.includes(tool.id)) { throw new Error('tool failure ' + tool.id); }
    // Deliberately allow a committed outcome to arrive after cancellation.
    return 'receipt-' + tool.id;
  }
}
class Fixture {
  turn: AgentTurn = { content: '', steps: [] };
  model: BatchModel;
  tools: GatedTools;
  cancellation: Cancellation = new Cancellation();
  saves: string[] = [];
  ends: string[] = [];
  saved: (index: number) => Promise<void> = async () => {};
  ended: (id: string) => void = () => {};
  constructor(calls: ToolCall[] = [call('a'), call('b')]) {
    this.model = new BatchModel(calls); this.tools = new GatedTools(calls.map((item) => item.id));
  }
  observer(): LoopObserver {
    return { event: (event) => {
      if (event.type === 'tool_end') { this.ends.push(event.toolCallId!); this.ended(event.toolCallId!); }
    }, checkpoint: async () => { this.saves.push(JSON.stringify(this.turn)); await this.saved(this.saves.length); } };
  }
  run(mode?: ToolExecutionMode): Promise<void> {
    return runAgentLoop({ model: this.model, tools: this.tools, messages: [{ role: 'user', content: 'task' }],
      turn: this.turn, maxSteps: 3, toolExecution: mode }, this.cancellation, this.observer());
  }
}
class Files implements WorkspaceFiles {
  async list(): Promise<string> { return '[]'; }
  async read(): Promise<string> { return '{"content":"ok"}'; }
  async write(): Promise<string> { return '{"written":true}'; }
}
async function errorOf(work: Promise<void>): Promise<string> {
  try { await work; return ''; } catch (error) { return (error as Error).message; }
}

export default function toolParallelismTests(): void {
  describe('ToolParallelism', () => {
    it('startsIndependentCallsTogetherAndReplaysOutOfOrderOutcomesInSourceOrder', 0, async () => {
      const f = new Fixture(); const bEnded = new Gate(); const firstSave = new Gate(); const saving = new Gate();
      f.saved = async (index) => { if (index === 1) { saving.open(); await firstSave.promise; } };
      f.tools.beforeStart = () => { expect(f.saves[0].includes('"status":"running"')).assertTrue(); };
      f.ended = (id) => { if (id === 'b') { bEnded.open(); } };
      const work = f.run(); await saving.promise; expect(f.tools.starts.length).assertEqual(0); firstSave.open();
      await f.tools.entered.get('b')!.promise;
      expect(f.tools.starts.join(',')).assertEqual('a,b'); expect(f.model.requests.length).assertEqual(1);
      f.tools.gates.get('b')!.open(); await bEnded.promise;
      expect(f.ends.join(',')).assertEqual('b'); expect(f.turn.steps[0].tools[0].status).assertEqual('running');
      f.tools.gates.get('a')!.open(); await work;
      expect(f.ends.join(',')).assertEqual('b,a');
      expect(f.model.requests[1].filter((item) => item.role === 'tool').map((item) => item.toolCallId).join(',')).assertEqual('a,b');
      const data = emptyData(); data.activeThreadId = 't'; data.threads = [{ id: 't', title: 't', updatedAt: 1, messages: [
        { id: 'u', role: 'user', content: 'task', status: 'complete', error: '' },
        { id: 'a', role: 'assistant', content: f.turn.content, steps: f.turn.steps, status: 'complete', error: '' }
      ] }];
      const history = requestHistory(parseAppData(JSON.stringify(data)).threads[0].messages, '');
      expect(history.filter((item) => item.role === 'tool').map((item) => item.content).join(',')).assertEqual('receipt-a,receipt-b');
    });
    it('serializesTheEntireBatchWhenAnyToolRequiresItAndSupportsAGlobalOverride', 0, async () => {
      for (const global of [false, true]) {
        const f = new Fixture([call('a'), call('b', global ? 'read' : 'write'), call('c')]);
        const work = f.run(global ? 'sequential' : undefined);
        await f.tools.entered.get('a')!.promise; expect(f.tools.starts.join(',')).assertEqual('a');
        f.tools.gates.get('a')!.open(); await f.tools.entered.get('b')!.promise;
        expect(f.tools.starts.join(',')).assertEqual('a,b');
        f.tools.gates.get('b')!.open(); await f.tools.entered.get('c')!.promise; f.tools.gates.get('c')!.open(); await work;
        expect(f.ends.join(',')).assertEqual('a,b,c');
      }
    });
    it('drainsStartedOperationsAndPersistsLateCommittedReceiptsBeforeStopping', 0, async () => {
      const f = new Fixture(); let settled = false; const bEnded = new Gate();
      f.ended = (id) => { if (id === 'b') { bEnded.open(); } };
      const work = errorOf(f.run()).then((error) => { settled = true; return error; });
      await f.tools.entered.get('b')!.promise; f.cancellation.cancel(); f.tools.gates.get('b')!.open(); await bEnded.promise;
      expect(settled).assertFalse(); f.tools.gates.get('a')!.open();
      expect((await work).includes('停止')).assertTrue(); expect(f.model.requests.length).assertEqual(1);
      expect(f.turn.steps[0].tools.every((tool) => tool.status === 'complete')).assertTrue();
      expect(f.saves[f.saves.length - 1].includes('receipt-a')).assertTrue();
      expect(f.saves[f.saves.length - 1].includes('receipt-b')).assertTrue();
    });
    it('neverStartsAnUnpersistedBatchAndSkipsCallsCancelledBeforeDispatch', 0, async () => {
      const failed = new Fixture(); failed.saved = async () => { throw new Error('disk full'); };
      expect(await errorOf(failed.run())).assertEqual('disk full'); expect(failed.tools.starts.length).assertEqual(0);
      expect(failed.turn.steps[0].tools.every((tool) => tool.status === 'cancelled')).assertTrue();
      const stopped = new Fixture(); stopped.saved = async () => { stopped.cancellation.cancel(); };
      expect((await errorOf(stopped.run())).includes('停止')).assertTrue(); expect(stopped.tools.starts.length).assertEqual(0);
      const midway = new Fixture(); midway.tools.beforeStart = () => { midway.cancellation.cancel(); }; midway.tools.gates.get('a')!.open();
      expect((await errorOf(midway.run())).includes('停止')).assertTrue();
      expect(midway.tools.starts.join(',')).assertEqual('a'); expect(midway.turn.steps[0].tools[1].status).assertEqual('cancelled');
      const notified = new Fixture(); const observer = notified.observer();
      observer.event = (event) => { if (event.type === 'tool_start') { notified.cancellation.cancel(); } };
      expect((await errorOf(runAgentLoop({ model: notified.model, tools: notified.tools, messages: [],
        turn: notified.turn, maxSteps: 3 }, notified.cancellation, observer))).includes('停止')).assertTrue();
      expect(notified.tools.starts.length).assertEqual(0);
    });
    it('serializesReceiptSavesAndDrainsOtherToolsAfterAPersistenceFailure', 0, async () => {
      const f = new Fixture(); const blocked = new Gate(); const saving = new Gate(); let active = 0; let peak = 0; let settled = false;
      f.saved = async (index) => {
        active++; peak = Math.max(peak, active);
        try { if (index === 2) { saving.open(); await blocked.promise; throw new Error('receipt disk failure'); } }
        finally { active--; }
      };
      const work = errorOf(f.run()).then((error) => { settled = true; return error; });
      await f.tools.entered.get('b')!.promise; f.tools.gates.get('b')!.open(); await saving.promise;
      f.tools.gates.get('a')!.open(); await Promise.resolve();
      expect(settled).assertFalse(); expect(peak).assertEqual(1); blocked.open();
      expect(await work).assertEqual('receipt disk failure'); expect(f.model.requests.length).assertEqual(1);
      expect(f.saves.length).assertEqual(3); expect(f.turn.steps[0].tools.every((tool) => tool.status === 'complete')).assertTrue();
    });
    it('returnsToolErrorsWithoutDiscardingSuccessfulSiblings', 0, async () => {
      const f = new Fixture(); f.tools.failures = ['a']; f.tools.gates.forEach((gate) => gate.open()); await f.run();
      expect(f.turn.steps[0].tools[0].status).assertEqual('failed'); expect(f.turn.steps[0].tools[1].status).assertEqual('complete');
      expect(f.model.requests[1][2].content.includes('tool failure a')).assertTrue();
      expect(f.model.requests[1][3].content).assertEqual('receipt-b');
    });
    it('sharesReadsAcrossWorkersButMakesWritesExclusiveAndPreventsWriterStarvation', 0, async () => {
      const lane = new TeamToolLane(); const tools = new GatedTools(['a', 'b', 'w', 'c']);
      const firstWorker = new TeamTools(tools, lane); const secondWorker = new TeamTools(tools, lane); const signal = new Cancellation();
      const a = firstWorker.execute(call('a'), signal); const b = secondWorker.execute(call('b'), signal);
      await tools.entered.get('b')!.promise;
      const w = firstWorker.execute(call('w', 'write'), signal); const c = secondWorker.execute(call('c'), signal);
      tools.gates.get('b')!.open(); await b; expect(tools.starts.join(',')).assertEqual('a,b');
      tools.gates.get('a')!.open(); await a; await tools.entered.get('w')!.promise;
      expect(tools.starts.join(',')).assertEqual('a,b,w'); tools.gates.get('w')!.open(); await w;
      await tools.entered.get('c')!.promise; tools.gates.get('c')!.open(); await c;
      expect(tools.starts.join(',')).assertEqual('a,b,w,c');
    });
    it('releasesSharedLaneAfterCancelledAndFailedExclusiveOperations', 0, async () => {
      const lane = new TeamToolLane(); const tools = new GatedTools(['a', 'skip', 'fail', 'c']); const signal = new Cancellation();
      const a = lane.execute(tools, call('a'), signal); await tools.entered.get('a')!.promise;
      const cancelled = new Cancellation();
      const skip = lane.execute(tools, call('skip', 'write'), cancelled).catch((error: Error) => error.message); cancelled.cancel();
      tools.failures = ['fail']; tools.gates.get('fail')!.open();
      const fail = lane.execute(tools, call('fail', 'write'), signal).catch((error: Error) => error.message);
      const c = lane.execute(tools, call('c'), signal); tools.gates.get('a')!.open(); await a;
      expect((await skip).includes('停止')).assertTrue(); expect(await fail).assertEqual('tool failure fail');
      await tools.entered.get('c')!.promise; tools.gates.get('c')!.open(); await c;
      expect(tools.starts.join(',')).assertEqual('a,fail,c');
    });
    it('keepsToolSchedulingMetadataThroughFiltersButOutOfAllProviderSchemas', 0, () => {
      const tools = new ToolSet([new WorkspaceTools(new Files())]);
      const definitions = tools.definitions();
      expect(definitions.find((tool) => tool.function.name === 'edit_file')?.executionMode).assertEqual('sequential');
      expect(definitions.find((tool) => tool.function.name === 'write_file')?.executionMode).assertEqual('sequential');
      expect(new RuleTools(tools, true).definitions().every((tool) => tool.executionMode === 'parallel')).assertTrue();
      const wires = [JSON.stringify(chatRequest('model', [], definitions)), JSON.stringify(responsesRequest('model', [], definitions)),
        JSON.stringify(anthropicRequest('model', [], definitions))];
      expect(wires.every((wire) => !wire.includes('executionMode'))).assertTrue();
    });
  });
}
