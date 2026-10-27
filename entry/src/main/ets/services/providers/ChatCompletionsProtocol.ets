import { ModelMessage, ToolCall, ToolDefinition, toolSchemas } from '../../model/Agent';

interface ChatImageUrl { url: string; }
interface ChatContent { type: string; text?: string; image_url?: ChatImageUrl; }
export interface ChatWireMessage {
  role: string;
  content: string | ChatContent[];
  tool_calls?: ToolCall[];
  tool_call_id?: string;
  reasoning_content?: string;
}

export interface ChatCompletionsOptions {
  allowHttp?: boolean;
  replayReasoning?: boolean;
}

export interface ChatRequest {
  reasoning_effort?: string;
  stream_options?: StreamOptions;
  model: string;
  messages: ChatWireMessage[];
  stream: boolean;
  tools?: ToolDefinition[];
  tool_choice?: string;
  max_tokens?: number;
}
interface StreamOptions { include_usage: boolean; }

export function chatRequest(model: string, messages: ModelMessage[], tools: ToolDefinition[],
  options: ChatCompletionsOptions = {}, maxOutputTokens?: number): ChatRequest {
  return { model: model, stream: true, tools: tools.length > 0 ? toolSchemas(tools) : undefined,
    max_tokens: maxOutputTokens,
    tool_choice: tools.length > 0 ? 'auto' : undefined,
    messages: messages.map((message: ModelMessage): ChatWireMessage => {
      const content: ChatContent[] = [];
      if (message.content.length > 0) { content.push({ type: 'text', text: message.content }); }
      for (const url of message.images || []) { content.push({ type: 'image_url', image_url: { url: url } }); }
      return { role: message.role, content: (message.images || []).length > 0 ? content : message.content,
        tool_calls: message.toolCalls, tool_call_id: message.toolCallId,
        reasoning_content: options.replayReasoning && message.role === 'assistant' ? message.reasoningContent : undefined };
    }) };
}
