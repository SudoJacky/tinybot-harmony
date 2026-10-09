import { describe, expect, it } from '@ohos/hypium';
import { AgentTurn, ModelMessage, ModelTurn, ToolCall, ToolDefinition } from '../main/ets/model/Agent';
import { MessageData, ThreadData, emptyData, parseAppData, requestHistory } from '../main/ets/model/Conversation';
import { prepareCompaction } from '../main/ets/model/ConversationContext';
import { PendingInput, nextPendingInput, validatePendingInputs } from '../main/ets/model/PendingInput';
import { matchingThreads } from '../main/ets/model/SessionManagement';
import { AgentTools, LoopObserver, runAgentLoop } from '../main/ets/services/AgentLoop';
import { Cancellation } from '../main/ets/services/Cancellation';
import { ModelSession } from '../main/ets/services/providers/Provider';

function input(id: string, text: string = id, followUp: boolean = false): PendingInput {
  return { id: id, text: text, mode: followUp ? 'followUp' : 'steer' };
}
function call(id: string): ToolCall {
  return { id: id, type: 'function', function: { name: 'work', arguments: '{}' } };
}
function answer(text: string, calls: ToolCall[] = []): ModelTurn { return { content: text, toolCalls: calls }; }
function thread(turn: AgentTurn, status: string = 'complete'): ThreadData {
  const messages: MessageData[] = [
    { id: 'u', role: 'user', content: 'initial', status: 'complete', error: '' },
    { id: 'a', role: 'assistant', content: turn.content, status: status, error: '', steps: turn.steps }
  ];
  return { id: 'thread', title: 'thread', updatedAt: 1, messages: messages };
}
async function failure(action: () => Promise<void>, fragment: string): Promise<void> {
  let message = '';
  try { await action(); } catch (error) { message = (error as Error).message; }
  expect(message.includes(fragment)).assertTrue();
}

class QueueFixture {
  pending: PendingInput[] = [];
  turn: AgentTurn = { content: '', steps: [] };
  checkpoints: string[] = [];
  failSave: boolean = false;
  observer(): LoopObserver {
    return { event: () => {}, checkpoint: async () => {
      if (this.failSave) { throw new Error('disk failed'); }
      this.checkpoints.push(JSON.stringify({ pending: this.pending, turn: this.turn }));
    }, steering: {
      peek: () => nextPendingInput(this.pending, false, true),
      consume: (id: string) => { this.pending = this.pending.filter((item: PendingInput) => item.id !== id); }
    } };
  }
}
class QueueModel implements ModelSession {
  requests: ModelMessage[][] = [];
  responses: ModelTurn[];
  beforeReply: (index: number) => void = () => {};
  constructor(responses: ModelTurn[]) { this.responses = responses; }
  async stream(messages: ModelMessage[], _tools: ToolDefinition[], cancellation: Cancellation,
    _onText: (text: string) => void): Promise<ModelTurn> {
    cancellation.check();
    const index = this.requests.length;
    this.requests.push(JSON.parse(JSON.stringify(messages)) as ModelMessage[]);
    this.beforeReply(index);
    const response = this.responses[index];
    if (!response) { throw new Error('unexpected request'); }
    return response;
  }
}
class QueueTools implements AgentTools {
  calls: string[] = [];
  duringTool: (id: string) => void = () => {};
  definitions(): ToolDefinition[] { return []; }
  async execute(tool: ToolCall, cancellation: Cancellation): Promise<string> {
    cancellation.check();
    this.calls.push(tool.id);
    this.duringTool(tool.id);
    return 'receipt-' + tool.id;
  }
}
async function run(fixture: QueueFixture, model: QueueModel, tools: QueueTools = new QueueTools(),
  cancellation: Cancellation = new Cancellation(), limit: number = 8, window?: number): Promise<void> {
  await runAgentLoop({ model: model, tools: tools, messages: [{ role: 'user', content: 'initial' }],
    turn: fixture.turn, maxSteps: limit, contextWindow: window }, cancellation, fixture.observer());
}

