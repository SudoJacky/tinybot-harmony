import { describe, expect, it } from '@ohos/hypium';
import { AgentStep, AgentTurn, ModelTurn, ToolCall, ToolDefinition, ModelMessage, validateSteps } from '../main/ets/model/Agent';
import { emptyData, parseAppData, requestHistory } from '../main/ets/model/Conversation';
import { runAgentLoop, LoopObserver, AgentTools } from '../main/ets/services/AgentLoop';
import { Cancellation } from '../main/ets/services/Cancellation';
import { ModelSession, ModelRequestOptions } from '../main/ets/services/providers/Provider';
import { toolPreview } from '../main/ets/model/ToolPresentation';
import { ChatStream } from '../main/ets/services/ChatStream';
import { chatRequest } from '../main/ets/services/providers/ChatCompletionsProtocol';
import { WorkspaceFiles, WorkspaceTools, workspaceRelativePath } from '../main/ets/services/WorkspaceTools';

const DONE = 'data: [DONE]\n\n';
const FINISH_TOOLS = 'data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}\n\n';
const FINISH_TEXT = 'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n';

interface IndexedCall extends ToolCall {
  index: number;
}

function call(id: string, name: string, args: string): ToolCall {
  return { id: id, type: 'function', function: { name: name, arguments: args } };
}

function toolWire(calls: ToolCall[]): string {
  const fragments = calls.map((item: ToolCall, index: number): IndexedCall => {
    return { index: index, id: item.id, type: item.type, function: item.function };
  });
  return 'data: {"choices":[{"index":0,"delta":{"tool_calls":' + JSON.stringify(fragments) + '}}]}\n\n' + FINISH_TOOLS + DONE;
}

function textWire(text: string): string {
  return 'data: {"choices":[{"index":0,"delta":{"content":' + JSON.stringify(text) + '}}]}\n\n' + FINISH_TEXT + DONE;
}

function rejects(action: () => void, fragment: string): void {
  let message = '';
  try { action(); } catch (error) { message = (error as Error).message; }
  expect(message.includes(fragment)).assertTrue();
}

async function rejectsAsync(action: () => Promise<void>, fragment: string): Promise<void> {
  let message = '';
  let rejected = false;
  try { await action(); } catch (error) { rejected = true; message = (error as Error).message; }
  expect(rejected).assertTrue();
  expect(message.includes(fragment)).assertTrue();
}

class ScriptModel implements ModelSession {
  requests: ModelMessage[][] = [];
  schemas: ToolDefinition[][] = [];
  cancelled: boolean = false;
  beforeReturn?: () => void;
  private scripts: string[];

  constructor(scripts: string[]) { this.scripts = scripts; }

  async stream(messages: ModelMessage[], tools: ToolDefinition[], cancellation: Cancellation,
    onText: (text: string) => void, options?: ModelRequestOptions): Promise<ModelTurn> {
    const unsubscribe = cancellation.onCancel(() => { this.cancelled = true; });
    this.requests.push(JSON.parse(JSON.stringify(messages)) as ModelMessage[]);
    this.schemas.push(tools);
    const stream = new ChatStream(onText, options?.onReasoning);
    const wire = this.scripts[this.requests.length - 1];
    if (!wire) { throw new Error('Unexpected extra provider request'); }
    for (let offset = 0; offset < wire.length; offset += 7) {
      stream.push(wire.slice(offset, offset + 7));
    }
    try {
      this.beforeReturn?.();
      return stream.finish();
    } finally {
      unsubscribe();
    }
  }
}

class MemoryFiles implements WorkspaceFiles {
  values: Map<string, string> = new Map<string, string>();
  calls: string[] = [];
  afterWrite?: () => void;

  async list(path: string, cancellation: Cancellation): Promise<string> {
    cancellation.check();
    this.calls.push('list:' + path);
    return JSON.stringify(Array.from(this.values.keys()));
  }

  async read(path: string, cancellation: Cancellation): Promise<string> {
    cancellation.check();
    this.calls.push('read:' + path);
    const value = this.values.get(path);
    if (value === undefined) { throw new Error('file missing'); }
    return JSON.stringify({ content: value });
  }

  async write(path: string, content: string, cancellation: Cancellation): Promise<string> {
    cancellation.check();
    this.calls.push('write:' + path);
    this.values.set(path, content);
    this.afterWrite?.();
    return JSON.stringify({ written: true });
  }
}

function observer(): LoopObserver {
  return { event: () => {}, checkpoint: async () => {} };
}

function turn(): AgentTurn { return { content: '', steps: [] }; }
function history(): ModelMessage[] { return [{ role: 'user', content: 'test' }]; }

