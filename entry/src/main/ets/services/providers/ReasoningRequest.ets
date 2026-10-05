import { t } from '../../model/I18n';
import { reasoningEfforts, adaptiveThinkingModel } from '../../model/ReasoningEffort';
import { ChatRequest } from './ChatCompletionsProtocol';
import { ResponsesRequest, AnthropicRequest } from './WireProtocols';

export function applyReasoningEffort(protocol: string, model: string, effort: string | undefined, body: Object): void {
  if (!effort || effort === 'default') return;
  if (!reasoningEfforts(protocol, model).includes(effort)) {
    throw new Error(t('当前模型或协议不支持此推理强度设置。'));
  }
  if (protocol === 'chat-completions') (body as ChatRequest).reasoning_effort = effort;
  else if (protocol === 'responses') {
    const request = body as ResponsesRequest;
    request.reasoning = { summary: request.reasoning?.summary, effort: effort };
  }
  else if (protocol === 'anthropic-messages') {
    const request = body as AnthropicRequest;
    request.output_config = { effort: effort };
    if (adaptiveThinkingModel(model)) request.thinking = { type: 'adaptive' };
    // Opus 4.5 effort is also valid without extended thinking. Do not invent a budget_tokens mapping.
  }
}
