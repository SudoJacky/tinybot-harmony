import { t } from '../../model/I18n';
import { ModelMessage, ToolDefinition, ToolParameters, validateToolCalls } from '../../model/Agent';
import { GeminiPart, GeminiFunctionCall, validateGeminiContent } from '../../model/GeminiContent';

interface GeminiContent { role?: string; parts: GeminiPart[]; }
interface GeminiDeclaration { name: string; description: string; parametersJsonSchema: ToolParameters; }
interface GeminiTools { functionDeclarations: GeminiDeclaration[]; }
interface GeminiGenerationConfig { maxOutputTokens?: number; }
export interface GeminiRequest {
  systemInstruction?: GeminiContent;
  contents: GeminiContent[];
  tools?: GeminiTools[];
  generationConfig?: GeminiGenerationConfig;
}

export function geminiStreamUrl(root: string, model: string): string {
  const id = model.replace(/^models\//, '');
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$/.test(id)) { throw new Error(t('Gemini 模型 ID 无效。')); }
  return root + '/models/' + id + ':streamGenerateContent?alt=sse';
}

export function geminiRequest(messages: ModelMessage[], tools: ToolDefinition[], maxOutput?: number): GeminiRequest {
  const contents: GeminiContent[] = [];
  const system: GeminiPart[] = [];
  const calls: Map<string, GeminiFunctionCall> = new Map<string, GeminiFunctionCall>();
  for (const message of messages) {
    if (message.role === 'system') { system.push({ text: message.content }); continue; }
    const role = message.role === 'assistant' ? 'model' : 'user';
    let parts: GeminiPart[] = [];
    if (message.role === 'tool') {
      const call = calls.get(message.toolCallId || '');
      if (!call) { throw new Error(t('Gemini 工具结果缺少对应的调用。')); }
      parts.push({ functionResponse: { id: call.id, name: call.name, response: { output: message.content } } });
      calls.delete(message.toolCallId!);
    } else {
      if (!['user', 'assistant'].includes(message.role)) { throw new Error(t('不支持的消息角色。')); }
      if (message.role === 'assistant' && message.geminiContent?.length) {
        validateGeminiContent(message.geminiContent);
        parts = JSON.parse(JSON.stringify(message.geminiContent)) as GeminiPart[];
      } else {
        if (message.content) { parts.push({ text: message.content }); }
        for (const image of message.images || []) {
          const data = /^data:(image\/[A-Za-z0-9.+-]+);base64,([A-Za-z0-9+/=]+)$/.exec(image);
          if (!data) { throw new Error(t('Gemini 图片必须是 base64 图片数据。')); }
          parts.push({ inlineData: { mimeType: data[1], data: data[2] } });
        }
        for (const call of message.toolCalls || []) {
          parts.push({ functionCall: { name: call.function.name, args: JSON.parse(call.function.arguments) as Object } });
        }
      }
      const toolCalls = message.toolCalls || [];
      validateToolCalls(toolCalls);
      const functions = parts.filter((part) => part.functionCall !== undefined).map((part) => part.functionCall!);
      if (functions.length !== toolCalls.length) { throw new Error(t('Gemini 工具调用无效。')); }
      for (let index = 0; index < functions.length; index++) {
        const call = functions[index];
        if (call.name !== toolCalls[index].function.name ||
          (call.args !== undefined && (!call.args || typeof call.args !== 'object' || Array.isArray(call.args)))) {
          throw new Error(t('Gemini 工具调用无效。'));
        }
        calls.set(toolCalls[index].id, call);
      }
    }
    if (!parts.length) { continue; }
    const previous = contents[contents.length - 1];
    if (previous?.role === role) { previous.parts = previous.parts.concat(parts); }
    else { contents.push({ role: role, parts: parts }); }
  }
  return { systemInstruction: system.length ? { parts: system } : undefined, contents: contents,
    generationConfig: maxOutput === undefined ? undefined : { maxOutputTokens: maxOutput },
    tools: tools.length ? [{ functionDeclarations: tools.map((tool): GeminiDeclaration => ({ name: tool.function.name,
      description: tool.function.description, parametersJsonSchema: tool.function.parameters })) }] : undefined };
}
