import { ModelMessage, ToolCall, ToolDefinition } from '../../model/Agent';

export interface ChatWireMessage {
  role: string;
  content: string;
  tool_calls?: ToolCall[];
  tool_call_id?: string;
  reasoning_content?: string;
}

export interface ChatCompletionsOptions {
  allowHttp?: boolean;
  replayReasoning?: boolean;
}

export interface ChatRequest {
  model: string;
  messages: ChatWireMessage[];
  stream: boolean;
  tools?: ToolDefinition[];
  tool_choice?: string;
  max_tokens?: number;
}

export function completionUrl(baseUrl: string, allowHttp: boolean = false): string {
  const base = baseUrl.trim().replace(/\/+$/, '');
  if (!/^https?:\/\/[^\s/?#@:\\]+(?::\d+)?(?:\/[^\s?#\\]*)?$/.test(base) ||
    (!allowHttp && !base.startsWith('https://'))) {
    throw new Error(`服务地址必须是 ${allowHttp ? 'HTTP 或 HTTPS' : 'HTTPS'} 地址，不能包含账号、查询参数、反斜杠或片段。`);
  }
  return base.endsWith('/chat/completions') ? base : base + '/chat/completions';
}

export function chatRequest(model: string, messages: ModelMessage[], tools: ToolDefinition[],
  options: ChatCompletionsOptions = {}, maxOutputTokens?: number): ChatRequest {
  return { model: model, stream: true, tools: tools.length > 0 ? tools : undefined,
    max_tokens: maxOutputTokens,
    tool_choice: tools.length > 0 ? 'auto' : undefined,
    messages: messages.map((message: ModelMessage): ChatWireMessage => {
      return { role: message.role, content: message.content,
        tool_calls: message.toolCalls, tool_call_id: message.toolCallId,
        reasoning_content: options.replayReasoning && message.role === 'assistant' ? message.reasoningContent : undefined };
    }) };
}
