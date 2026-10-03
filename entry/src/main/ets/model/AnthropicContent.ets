import { t } from './I18n';

export interface AnthropicImageSource { type: string; media_type: string; data: string; }
// Retain the complete ordered assistant content, including opaque signed thinking.
// Only the Anthropic encoder consumes this; signatures never become visible chat text.
export interface AnthropicContentBlock {
  type: string;
  text?: string;
  thinking?: string;
  signature?: string;
  data?: string;
  id?: string;
  name?: string;
  input?: Object;
  source?: AnthropicImageSource;
  tool_use_id?: string;
  content?: string;
}

export function validateAnthropicContent(blocks: AnthropicContentBlock[]): void {
  if (!Array.isArray(blocks) || blocks.length > 129 || JSON.stringify(blocks).length > 2 * 1024 * 1024) {
    throw new Error(t('Anthropic 思考记录无效或过大。'));
  }
  for (const block of blocks) {
    if (!block || !['text', 'thinking', 'redacted_thinking', 'tool_use'].includes(block.type) ||
      (block.type === 'text' && typeof block.text !== 'string') ||
      (block.type === 'thinking' && (typeof block.thinking !== 'string' || typeof block.signature !== 'string' || !block.signature)) ||
      (block.type === 'redacted_thinking' && (typeof block.data !== 'string' || !block.data)) ||
      (block.type === 'tool_use' && (typeof block.id !== 'string' || typeof block.name !== 'string' ||
        !block.input || typeof block.input !== 'object' || Array.isArray(block.input)))) {
      throw new Error(t('Anthropic 思考记录无效或过大。'));
    }
  }
}