async function runLoop(model: ModelSession, tools: AgentTools, result: AgentTurn, observe: LoopObserver,
  cancellation: Cancellation = new Cancellation()): Promise<void> {
  await runAgentLoop({ model: model, tools: tools, messages: history(), turn: result, maxSteps: 8 }, cancellation, observe);
}

export default function agentTests(): void {
  describe('InlineToolPreview', () => {
    it('onlyShowsSuccessfulEditsAsChangesAndPreservesEmptyReplacements', 0, () => {
      const args = '{"path":"a.txt","oldText":"old","newText":""}';
      const success = toolPreview('edit_file', args, '{"written":true}', 'complete');
      expect(success.changed).assertTrue();
      expect(success.before).assertEqual('old');
      expect(success.after).assertEqual('');
      const failure = toolPreview('edit_file', args, '{"error":"missing"}', 'failed');
      expect(failure.changed).assertFalse();
      expect(failure.content).assertEqual('missing');
    });
    it('handlesMalformedResultsAndReturnsActualReadContent', 0, () => {
      expect(toolPreview('read_file', 'null', '{"content":null}', 'complete').content).assertEqual('{\n  "content": null\n}');
      expect(toolPreview('read_file', '{}', 'not json', 'complete').content).assertEqual('not json');
      const read = toolPreview('read_file', '{"path":"a"}', '{"content":"hello\\nworld","truncated":true}', 'complete');
      expect(read.content).assertEqual('hello\nworld');
      expect(read.truncated).assertTrue();
    });
  });
  describe('ToolStream', () => {
    it('streamsReasoningSeparatelyBeforeFinalResponse', 0, () => {
      let thoughts = ''; let answer = '';
      const stream = new ChatStream((text: string) => { answer += text; }, (text: string) => { thoughts += text; });
      const wire = 'data: {"choices":[{"index":0,"delta":{"reasoning_content":"正在分析"}}]}\n\n';
      for (const character of wire) { stream.push(character); }
      expect(thoughts).assertEqual('正在分析');
      expect(answer).assertEqual('');
      stream.push(textWire('answer'));
      expect(stream.finish().reasoningContent).assertEqual(thoughts);
      expect(answer).assertEqual('answer');
    });
    it('rejectsInvalidOrLateReasoningInsteadOfSilentlyDiscardingIt', 0, () => {
      const invalid = 'data: {"choices":[{"index":0,"delta":{"reasoning_content":42}}]}\n\n';
      rejects(() => { new ChatStream(() => {}).push(invalid); }, '推理');
      const stream = new ChatStream(() => {});
      stream.push(FINISH_TEXT);
      rejects(() => stream.push(invalid.replace('42', '"late"')), '推理');
      const steps = JSON.parse('[{"content":"ok","tools":[],"reasoningContent":42}]') as AgentStep[];
      rejects(() => validateSteps(steps), '损坏');
    });
    it('assemblesInterleavedCallsAndFragmentedUnicodeArguments', 0, () => {
      const first = 'data: {"choices":[{"index":0,"delta":{"tool_calls":[' +
        '{"index":0,"id":"a","type":"function","function":{"name":"write_","arguments":"{\\"path\\":\\"a.txt\\","}},' +
        '{"index":1,"id":"b","type":"function","function":{"name":"read_file","arguments":"{\\"path\\":"}}]}}]}\n\n';
      const second = 'data: {"choices":[{"index":0,"delta":{"tool_calls":[' +
        '{"index":1,"function":{"arguments":"\\"a.txt\\"}"}},' +
        '{"index":0,"function":{"name":"file","arguments":"\\"content\\":\\"你好🌱\\"}"}}]}}]}\n\n';
      const wire = first + second + FINISH_TOOLS + DONE;
      for (let boundary = 1; boundary < wire.length; boundary++) {
        const parser = new ChatStream(() => {});
        parser.push(wire.slice(0, boundary));
        parser.push(wire.slice(boundary));
        const result = parser.finish();
        expect(result.toolCalls.length).assertEqual(2);
        expect(result.toolCalls[0].function.name).assertEqual('write_file');
        expect(result.toolCalls[0].function.arguments).assertEqual('{"path":"a.txt","content":"你好🌱"}');
        expect(result.toolCalls[1].function.arguments).assertEqual('{"path":"a.txt"}');
      }
    });
    it('rejectsDuplicateIdsGapsAndMismatchedTermination', 0, () => {
      const duplicate = new ChatStream(() => {});
      duplicate.push(toolWire([call('same', 'list_files', '{}'), call('same', 'read_file', '{}')]));
      rejects(() => { duplicate.finish(); }, '重复');
      const gap = new ChatStream(() => {});
      gap.push(toolWire([call('a', 'list_files', '{}')]).replace('"index":0,"id"', '"index":1,"id"'));
      rejects(() => { gap.finish(); }, '索引');
      const mismatch = new ChatStream(() => {});
      mismatch.push(toolWire([call('a', 'list_files', '{}')]).replace(FINISH_TOOLS, FINISH_TEXT));
      rejects(() => { mismatch.finish(); }, '不匹配');
    });
    it('rejectsOversizedBatchAndArguments', 0, () => {
      const calls: ToolCall[] = [];
      for (let index = 0; index < 9; index++) { calls.push(call('a' + index, 'list_files', '{}')); }
      rejects(() => { new ChatStream(() => {}).push(toolWire(calls)); }, '片段');
      rejects(() => { new ChatStream(() => {}).push(toolWire([call('a', 'write_file', 'x'.repeat(96 * 1024 + 1))])); }, '过大');
    });
  });

  describe('AgentLoop', () => {
    it('emitsReasoningBeforeModelEndAndKeepsPartialReasoningOnCancellation', 0, async () => {
      const wire = 'data: {"choices":[{"index":0,"delta":{"reasoning_content":"partial thought"}}]}\n\n';
      const model = new ScriptModel([wire + textWire('answer')]);
      const result = turn(); const cancellation = new Cancellation();
      let seen = '';
      const observe = observer();
      observe.event = (event) => {
        if (event.type === 'reasoning_delta') { seen = result.steps[0].reasoningContent || ''; cancellation.cancel(); }
      };
      try { await runLoop(model, new WorkspaceTools(new MemoryFiles()), result, observe, cancellation); } catch (_) {}
      expect(seen).assertEqual('partial thought');
      expect(result.steps[0].reasoningContent).assertEqual('partial thought');
      expect(result.content).assertEqual('');
    });
    it('preservesStreamedReasoningAcrossToolRoundsAndReloadWithoutDisplayingIt', 0, async () => {
      const reasoning = 'data: {"choices":[{"index":0,"delta":{"reasoning_content":"fixture "}}]}\n\n' +
        'data: {"choices":[{"index":0,"delta":{"reasoning_content":"context"}}]}\n\n';
      const model = new ScriptModel([
        reasoning + toolWire([call('list', 'list_files', '{"path":"."}')]), textWire('done')
      ]);
      const result = turn();
      await runLoop(model, new WorkspaceTools(new MemoryFiles()), result, observer());
      expect(result.content).assertEqual('done');
      expect(result.steps[0].content).assertEqual('');
      expect(model.requests[1][1].reasoningContent).assertEqual('fixture context');
      const data = emptyData();
      data.activeThreadId = 'fixture';
      data.threads = [{ id: 'fixture', title: 'fixture', updatedAt: 1, messages: [
        { id: 'user', role: 'user', content: 'test', status: 'complete', error: '' },
        { id: 'assistant', role: 'assistant', content: result.content, status: 'complete', error: '', steps: result.steps }
      ] }];
      const restored = parseAppData(JSON.stringify(data));
      const replay = requestHistory(restored.threads[0].messages, 'system');
      const request = chatRequest('glm-5.3', replay, [], { replayReasoning: true });
      expect(request.messages[2].reasoning_content).assertEqual('fixture context');
      expect(request.messages[3].tool_call_id).assertEqual('list');
      expect(restored.threads[0].messages[1].content).assertEqual('done');
    });
    it('writesReadsAndAnswersAcrossProviderRoundsWithDurableReceipts', 0, async () => {
      const model = new ScriptModel([
        toolWire([call('write', 'write_file', '{"path":"notes/a.txt","content":"你好🌱"}')]),
        toolWire([call('read', 'read_file', '{"path":"notes/a.txt"}')]), textWire('已创建并核对。')
      ]);
      const files = new MemoryFiles();
      const result = turn();
      const saved: string[] = [];
      const observe: LoopObserver = { event: () => {}, checkpoint: async () => { saved.push(JSON.stringify(result)); } };
      await runLoop(model, new WorkspaceTools(files), result, observe);
      expect(result.content).assertEqual('已创建并核对。');
      expect(files.values.get('notes/a.txt')).assertEqual('你好🌱');
      expect(files.calls.join(',')).assertEqual('write:notes/a.txt,read:notes/a.txt');
      expect(saved.length).assertEqual(4);
      expect(saved[0].includes('"status":"running"')).assertTrue();
      expect(saved[1].includes('"status":"complete"')).assertTrue();
      expect(model.requests[1][1].toolCalls?.[0].id).assertEqual('write');
      expect(model.requests[1][2].toolCallId).assertEqual('write');
      expect(model.requests[2][4].content).assertEqual('{"content":"你好🌱"}');
      expect(model.schemas[0].some((tool) => tool.function.name === 'write_file')).assertTrue();
      expect(model.schemas[0].some((tool) => tool.function.name === 'search_file_content')).assertTrue();
    });
    it('runsBatchSequentiallyAndReturnsErrorsForModelCorrection', 0, async () => {
      const model = new ScriptModel([
        toolWire([call('bad', 'write_file', '{broken'), call('unknown', 'shell', '{}'), call('missing', 'read_file', '{"path":"missing"}')]),
        toolWire([call('write', 'write_file', '{"path":"ok","content":"saved"}'), call('read', 'read_file', '{"path":"ok"}')]),
        textWire('done')
      ]);
      const files = new MemoryFiles();
      const result = turn();
      await runLoop(model, new WorkspaceTools(files), result, observer());
      expect(model.requests[1][2].content.includes('JSON')).assertTrue();
      expect(model.requests[1][3].content.includes('不支持')).assertTrue();
      expect(model.requests[1][4].content.includes('file missing')).assertTrue();
      expect(files.calls.join(',')).assertEqual('read:missing,write:ok,read:ok');
      expect(result.steps[1].tools[1].status).assertEqual('complete');
    });
    it('neverExecutesCallsFromATruncatedStream', 0, async () => {
      const model = new ScriptModel([toolWire([call('a', 'write_file', '{"path":"a","content":"x"}')]).replace(DONE, '')]);
      const files = new MemoryFiles();
      await rejectsAsync(async () => { await runLoop(model, new WorkspaceTools(files), turn(), observer()); }, '结束标记');
      expect(files.calls.length).assertEqual(0);
    });
    it('cancelsTheProviderAndDoesNotDispatchReceivedCalls', 0, async () => {
      const model = new ScriptModel([toolWire([call('a', 'list_files', '{"path":"."}')])]);
      const files = new MemoryFiles();
      const cancellation = new Cancellation();
      model.beforeReturn = () => { cancellation.cancel(); };
      await rejectsAsync(async () => { await runLoop(model, new WorkspaceTools(files), turn(), observer(), cancellation); }, '停止');
      expect(model.cancelled).assertTrue();
      expect(files.calls.length).assertEqual(0);
      expect(model.requests.length).assertEqual(1);
    });
    it('retainsACommittedWriteWhenStoppedAndSkipsRemainingCalls', 0, async () => {
      const model = new ScriptModel([toolWire([
        call('a', 'write_file', '{"path":"a","content":"saved"}'), call('b', 'write_file', '{"path":"b","content":"not run"}')
      ])]);
      const files = new MemoryFiles();
      const result = turn();
      const cancellation = new Cancellation();
      files.afterWrite = () => { cancellation.cancel(); };
      await rejectsAsync(async () => { await runLoop(model, new WorkspaceTools(files), result, observer(), cancellation); }, '停止');
      expect(files.values.get('a')).assertEqual('saved');
      expect(files.values.has('b')).assertFalse();
      expect(result.steps[0].tools[0].status).assertEqual('complete');
      expect(result.steps[0].tools[1].status).assertEqual('cancelled');
      expect(model.requests.length).assertEqual(1);
    });
    it('doesNotPerformSideEffectsWhenCheckpointFails', 0, async () => {
      const model = new ScriptModel([toolWire([call('a', 'write_file', '{"path":"a","content":"x"}')])]);
      const files = new MemoryFiles();
      const observe: LoopObserver = { event: () => {}, checkpoint: async () => { throw new Error('disk full'); } };
      await rejectsAsync(async () => { await runLoop(model, new WorkspaceTools(files), turn(), observe); }, 'disk full');
      expect(files.calls.length).assertEqual(0);
    });
    it('boundsTheLoopAndDoesNotExecuteAnUnfollowableLastBatch', 0, async () => {
      const scripts: string[] = [];
      for (let index = 0; index < 8; index++) { scripts.push(toolWire([call('call_' + index, 'list_files', '{"path":"."}')])); }
      const model = new ScriptModel(scripts);
      const files = new MemoryFiles();
      const result = turn();
      await rejectsAsync(async () => { await runLoop(model, new WorkspaceTools(files), result, observer()); }, '8 次');
      expect(model.requests.length).assertEqual(8);
      expect(files.calls.length).assertEqual(7);
      expect(result.steps[7].tools[0].status).assertEqual('cancelled');
    });
    it('rejectsReusedCallIdsAcrossRounds', 0, async () => {
      const wire = toolWire([call('a', 'list_files', '{"path":"."}')]);
      const model = new ScriptModel([wire, wire]);
      const files = new MemoryFiles();
      await rejectsAsync(async () => { await runLoop(model, new WorkspaceTools(files), turn(), observer()); }, '重复');
      expect(files.calls.length).assertEqual(1);
    });
  });

  describe('WorkspaceToolBoundary', () => {
    it('rejectsEscapesAndMalformedArgumentsBeforeFileAccess', 0, async () => {
      const files = new MemoryFiles();
      const tools = new WorkspaceTools(files);
      for (const path of ['../other', 'a/../b', '/absolute', 'a//b', 'C:\\file', 'file://x', 'a\u0000b', '.tinybot-temp', 'a/.tinybot-temp', '', '.']) {
        await rejectsAsync(async () => { await tools.execute(call('a', 'read_file', JSON.stringify({ path: path })), new Cancellation()); }, path === '.' ? '路径' : '');
      }
      for (const args of ['null', '[]', '{"path":"a","extra":1}', '{"path":1}', '{"path":"a"}']) {
        await rejectsAsync(async () => { await tools.execute(call('a', 'write_file', args), new Cancellation()); }, '参数');
      }
      expect(files.calls.length).assertEqual(0);
      expect(workspaceRelativePath('.', true)).assertEqual('');
      expect(workspaceRelativePath('文档/笔记.txt', false)).assertEqual('文档/笔记.txt');
    });
  });

  describe('AgentHistory', () => {
    it('roundTripsToolCallsAndResultsWithoutFlatteningTheirProtocol', 0, () => {
      const steps: AgentStep[] = [
        { content: '先读取。', tools: [{ call: call('r', 'read_file', '{"path":"a"}'), status: 'complete', output: '{"content":"你好"}' }] },
        { content: '读取完成。', tools: [] }
      ];
      const data = emptyData();
      data.threads = [{ id: 't', title: 't', updatedAt: 1, messages: [
        { id: 'u', role: 'user', content: '读取', status: 'complete', error: '' },
        { id: 'a', role: 'assistant', content: '先读取。\n\n读取完成。', status: 'complete', error: '', steps: steps }
      ] }];
      const restored = parseAppData(JSON.stringify(data));
      const wire = requestHistory(restored.threads[0].messages, '');
      expect(wire.length).assertEqual(4);
      expect(wire[1].toolCalls?.[0].function.name).assertEqual('read_file');
      expect(wire[2].toolCallId).assertEqual('r');
      expect(wire[3].content).assertEqual('读取完成。');
    });
    it('recoversUnknownToolOutcomesAndReplaysReceiptsWithoutPartialAnswer', 0, () => {
      const data = emptyData();
      const steps: AgentStep[] = [{ content: '', tools: [
        { call: call('written', 'write_file', '{}'), status: 'complete', output: '{"written":true}' },
        { call: call('unknown', 'write_file', '{}'), status: 'running', output: '' },
        { call: call('not_started', 'write_file', '{}'), status: 'pending', output: '' }
      ] }, { content: 'partial unfinished answer', tools: [] }];
      data.threads = [{ id: 't', title: 't', updatedAt: 1, messages: [
        { id: 'u', role: 'user', content: '写文件', status: 'complete', error: '' },
        { id: 'a', role: 'assistant', content: 'partial unfinished answer', status: 'generating', error: '', steps: steps }
      ] }];
      const messages = parseAppData(JSON.stringify(data)).threads[0].messages;
      expect(messages[1].status).assertEqual('stopped');
      const wire = requestHistory(messages, '');
      expect(wire[2].content).assertEqual('{"written":true}');
      expect(wire[3].content.includes('结果未知')).assertTrue();
      expect(wire[4].content.includes('未执行')).assertTrue();
      expect(JSON.stringify(wire).includes('partial unfinished')).assertFalse();
    });
    it('rejectsCorruptToolReceipts', 0, () => {
      const data = emptyData();
      data.threads = [{ id: 't', title: 't', updatedAt: 1, messages: [
        { id: 'u', role: 'user', content: 'x', status: 'complete', error: '' },
        { id: 'a', role: 'assistant', content: '', status: 'complete', error: '', steps: [
          { content: '', tools: [{ call: call('a', 'read_file', '{}'), status: 'invented', output: '' }] }
        ] }
      ] }];
      rejects(() => { parseAppData(JSON.stringify(data)); }, '工具记录');
    });
  });
}
