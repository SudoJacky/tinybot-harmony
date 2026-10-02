import { t } from '../../model/I18n';
import { ModelMessage, ToolDefinition, ToolParameters } from '../../model/Agent';
import { completionUrl } from './ChatCompletionsProtocol';

export function protocolHeaders(protocol: string, apiKey: string): Record<string, string> {
  const headers: Record<string, string> = { 'Content-Type': 'application/json', 'Accept': 'text/event-stream' };
  if (protocol === 'anthropic-messages') { headers['anthropic-version'] = '2023-06-01'; }
  if (apiKey.length > 0) {
    if (protocol === 'anthropic-messages') { headers['x-api-key'] = apiKey; }
    else { headers['Authorization'] = 'Bearer ' + apiKey; }
  }
  return headers;
}

export function protocolUrl(protocol: string, baseUrl: string, allowHttp: boolean): string {
  completionUrl(baseUrl, allowHttp);
  const base = baseUrl.trim().replace(/\/+$/, '');
  const suffix = protocol === 'chat-completions' ? '/chat/completions' : protocol === 'responses' ? '/responses' :
    protocol === 'anthropic-messages' ? '/messages' : '';
  if (!suffix) { throw new Error(t("不支持的模型协议：") + protocol); }
  for (const ending of ['/chat/completions', '/responses', '/messages']) {
    if (base.endsWith(ending) && ending !== suffix) { throw new Error(t("服务地址的接口路径与所选协议不一致。")); }
  }
  if (base.endsWith(suffix)) { return base; }
  if (protocol === 'anthropic-messages' && /^https?:\/\/[^/]+$/.test(base)) { return base + '/v1/messages'; }
  return base + suffix;
}

interface ResponsesContent { type: string; text?: string; image_url?: string; }
export interface ResponsesInput {
  type?: string;
  role?: string;
  content?: string | ResponsesContent[];
  call_id?: string;
  name?: string;
  arguments?: string;
  output?: string;
}
interface ResponsesTool {
  type: string;
  name: string;
  description: string;
  parameters: ToolParameters;
  strict: boolean;
}
export interface ResponsesRequest {
  reasoning?: ReasoningOptions;
  model: string;
  stream: boolean;
  store: boolean;
  instructions?: string;
  input: ResponsesInput[];
  tools?: ResponsesTool[];
  max_output_tokens?: number;
}
interface ReasoningOptions { effort: string; }

export function responsesRequest(model: string, messages: ModelMessage[], tools: ToolDefinition[],
  maxOutput: number = 4096): ResponsesRequest {
  const input: ResponsesInput[] = [];
  const instructions: string[] = [];
  for (const message of messages) {
    if (message.role === 'system') { instructions.push(message.content); }
    else if (message.role === 'tool') {
      if (!message.toolCallId) { throw new Error(t("工具结果缺少调用 ID。")); }
      input.push({ type: 'function_call_output', call_id: message.toolCallId, output: message.content });
    } else {
      if (message.role !== 'user' && message.role !== 'assistant') { throw new Error(t("不支持的消息角色。")); }
      if ((message.images || []).length > 0) {
        const content: ResponsesContent[] = [{ type: 'input_text', text: message.content }];
        for (const url of message.images || []) { content.push({ type: 'input_image', image_url: url }); }
        input.push({ role: message.role, content: content });
      } else if (message.content.length > 0) { input.push({ role: message.role, content: message.content }); }
      for (const call of message.toolCalls || []) {
        input.push({ type: 'function_call', call_id: call.id, name: call.function.name, arguments: call.function.arguments });
      }
    }
  }
  return { model: model, stream: true, store: false, instructions: instructions.length > 0 ? instructions.join('\n\n') : undefined,
    input: input, max_output_tokens: maxOutput,
    tools: tools.length > 0 ? tools.map((tool: ToolDefinition): ResponsesTool => {
      return { type: 'function', name: tool.function.name, description: tool.function.description,
        parameters: tool.function.parameters, strict: false };
    }) : undefined };
}

interface ImageSource { type: string; media_type: string; data: string; }
export interface AnthropicBlock {
  source?: ImageSource;
  type: string;
  text?: string;
  id?: string;
  name?: string;
  input?: Object;
  tool_use_id?: string;
  content?: string;
}
interface AnthropicMessage {
  role: string;
  content: AnthropicBlock[];
}
interface AnthropicTool {
  name: string;
  description: string;
  input_schema: ToolParameters;
}
export interface AnthropicRequest {
  model: string;
  stream: boolean;
  max_tokens: number;
  system?: string;
  messages: AnthropicMessage[];
  tools?: AnthropicTool[];
}

export function anthropicRequest(model: string, messages: ModelMessage[], tools: ToolDefinition[],
  maxOutput: number = 4096): AnthropicRequest {
  const result: AnthropicMessage[] = [];
  const system: string[] = [];
  for (const message of messages) {
    if (message.role === 'system') { system.push(message.content); continue; }
    const blocks: AnthropicBlock[] = [];
    const role = message.role === 'tool' ? 'user' : message.role;
    if (role !== 'user' && role !== 'assistant') { throw new Error(t("不支持的消息角色。")); }
    if (message.role === 'tool') {
      if (!message.toolCallId) { throw new Error(t("工具结果缺少调用 ID。")); }
      blocks.push({ type: 'tool_result', tool_use_id: message.toolCallId, content: message.content });
    } else {
      if (message.content.length > 0) { blocks.push({ type: 'text', text: message.content }); }
      for (const url of message.images || []) { blocks.push({ type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: url.slice(url.indexOf(',') + 1) } }); }
      for (const call of message.toolCalls || []) {
        const input = JSON.parse(call.function.arguments) as Object;
        if (!input || typeof input !== 'object' || Array.isArray(input)) { throw new Error(t("工具参数必须是 JSON 对象。")); }
        blocks.push({ type: 'tool_use', id: call.id, name: call.function.name, input: input });
      }
    }
    if (blocks.length === 0) { continue; }
    const previous = result[result.length - 1];
    if (previous && previous.role === role) { previous.content = previous.content.concat(blocks); }
    else { result.push({ role: role, content: blocks }); }
  }
  return { model: model, stream: true, max_tokens: maxOutput, system: system.length > 0 ? system.join('\n\n') : undefined,
    messages: result, tools: tools.length > 0 ? tools.map((tool: ToolDefinition): AnthropicTool => {
      return { name: tool.function.name, description: tool.function.description, input_schema: tool.function.parameters };
    }) : undefined };
}
