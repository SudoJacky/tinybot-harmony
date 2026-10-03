import { describe, expect, it } from '@ohos/hypium';
import { reasoningEfforts, supportsReasoningEffort, isHighestReasoningEffort } from '../main/ets/model/ReasoningEffort';
import { AgentStep, ModelMessage, ToolExecution, stepMessages, validateSteps } from '../main/ets/model/Agent';
import { validateAnthropicContent } from '../main/ets/model/AnthropicContent';
import { applyReasoningEffort } from '../main/ets/services/providers/ReasoningRequest';
import { chatRequest } from '../main/ets/services/providers/ChatCompletionsProtocol';
import { responsesRequest, anthropicRequest } from '../main/ets/services/providers/WireProtocols';
import { AnthropicStream } from '../main/ets/services/providers/EventStreams';

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
