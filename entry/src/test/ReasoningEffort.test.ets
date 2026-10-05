import { describe, expect, it } from '@ohos/hypium';
import { reasoningEfforts, supportsReasoningEffort, isHighestReasoningEffort } from '../main/ets/model/ReasoningEffort';
import { AgentStep, MAX_REASONING_CONTENT, ModelMessage, ToolExecution, stepMessages, validateSteps } from '../main/ets/model/Agent';
import { validateAnthropicContent } from '../main/ets/model/AnthropicContent';
import { applyReasoningEffort } from '../main/ets/services/providers/ReasoningRequest';
import { chatRequest } from '../main/ets/services/providers/ChatCompletionsProtocol';
import { responsesRequest, anthropicRequest } from '../main/ets/services/providers/WireProtocols';
import { AnthropicStream, ResponsesStream } from '../main/ets/services/providers/EventStreams';

function rejects(action: () => void): void {
  let rejected = false;
  try { action(); } catch (_) { rejected = true; }
  expect(rejected).assertTrue();
}

const THINKING_WIRE: string = [
  '{"type":"message_start"}',
  '{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}',
  '{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Consider the tool."}}',
  '{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"signed-"}}',
  '{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"opaque"}}',
  '{"type":"content_block_stop","index":0}',
  '{"type":"content_block_start","index":1,"content_block":{"type":"redacted_thinking","data":"encrypted-payload"}}',
  '{"type":"content_block_stop","index":1}',
  '{"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}',
  '{"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"Checking."}}',
  '{"type":"content_block_stop","index":2}',
  '{"type":"content_block_start","index":3,"content_block":{"type":"tool_use","id":"call_1","name":"read_file","input":{}}}',
  '{"type":"content_block_delta","index":3,"delta":{"type":"input_json_delta","partial_json":"{\\\"path\\\":\\\"a.txt\\\"}"}}',
  '{"type":"content_block_stop","index":3}',
  '{"type":"message_delta","delta":{"stop_reason":"tool_use"}}',
  '{"type":"message_stop"}'
].map((event: string) => 'data: ' + event + '\n\n').join('');

const RESPONSES_THINKING: string = [
  '{"type":"response.reasoning_summary_text.delta","output_index":0,"summary_index":0,"delta":"先检查"}',
  '{"type":"response.reasoning_summary_text.delta","output_index":0,"summary_index":0,"delta":"输入。"}',
  '{"type":"response.reasoning_summary_text.done","output_index":0,"summary_index":0,"text":"先检查输入。"}',
  '{"type":"response.reasoning_summary_text.delta","output_index":0,"summary_index":1,"delta":"再核对结果。"}',
  '{"type":"response.reasoning_summary_text.done","output_index":0,"summary_index":1,"text":"再核对结果。"}',
  '{"type":"response.output_text.delta","delta":"完成"}',
  '{"type":"response.completed","response":{"status":"completed","output":[{"type":"reasoning","summary":[{"type":"summary_text","text":"先检查输入。"},{"type":"summary_text","text":"再核对结果。"}]},{"type":"message","content":[{"type":"output_text","text":"完成"}]}]}}'
].map((event: string) => 'data: ' + event + '\n\n').join('');