export default function pendingInputTests(): void {
  describe('PendingInputQueue', () => {
    it('prioritizesSteeringWithoutReorderingEitherLaneAndHonorsPause', 0, () => {
      const items = [input('task1', 'task1', true), input('steer1'), input('task2', 'task2', true), input('steer2')];
      expect(nextPendingInput(items, true)).assertUndefined();
      expect(nextPendingInput(items, false)?.id).assertEqual('steer1');
      const rest = items.filter((item: PendingInput) => item.id !== 'steer1');
      expect(nextPendingInput(rest, false)?.id).assertEqual('steer2');
      const tasks = rest.filter((item: PendingInput) => item.mode === 'followUp');
      expect(nextPendingInput(tasks, false, true)).assertUndefined();
      expect(nextPendingInput(tasks, false)?.id).assertEqual('task1');
      expect(items.length).assertEqual(4);
    });
    it('persistsPerSessionAndPausesRestoredWorkWithoutStartingIt', 0, () => {
      const data = emptyData();
      const first = thread({ content: 'done', steps: [] });
      first.pendingInputs = [input('first', 'first', true)]; first.queuePaused = false;
      const second = thread({ content: 'done', steps: [] }); second.id = 'second';
      second.pendingInputs = [input('second', 'second', true)];
      data.threads = [first, second];
      const restored = parseAppData(JSON.stringify(data));
      expect(restored.threads[0].queuePaused).assertTrue();
      expect(restored.threads[1].pendingInputs?.[0].text).assertEqual('second');
      expect(nextPendingInput(restored.threads[0].pendingInputs || [], restored.threads[0].queuePaused === true)).assertUndefined();
      expect(parseAppData(JSON.stringify(emptyData())).threads.length).assertEqual(0);
    });
    it('rejectsDuplicateEmptyAndOversizedPendingInstructions', 0, async () => {
      await failure(async () => { validatePendingInputs([input('x'), input('x')]); }, '重复');
      await failure(async () => { validatePendingInputs([input('x', ' ')]); }, '24000');
      await failure(async () => { validatePendingInputs([input('x', 'x'.repeat(24001))]); }, '24000');
      const items: PendingInput[] = [];
      for (let index = 0; index < 21; index++) { items.push(input('i' + index)); }
      await failure(async () => { validatePendingInputs(items); }, '20');
    });
  });
  describe('LiveSteering', () => {
    it('finishesTheWholeToolBatchThenDeliversOneSteeringInputPerRequest', 0, async () => {
      const fixture = new QueueFixture();
      fixture.pending = [input('later', 'later', true)];
      const model = new QueueModel([answer('working', [call('a'), call('b')]), answer('first correction'), answer('second correction')]);
      const tools = new QueueTools();
      tools.duringTool = (id: string) => { if (id === 'a') { fixture.pending.push(input('s1'), input('s2')); } };
      await run(fixture, model, tools);
      expect(tools.calls.join(',')).assertEqual('a,b');
      expect(model.requests[1].map((message: ModelMessage) => message.role).join(',')).assertEqual('user,assistant,tool,tool,user');
      expect(model.requests[1][3].content).assertEqual('receipt-b');
      expect(model.requests[1][4].content).assertEqual('s1');
      expect(model.requests[2][model.requests[2].length - 1].content).assertEqual('s2');
      expect(fixture.pending.length).assertEqual(1);
      expect(fixture.pending[0].id).assertEqual('later');
      expect(fixture.checkpoints.some((snapshot) => snapshot.includes('"steering":{"id":"s1"'))).assertTrue();
    });
    it('acceptsSteeringDuringAResponseThatWouldOtherwiseFinish', 0, async () => {
      const fixture = new QueueFixture();
      const model = new QueueModel([answer('original answer'), answer('revised answer')]);
      model.beforeReply = (index: number) => { if (index === 0) { fixture.pending.push(input('change', 'use Chinese')); } };
      await run(fixture, model);
      expect(model.requests[1].map((message: ModelMessage) => message.content).join('|')).assertEqual('initial|original answer|use Chinese');
      expect(fixture.turn.steps[1].steering?.text).assertEqual('use Chinese');
    });
    it('replaysSteeringInOrderWithToolReceiptsAfterPersistenceAndCompaction', 0, async () => {
      const fixture = new QueueFixture();
      const model = new QueueModel([answer('first', [call('a')]), answer('corrected')]);
      const tools = new QueueTools();
      tools.duringTool = () => { fixture.pending.push(input('s', 'keep source')); };
      await run(fixture, model, tools);
      const data = emptyData(); data.threads = [thread(fixture.turn)];
      const restored = parseAppData(JSON.stringify(data)).threads[0];
      const history = requestHistory(restored.messages, '');
      expect(history.map((message: ModelMessage) => message.role).join(',')).assertEqual('user,assistant,tool,user,assistant');
      expect(history[3].content).assertEqual('keep source');
      expect(matchingThreads([restored], 'keep source', false).length).assertEqual(1);
      restored.messages.push({ id: 'u2', role: 'user', content: 'new', status: 'complete', error: '' },
        { id: 'a2', role: 'assistant', content: 'done', status: 'complete', error: '' });
      const plan = prepareCompaction(restored, { window: 8192, autoCompact: true, keepRecent: 1 });
      expect(plan?.messages[3].content).assertEqual('keep source');
    });
    it('neverDispatchesAnUnrecordedInputAndKeepsItInInterruptedHistory', 0, async () => {
      const fixture = new QueueFixture(); fixture.pending = [input('s', 'correction')]; fixture.failSave = true;
      const model = new QueueModel([answer('must not run')]);
      await failure(async () => { await run(fixture, model); }, 'disk failed');
      expect(model.requests.length).assertEqual(0);
      const history = requestHistory(thread(fixture.turn, 'failed').messages, '');
      expect(history[1].role).assertEqual('user');
      expect(history[1].content).assertEqual('correction');
      const data = emptyData(); data.threads = [thread(fixture.turn, 'failed')];
      expect(parseAppData(JSON.stringify(data)).threads[0].messages[1].steps?.[0].steering?.id).assertEqual('s');
    });
    it('retainsPendingInputWhenBudgetOrStepLimitsPreventDelivery', 0, async () => {
      const fixture = new QueueFixture(); fixture.pending = [input('large', '中'.repeat(3000))];
      const model = new QueueModel([answer('must not run')]);
      await failure(async () => { await run(fixture, model, new QueueTools(), new Cancellation(), 8, 8192); }, '预算');
      expect(fixture.pending.length).assertEqual(1); expect(model.requests.length).assertEqual(0);
      const limited = new QueueFixture();
      const last = new QueueModel([answer('done')]);
      last.beforeReply = () => { limited.pending.push(input('late')); };
      await failure(async () => { await run(limited, last, new QueueTools(), new Cancellation(), 1); }, '上限');
      expect(limited.pending[0].id).assertEqual('late');
      expect(last.requests.length).assertEqual(1);
    });
    it('preservesWaitingInstructionsAndCommittedReceiptsOnStop', 0, async () => {
      const fixture = new QueueFixture();
      const model = new QueueModel([answer('', [call('a'), call('b')])]);
      const tools = new QueueTools(); const cancellation = new Cancellation();
      tools.duringTool = () => { fixture.pending.push(input('s'), input('f', 'follow', true)); cancellation.cancel(); };
      await failure(async () => { await run(fixture, model, tools, cancellation); }, '停止');
      expect(tools.calls.join(',')).assertEqual('a');
      expect(fixture.turn.steps[0].tools[0].status).assertEqual('complete');
      expect(fixture.turn.steps[0].tools[1].status).assertEqual('cancelled');
      expect(fixture.pending.length).assertEqual(2);
      expect(model.requests.length).assertEqual(1);
    });
    it('rejectsAReceiptStillPresentInTheOutbox', 0, async () => {
      const data = emptyData(); const state = thread({ content: 'done', steps: [{ content: 'done', tools: [], steering: input('same') }] });
      state.pendingInputs = [input('same')]; data.threads = [state];
      await failure(async () => { parseAppData(JSON.stringify(data)); }, '同时');
    });
  });
}
