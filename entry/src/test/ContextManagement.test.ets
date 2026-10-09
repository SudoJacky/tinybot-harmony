import { describe, expect, it } from '@ohos/hypium';
import { AgentTurn, ModelMessage, ModelTurn, ToolDefinition } from '../main/ets/model/Agent';
import { MessageData, ThreadData, emptyData, parseAppData } from '../main/ets/model/Conversation';
import { CompactionPlan, contextSettings, contextInputBudget, estimateContextTokens, estimateTextTokens,
  prepareCompaction, threadHistory } from '../main/ets/model/ConversationContext';
import { matchingThreads, threadTitle } from '../main/ets/model/SessionManagement';
import { compactContext } from '../main/ets/services/ContextCompactor';
import { prepareSessionContext } from '../main/ets/services/SessionContext';
import { Cancellation } from '../main/ets/services/Cancellation';
import { ModelRequestOptions, ModelSession } from '../main/ets/services/providers/Provider';
import { runAgentLoop, AgentTools } from '../main/ets/services/AgentLoop';
import { ContextTools } from '../main/ets/services/ContextTools';
import { threadEntries } from '../main/ets/model/ContextProjection';

function message(id: string, role: string, content: string): MessageData {
  return { id: id, role: role, content: content, status: 'complete', error: '' };
}

function fixture(): ThreadData {
  return { id: 'fixture', title: 'context', updatedAt: 1, messages: [
    message('u1', 'user', 'old question'), message('a1', 'assistant', 'old answer'),
    message('u2', 'user', 'recent question'), message('a2', 'assistant', 'recent answer')
  ] };
}

function rejects(action: () => void, fragment: string): void {
  let errorMessage = '';
  try { action(); } catch (error) { errorMessage = (error as Error).message; }
  expect(errorMessage.includes(fragment)).assertTrue();
}

async function rejectsAsync(action: () => Promise<void>, fragment: string): Promise<void> {
  let errorMessage = '';
  try { await action(); } catch (error) { errorMessage = (error as Error).message; }
  expect(errorMessage.includes(fragment)).assertTrue();
}

class SummaryModel implements ModelSession {
  requests: ModelMessage[][] = [];
  schemas: ToolDefinition[][] = [];
  limits: number[] = [];
  failure: string = '';
  tools: boolean = false;
  onRequest?: () => void;

  async stream(messages: ModelMessage[], tools: ToolDefinition[], cancellation: Cancellation,
    _onText: (text: string) => void, options?: ModelRequestOptions): Promise<ModelTurn> {
    this.requests.push(messages);
    this.schemas.push(tools);
    this.limits.push(options?.maxOutputTokens || 0);
    if (this.onRequest) { this.onRequest(); }
    cancellation.check();
    if (this.failure.length > 0) { throw new Error(this.failure); }
    return { content: '摘要 ' + this.requests.length, toolCalls: this.tools ? [
      { id: 'bad', type: 'function', function: { name: 'write_file', arguments: '{}' } }
    ] : [] };
  }
}

class NoTools implements AgentTools {
  definitions(): ToolDefinition[] { return []; }
  async execute(): Promise<string> { throw new Error('unexpected tool'); }
}

class LargeResultTools extends NoTools {
  writes: number = 0;
  async execute(): Promise<string> { this.writes++; return 'x'.repeat(16000); }
}

