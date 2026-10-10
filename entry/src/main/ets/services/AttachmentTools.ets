import { Attachment } from '../model/Productivity';
import { ToolCall, ToolDefinition } from '../model/Agent';
import { textPage } from '../model/TextPage';
import { AgentTools } from './AgentLoop';
import { Cancellation } from './Cancellation';

interface AttachmentArguments { id: string; offset?: number; limit?: number; column?: number; }

// Only attachments belonging to this conversation are available, including branch snapshots.
export class AttachmentTools implements AgentTools {
  private attachments: Attachment[];
  constructor(attachments: Attachment[]) { this.attachments = attachments; }
  definitions(): ToolDefinition[] {
    if (!this.attachments.some((item) => item.mime === 'text/plain')) { return []; }
    return [{ type: 'function', executionMode: 'parallel', promptSnippet: '分段读取对话附件',
      promptGuidelines: ['大附件全文未放入消息。用 read_attachment 读取；需要全文时按返回的续读位置继续。'],
      function: { name: 'read_attachment', description: '按 id 读取本对话的文本附件。每次最多 2000 行或 50 KiB。' +
        'truncated 表示未读完，使用 nextOffset/nextColumn 作为 offset/column 继续。', parameters: {
        type: 'object', properties: { 'id': { type: 'string', description: '附件资料中给出的 id' },
          'offset': { type: 'integer', description: '起始行，默认 1' }, 'limit': { type: 'integer', description: '行数，默认 2000' },
          'column': { type: 'integer', description: '首行起始 UTF-16 列，默认 1；续读时使用 nextColumn' } },
        required: ['id'], additionalProperties: false } } }];
  }
  async execute(call: ToolCall, cancellation: Cancellation): Promise<string> {
    cancellation.check();
    if (call.function.name !== 'read_attachment') { throw new Error('Unsupported attachment tool.'); }
    const args = JSON.parse(call.function.arguments) as AttachmentArguments;
    if (!args || Array.isArray(args) || typeof args.id !== 'string' ||
      Object.keys(args).some((key) => !['id', 'offset', 'limit', 'column'].includes(key))) { throw new Error('Invalid attachment arguments.'); }
    const item = this.attachments.find((attachment) => attachment.id === args.id && attachment.mime === 'text/plain');
    if (!item || typeof item.text !== 'string') { throw new Error('Text attachment is unavailable in this conversation.'); }
    const page = textPage(item.text, args.offset, args.limit, args.column);
    return JSON.stringify({ id: item.id, name: item.name, content: page.content, startLine: page.startLine,
      totalLines: page.totalLines, truncated: page.truncated, nextOffset: page.nextOffset, nextColumn: page.nextColumn });
  }
}
