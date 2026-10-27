import { t } from './I18n';

export interface GeminiFunctionCall { id?: string; name: string; args?: Object; }
export interface GeminiFunctionOutput { output: string; }
export interface GeminiFunctionResponse { id?: string; name: string; response: GeminiFunctionOutput; }
export interface GeminiInlineData { mimeType: string; data: string; }
// Preserve part boundaries and opaque signatures exactly as received, including empty text parts.
export interface GeminiPart {
  text?: string;
  thought?: boolean;
  thoughtSignature?: string;
  functionCall?: GeminiFunctionCall;
  functionResponse?: GeminiFunctionResponse;
  inlineData?: GeminiInlineData;
}

export function validateGeminiContent(parts: GeminiPart[]): void {
  if (!Array.isArray(parts) || parts.length > 65536) {
    throw new Error(t('Gemini 内容记录无效或过大。'));
  }
  for (const part of parts) {
    if (!part || typeof part !== 'object' || Array.isArray(part) ||
      Object.keys(part).some((key) => !['text', 'thought', 'thoughtSignature', 'functionCall'].includes(key)) ||
      (part.text !== undefined && typeof part.text !== 'string') ||
      (part.thought !== undefined && typeof part.thought !== 'boolean') ||
      (part.thoughtSignature !== undefined && (typeof part.thoughtSignature !== 'string' || !part.thoughtSignature)) ||
      (part.text === undefined && !part.functionCall && !part.thoughtSignature) ||
      (part.text !== undefined && part.functionCall !== undefined)) {
      throw new Error(t('Gemini 内容记录无效或过大。'));
    }
    const call = part.functionCall;
    if (call !== undefined && (!call || typeof call !== 'object' || Array.isArray(call) ||
      typeof call.name !== 'string' || !/^[A-Za-z0-9_-]{1,64}$/.test(call.name) ||
      (call.id !== undefined && (typeof call.id !== 'string' || !call.id || call.id.length > 1024)) ||
      (call.args !== undefined && (!call.args || typeof call.args !== 'object' || Array.isArray(call.args))))) {
      throw new Error(t('Gemini 工具调用无效。'));
    }
  }
}