export default function contextTests(): void {
  describe('ContextManagement', () => {
    it('compactsInsideAnActiveTurnAndRetainsEveryFullReceiptAcrossReload', 0, async () => {
      const thread: ThreadData = { id: 'long', title: 'long', updatedAt: 1, messages: [message('u1', 'user', 'finish the task'),
        { id: 'a1', role: 'assistant', content: '', status: 'generating', error: '', steps: [] }] };
      for (let index = 0; index < 4; index++) {
        thread.messages[1].steps!.push({ content: 'x'.repeat(20000), uiValidation: '', tools: [{
          call: { id: 'call' + index, type: 'function', function: { name: 'write_file', arguments: JSON.stringify({ path: 'file' + index + '.txt', content: 'saved' }) } }, status: 'complete', output: 'receipt' + index
        }] });
      }
      const config = emptyData().config; config.contextWindow = 32768;
      const model = new SummaryModel(); let saves = 0;
      const history = await prepareSessionContext(thread, model, new Cancellation(), false, config, 'rules', [], async () => { saves++; }, () => {});
      expect(saves).assertEqual(1); expect((thread.compaction?.firstKeptStep || 0) > 0).assertTrue();
      expect(history.some((item) => item.content === 'finish the task')).assertTrue();
      expect(estimateContextTokens(history) <= contextInputBudget(32768)).assertTrue();
      const data = emptyData(); data.threads = [thread]; data.activeThreadId = thread.id;
      const restored = parseAppData(JSON.stringify(data)).threads[0];
      expect(restored.messages[1].steps?.length).assertEqual(4);
      expect(restored.messages[1].steps?.[0].tools[0].output).assertEqual('receipt0');
      expect(restored.compaction?.fileOperations?.modifiedFiles.includes('file0.txt')).assertTrue();
      expect(restored.compaction?.fileOperations?.modifiedFiles.length).assertEqual(restored.compaction?.firstKeptStep);
      expect(threadHistory(restored, 'rules').some((item) => item.toolCallId === 'call3')).assertTrue();
    });
    it('projectsLargeResultsWithoutDiscardingTheirReadableOriginals', 0, async () => {
      const thread = fixture(); const full = '中'.repeat(20000) + 'END';
      thread.messages[3].steps = [{ content: '', tools: [{ call: { id: 'large', type: 'function', function: { name: 'execute_code', arguments: '{}' } }, status: 'complete', output: full }] }];
      const config = emptyData().config; config.contextWindow = 8192;
      const tools = new ContextTools(new NoTools(), () => threadEntries(thread), 8192);
      const history = await prepareSessionContext(thread, new SummaryModel(), new Cancellation(), false, config, '', tools.definitions(), async () => {}, () => {});
      const preview = history.find((item) => item.toolCallId === 'large');
      expect(preview?.content.includes('"contextPreview":true')).assertTrue();
      const page = await tools.execute({ id: 'read', type: 'function', function: { name: 'read_tool_result', arguments: '{"messageId":"a2","callId":"large","offset":20000}' } }, new Cancellation());
      expect(page.includes('"content":"END"')).assertTrue();
      expect(thread.messages[3].steps?.[0].tools[0].output).assertEqual(full);
    });
    it('compactsBeforePiReserveIsConsumedAndUsesSeparateSummaryBudget', 0, async () => {
      const thread = fixture();
      for (const item of thread.messages) { item.content = 'x'.repeat(18000); }
      const config = emptyData().config; config.contextWindow = 32768;
      const before = estimateContextTokens(threadHistory(thread, ''));
      expect(before > contextInputBudget(32768) && before < 32768 - 4096).assertTrue();
      const model = new SummaryModel(); let saved = 0;
      const history = await prepareSessionContext(thread, model, new Cancellation(), false, config, '', [],
        async () => { saved++; }, () => {});
      expect(saved).assertEqual(1);
      expect(model.limits[0]).assertEqual(4096);
      expect(thread.messages.length).assertEqual(4);
      expect(estimateContextTokens(history) < contextInputBudget(32768)).assertTrue();
    });
    it('reservesPiHeadroomAndKeepsRecentHistoryWithoutStarvingSmallWindows', 0, () => {
      const config = emptyData().config;
      expect(contextInputBudget(1000000)).assertEqual(983616);
      expect(contextSettings(config).keepRecent).assertEqual(20000);
      config.model = 'unknown';
      expect(contextInputBudget(contextSettings(config).window)).assertEqual(183616);
      config.contextWindow = 8192;
      expect(contextInputBudget(contextSettings(config).window)).assertEqual(4096);
      expect(contextSettings(config).keepRecent).assertEqual(2048);
    });
    it('keepsCurrentPromptWhileReplyIsGenerating', 0, () => {
      const thread = fixture();
      thread.messages.push(message('u3', 'user', 'current prompt'));
      thread.messages.push({ id: 'a3', role: 'assistant', content: 'partial', status: 'generating', error: '' });
      const history = threadHistory(thread, 'system');
      expect(history[history.length - 1].content).assertEqual('current prompt');
      expect(history.some((item: ModelMessage) => item.content === 'partial')).assertFalse();
    });
    it('retainsToolPairsAndFullHistoryAcrossCompactionReload', 0, () => {
      const thread = fixture();
      thread.messages[3].steps = [{ content: 'reading', tools: [{
        call: { id: 'read1', type: 'function', function: { name: 'read_file', arguments: '{"path":"a.txt"}' } },
        status: 'complete', output: '{"content":"saved"}'
      }] }];
      const plan = prepareCompaction(thread, contextSettings(emptyData().config));
      expect(plan?.firstKeptMessageId).assertEqual('u2');
      thread.compaction = { summary: 'old context', firstKeptMessageId: 'u2', tokensBefore: 100, createdAt: 1 };
      const data = emptyData();
      data.threads = [thread];
      data.activeThreadId = thread.id;
      const restored = parseAppData(JSON.stringify(data)).threads[0];
      expect(restored.messages.length).assertEqual(4);
      const history = threadHistory(restored, 'system');
      expect(history[0].content).assertEqual('system');
      expect(history[1].role).assertEqual('user');
      expect(history[2].content).assertEqual('recent question');
      expect(history[3].toolCalls?.[0].id).assertEqual('read1');
      expect(history[4].toolCallId).assertEqual('read1');
      expect(history.some((item: ModelMessage) => item.content === 'old question')).assertFalse();
    });
    it('repeatedCompactionStartsAtPreviousBoundaryAndKeepsNewPrompt', 0, () => {
      const thread = fixture();
      thread.compaction = { summary: 'previous', firstKeptMessageId: 'u2', tokensBefore: 20, createdAt: 1 };
      thread.messages.push(message('u3', 'user', 'third'), message('a3', 'assistant', 'answer'));
      thread.messages.push(message('u4', 'user', 'current'));
      thread.messages.push({ id: 'a4', role: 'assistant', content: '', status: 'generating', error: '' });
      const plan = prepareCompaction(thread, contextSettings(emptyData().config));
      expect(plan?.firstKeptMessageId).assertEqual('u3');
      expect(plan?.previousSummary).assertEqual('previous');
      expect(plan?.messages[0].content).assertEqual('recent question');
      expect(plan?.messages.some((item: ModelMessage) => item.content === 'current')).assertFalse();
    });
    it('preservesInterruptedToolEffectsInSummarizationInput', 0, () => {
      const thread = fixture();
      thread.messages[1].status = 'stopped';
      thread.messages[1].steps = [{ content: '', tools: [{
        call: { id: 'write1', type: 'function', function: { name: 'write_file', arguments: '{"path":"written.txt","content":"ok"}' } },
        status: 'complete', output: '{"written":true}'
      }] }];
      const plan = prepareCompaction(thread, contextSettings(emptyData().config));
      expect(plan?.messages.some((item: ModelMessage) => item.toolCallId === 'write1')).assertTrue();
      expect(plan?.messages[plan.messages.length - 1].content.includes('不要假设文件操作已经回滚')).assertTrue();
    });
    it('migratesLegacySettingsAndRejectsInvalidBoundaries', 0, () => {
      const data = emptyData();
      data.config.contextWindow = undefined;
      data.config.autoCompact = undefined;
      expect(contextSettings(parseAppData(JSON.stringify(data)).config).window).assertEqual(1000000);
      data.config.model = 'unknown-model';
      expect(contextSettings(parseAppData(JSON.stringify(data)).config).window).assertEqual(200000);
      data.config.contextWindow = 32768;
      expect(contextSettings(parseAppData(JSON.stringify(data)).config).window).assertEqual(32768);
      data.threads = [fixture()];
      data.threads[0].compaction = { summary: 'bad', firstKeptMessageId: 'a1', tokensBefore: 1, createdAt: 1 };
      rejects(() => { parseAppData(JSON.stringify(data)); }, '边界');
      data.threads[0].compaction = undefined;
      data.config.contextWindow = 4096;
      rejects(() => { parseAppData(JSON.stringify(data)); }, '上下文窗口');
    });
    it('countsChineseReasoningSchemasAndToolArguments', 0, () => {
      expect(estimateTextTokens('中文')).assertEqual(4);
      const base = estimateContextTokens([{ role: 'assistant', content: '' }]);
      const extra = estimateContextTokens([{ role: 'assistant', content: '', reasoningContent: '中文',
        toolCalls: [{ id: 'x', type: 'function', function: { name: 'read_file', arguments: '{"path":"a"}' } }] }]);
      expect(extra > base + 4).assertTrue();
    });
    it('batchesOversizedHistoryWithoutTruncationOrTools', 0, async () => {
      const model = new SummaryModel();
      const transcript = 'older'.repeat(12000) + 'END_OF_HISTORY';
      const plan: CompactionPlan = { firstKeptMessageId: 'u2', messages: [{ role: 'user', content: transcript }],
        previousSummary: 'previous checkpoint', tokensBefore: 30000 };
      const settings = contextSettings({ configured: false, providerId: 'test', baseUrl: '', model: '',
        systemPrompt: '', credentialAlias: '', contextWindow: 8192 });
      let batches = 0;
      const result = await compactContext(plan, settings, model, new Cancellation(), (batch: number) => { batches = batch; });
      expect(batches > 1).assertTrue();
      let combined = '';
      for (let index = 0; index < model.requests.length; index++) {
        const payload = JSON.parse(model.requests[index][1].content) as Record<string, string>;
        combined += payload['conversation'];
        expect(model.schemas[index].length).assertEqual(0);
        expect(model.limits[index]).assertEqual(4096);
        expect(estimateContextTokens(model.requests[index]) <= 4096).assertTrue();
        if (index > 0) { expect(payload['previousSummary']).assertEqual('摘要 ' + index); }
      }
      expect(combined).assertEqual(JSON.stringify(plan.messages[0]));
      expect(result.firstKeptMessageId).assertEqual('u2');
    });
    it('failsAndCancelsWithoutMutatingTheInputCheckpoint', 0, async () => {
      const plan = prepareCompaction(fixture(), contextSettings(emptyData().config)) as CompactionPlan;
      const before = JSON.stringify(plan);
      const model = new SummaryModel();
      model.failure = 'upstream failed';
      await rejectsAsync(async () => { await compactContext(plan, contextSettings(emptyData().config), model,
        new Cancellation(), () => {}); }, 'upstream failed');
      model.failure = '';
      const cancellation = new Cancellation();
      model.onRequest = () => cancellation.cancel();
      await rejectsAsync(async () => { await compactContext(plan, contextSettings(emptyData().config), model,
        cancellation, () => {}); }, '停止');
      expect(JSON.stringify(plan)).assertEqual(before);
    });
    it('rejectsToolCallsInSummaryResponses', 0, async () => {
      const plan = prepareCompaction(fixture(), contextSettings(emptyData().config)) as CompactionPlan;
      const model = new SummaryModel();
      model.tools = true;
      await rejectsAsync(async () => { await compactContext(plan, contextSettings(emptyData().config), model,
        new Cancellation(), () => {}); }, '有效');
    });
    it('enforcesBudgetBeforeCallingTheModel', 0, async () => {
      const model = new SummaryModel();
      const turn: AgentTurn = { content: '', steps: [] };
      await rejectsAsync(async () => {
        await runAgentLoop({ model: model, tools: new NoTools(), messages: [{ role: 'user', content: '中'.repeat(3000) }],
          turn: turn, maxSteps: 1, contextWindow: 8192 }, new Cancellation(), { event: () => {}, checkpoint: async () => {} });
      }, '上下文预算');
      expect(model.requests.length).assertEqual(0);
    });
    it('retainsCommittedToolResultsWhenTheNextRequestExceedsBudget', 0, async () => {
      const model = new SummaryModel();
      model.tools = true;
      const tools = new LargeResultTools();
      const turn: AgentTurn = { content: '', steps: [] };
      const saved: string[] = [];
      await rejectsAsync(async () => {
        await runAgentLoop({ model: model, tools: tools, messages: [{ role: 'user', content: 'write' }],
          turn: turn, maxSteps: 2, contextWindow: 8192 }, new Cancellation(), {
          event: () => {}, checkpoint: async () => { saved.push(JSON.stringify(turn)); }
        });
      }, '上下文预算');
      expect(model.requests.length).assertEqual(1);
      expect(tools.writes).assertEqual(1);
      expect(turn.steps[0].tools[0].status).assertEqual('complete');
      expect(turn.steps[0].tools[0].output.length).assertEqual(16000);
      const durable = JSON.parse(saved[saved.length - 1]) as AgentTurn;
      expect(JSON.stringify(durable.steps[0].tools)).assertEqual(JSON.stringify(turn.steps[0].tools));
    });
  });
  describe('SessionManagement', () => {
    it('searchesTitlesAndFullTextAndSeparatesArchives', 0, () => {
      const active = fixture();
      const archived = fixture(); archived.id = 'archived'; archived.archived = true;
      expect(matchingThreads([active, archived], 'OLD ANSWER', false).length).assertEqual(1);
      expect(matchingThreads([active, archived], 'context', true)[0].id).assertEqual('archived');
      expect(matchingThreads([active], 'missing', false).length).assertEqual(0);
    });
    it('pinsBeforeRecencyWithoutMutatingOriginalOrder', 0, () => {
      const old = fixture(); old.id = 'old'; old.pinned = true;
      const recent = fixture(); recent.id = 'recent'; recent.updatedAt = 100;
      const threads = [recent, old];
      expect(matchingThreads(threads, '', false)[0].id).assertEqual('old');
      expect(threads[0].id).assertEqual('recent');
    });
    it('roundTripsDraftsNamesAndArchiveMetadata', 0, () => {
      const data = emptyData();
      const thread = fixture();
      thread.title = threadTitle('  renamed  '); thread.titleEdited = true;
      thread.pinned = true; thread.archived = true; thread.draft = 'unfinished input';
      data.threads = [thread];
      const restored = parseAppData(JSON.stringify(data)).threads[0];
      expect(restored.title).assertEqual('renamed');
      expect(restored.draft).assertEqual('unfinished input');
      expect(restored.pinned).assertTrue();
      expect(restored.archived).assertTrue();
      rejects(() => { threadTitle('  '); }, '名称');
      rejects(() => { threadTitle('x'.repeat(81)); }, '名称');
      thread.draft = 'x'.repeat(24001);
      rejects(() => { parseAppData(JSON.stringify(data)); }, '管理数据');
    });
  });
}