export default function reasoningEffortTests(): void {
  describe('ReasoningEffort', () => {
    it('highlightsOnlyTheExplicitHighestSupportedModelLevel', 0, () => {
      expect(isHighestReasoningEffort('responses', 'gpt-5', 'high')).assertTrue();
      expect(isHighestReasoningEffort('responses', 'gpt-5.2', 'xhigh')).assertTrue();
      expect(isHighestReasoningEffort('responses', 'gpt-5.2', 'high')).assertFalse();
      expect(isHighestReasoningEffort('responses', 'gpt-5.2', 'max')).assertFalse();
      expect(isHighestReasoningEffort('anthropic-messages', 'claude-opus-4-6', 'max')).assertTrue();
      expect(isHighestReasoningEffort('anthropic-messages', 'claude-opus-4-6', 'default')).assertFalse();
      expect(isHighestReasoningEffort('anthropic-messages', 'claude-haiku-4-5', 'high')).assertFalse();
    });
    it('usesModelSpecificStandardEffortLevels', 0, () => {
      expect(reasoningEfforts('responses', 'gpt-5.2').join(',')).assertEqual('default,none,low,medium,high,xhigh');
      expect(reasoningEfforts('responses', 'gpt-6-astra').join(',')).assertEqual('default,low,medium,high,xhigh,max');
      expect(reasoningEfforts('responses', 'gpt-5').includes('minimal')).assertTrue();
      expect(reasoningEfforts('responses', 'gpt-5-pro').join(',')).assertEqual('default,high');
      expect(reasoningEfforts('anthropic-messages', 'claude-opus-4-6').join(',')).assertEqual('default,low,medium,high,max');
      expect(reasoningEfforts('anthropic-messages', 'claude-sonnet-4-6').includes('max')).assertTrue();
      expect(reasoningEfforts('anthropic-messages', 'claude-opus-4-5-20251101').includes('max')).assertFalse();
      expect(reasoningEfforts('anthropic-messages', 'claude-opus-5-5').join(',')).assertEqual('default,low,medium,high,xhigh,max');
      expect(supportsReasoningEffort('anthropic-messages', 'claude-haiku-4-5')).assertFalse();
      expect(supportsReasoningEffort('chat-completions', 'gpt-4.1')).assertFalse();
      expect(reasoningEfforts('anthropic-messages', 'custom-alias').includes('none')).assertFalse();
    });
    it('writesTheCorrectWireFieldForAllThreeProtocols', 0, () => {
      const chat = chatRequest('gpt-5', [], []);
      applyReasoningEffort('chat-completions', 'gpt-5', 'minimal', chat);
      expect(chat.reasoning_effort).assertEqual('minimal');
      const responses = responsesRequest('gpt-5.2', [], []);
      applyReasoningEffort('responses', 'gpt-5.2', 'xhigh', responses);
      expect(responses.reasoning?.effort).assertEqual('xhigh');
      expect(responses.reasoning?.summary).assertEqual('auto');
      const claude = anthropicRequest('claude-opus-4-6', [], []);
      applyReasoningEffort('anthropic-messages', claude.model, 'max', claude);
      expect(claude.output_config?.effort).assertEqual('max');
      expect(claude.thinking?.type).assertEqual('adaptive');
      expect(JSON.stringify(claude).includes('reasoning_effort')).assertFalse();
      expect(JSON.stringify(claude).includes('budget_tokens')).assertFalse();
      const legacy = anthropicRequest('claude-opus-4-5', [], []);
      applyReasoningEffort('anthropic-messages', legacy.model, 'high', legacy);
      expect(legacy.output_config?.effort).assertEqual('high');
      expect(legacy.thinking === undefined).assertTrue();
    });
    it('requestsResponsesSummariesWithoutForcingDefaultEffortOrChangingNonReasoningModels', 0, () => {
      const request = responsesRequest('gpt-5.2', [], []);
      applyReasoningEffort('responses', request.model, 'default', request);
      expect(request.reasoning?.summary).assertEqual('auto');
      expect(request.reasoning?.effort === undefined).assertTrue();
      expect(responsesRequest('gpt-4.1', [], []).reasoning === undefined).assertTrue();
      expect(responsesRequest('custom-reasoning-alias', [], []).reasoning?.summary).assertEqual('auto');
    });
    it('streamsResponsesThinkingSeparatelyAndDeduplicatesDoneAndCompletedSnapshots', 0, () => {
      let answer = ''; let thinking = '';
      const parser = new ResponsesStream((delta: string) => { answer += delta; }, (delta: string) => { thinking += delta; });
      for (let offset = 0; offset < RESPONSES_THINKING.length; offset += 7) { parser.push(RESPONSES_THINKING.slice(offset, offset + 7)); }
      const turn = parser.finish();
      expect(answer).assertEqual('完成'); expect(turn.content).assertEqual('完成');
      expect(thinking).assertEqual('先检查输入。\n\n再核对结果。'); expect(turn.reasoningContent).assertEqual(thinking);
      const step: AgentStep = { content: turn.content, reasoningContent: turn.reasoningContent, tools: [] };
      const restored = JSON.parse(JSON.stringify(step)) as AgentStep; validateSteps([restored]);
      expect(restored.reasoningContent).assertEqual(thinking);
      // Visible summaries are local display data, not invented assistant input or encrypted reasoning.
      expect(JSON.stringify(responsesRequest('gpt-5.2', stepMessages(restored), [])).includes('先检查输入')).assertFalse();
    });
    it('acceptsResponsesTextualThinkingAndFinalOnlySummariesWithoutShowingEncryptedData', 0, () => {
      let thinking = '';
      const raw = new ResponsesStream(() => {}, (delta: string) => { thinking += delta; });
      raw.push('data: {"type":"response.reasoning_text.delta","output_index":0,"content_index":0,"delta":"检查"}\n\n');
      raw.push('data: {"type":"response.reasoning_text.done","output_index":0,"content_index":0,"text":"检查文件"}\n\n');
      raw.push('data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"reasoning","summary":[],"content":[{"type":"reasoning_text","text":"检查文件"}],"encrypted_content":"opaque"},{"type":"reasoning","summary":[{"type":"summary_text","text":"准备调用工具"}]},{"type":"function_call","call_id":"call_1","name":"read_file","arguments":"{}"}]}}\n\n');
      expect(thinking).assertEqual('检查文件\n\n准备调用工具'); expect(raw.finish().reasoningContent).assertEqual(thinking);
      expect(raw.finish().toolCalls.length).assertEqual(1);
      const opaque = new ResponsesStream(() => {});
      opaque.push('data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"reasoning","summary":[],"encrypted_content":"opaque"},{"type":"function_call","call_id":"call_1","name":"read_file","arguments":"{}"}]}}\n\n');
      expect(opaque.finish().reasoningContent === undefined).assertTrue();
    });
    it('rejectsMalformedContradictoryAndOverLimitResponsesThinking', 0, () => {
      for (const event of ['{"type":"response.reasoning_summary_text.delta","delta":42}',
        '{"type":"response.reasoning_text.delta","output_index":-1,"delta":"text"}',
        '{"type":"response.reasoning_text.done"}']) {
        rejects(() => new ResponsesStream(() => {}).push('data: ' + event + '\n\n'));
      }
      const parser = new ResponsesStream(() => {});
      parser.push('data: {"type":"response.reasoning_text.delta","delta":"partial"}\n\n');
      rejects(() => parser.push('data: {"type":"response.reasoning_text.done","text":"different"}\n\n'));
      const closed = new ResponsesStream(() => {});
      closed.push('data: {"type":"response.reasoning_text.done","text":"done"}\n\n');
      rejects(() => closed.push('data: {"type":"response.reasoning_text.delta","delta":"late"}\n\n'));
      const oversized = new ResponsesStream(() => {});
      const chunk = 'data: {"type":"response.reasoning_summary_text.delta","delta":"' + 'a'.repeat(1024) + '"}\n\n';
      for (let index = 0; index < MAX_REASONING_CONTENT / 1024; index++) { oversized.push(chunk); }
      rejects(() => oversized.push(chunk));
    });
    it('omitsDefaultsAndRejectsInvalidCrossProviderLevels', 0, () => {
      const claude = anthropicRequest('claude-opus-4-6', [], []);
      applyReasoningEffort('anthropic-messages', claude.model, 'default', claude);
      expect(claude.thinking === undefined && claude.output_config === undefined).assertTrue();
      rejects(() => applyReasoningEffort('anthropic-messages', claude.model, 'none', claude));
      rejects(() => applyReasoningEffort('anthropic-messages', claude.model, 'xhigh', claude));
      rejects(() => applyReasoningEffort('responses', 'gpt-6-astra', 'none', responsesRequest('gpt-6-astra', [], [])));
      const responses = responsesRequest('gpt-5.2', [], []);
      applyReasoningEffort('responses', 'gpt-5.2', 'none', responses);
      expect(responses.reasoning?.effort).assertEqual('none');
    });
    it('replaysSignedAndRedactedThinkingAcrossToolCallsAndPersistence', 0, () => {
      let text = ''; let reasoning = '';
      const parser = new AnthropicStream((delta) => { text += delta; }, (delta) => { reasoning += delta; });
      for (let offset = 0; offset < THINKING_WIRE.length; offset += 7) parser.push(THINKING_WIRE.slice(offset, offset + 7));
      const turn = parser.finish();
      expect(text).assertEqual('Checking.'); expect(reasoning).assertEqual('Consider the tool.');
      expect(turn.anthropicContent?.[0].signature).assertEqual('signed-opaque');
      expect(turn.anthropicContent?.[1].data).assertEqual('encrypted-payload');
      const step: AgentStep = { content: turn.content, reasoningContent: turn.reasoningContent, anthropicContent: turn.anthropicContent,
        tools: turn.toolCalls.map((call): ToolExecution => { return { call: call, status: 'complete', output: 'file content' }; }) };
      const restored = JSON.parse(JSON.stringify(step)) as AgentStep; validateSteps([restored]);
      const history: ModelMessage[] = [{ role: 'user', content: 'read a file' }];
      history.push(...stepMessages(restored));
      const request = anthropicRequest('claude-opus-4-6', history, []);
      expect(JSON.stringify(request.messages[1].content)).assertEqual(JSON.stringify(turn.anthropicContent));
      expect(request.messages[2].content[0].tool_use_id).assertEqual('call_1');
      expect(JSON.stringify(responsesRequest('gpt-5.2', history, [])).includes('signed-opaque')).assertFalse();
    });
    it('rejectsUnsignedTruncatedAndOversizedThinking', 0, () => {
      const missing = THINKING_WIRE.replace('"signature":"signed-"', '"signature":""').replace('"signature":"opaque"', '"signature":""');
      const parser = new AnthropicStream(() => {}); parser.push(missing);
      rejects(() => { parser.finish(); });
      const truncated = new AnthropicStream(() => {}); truncated.push(THINKING_WIRE.slice(0, -10));
      rejects(() => { truncated.finish(); });
      rejects(() => validateAnthropicContent([{ type: 'redacted_thinking', data: 'a'.repeat(2 * 1024 * 1024) }]));
    });
  });
}
