import { ModelMessage, ToolDefinition, toolSchemas } from './Agent';
import { attachmentContext } from './AttachmentContext';
import { ContextEntry, PromptSection, renderPrompt } from './ContextProjection';
import { estimateTextTokens } from './ConversationContext';
import { Attachment } from './Productivity';

// Content-free attribution of the actual retained request. Never persisted per step.
export interface ContextTokenItem {
  id: string;
  kind: string;
  tokens: number;
  messageId?: string;
  step?: number;
  name?: string;
}

export function attachmentTokens(attachment: Attachment): number {
  return attachment.mime === 'image/jpeg' ? 1800 : estimateTextTokens(attachmentContext(attachment));
}

export function contextBreakdown(messages: ModelMessage[], tools: ToolDefinition[], sections: PromptSection[],
  entries: ContextEntry[], hasSummary: boolean): ContextTokenItem[] {
  const rows: ContextTokenItem[] = [];
  const sources = new Map<ModelMessage, ContextEntry>();
  for (const entry of entries) { for (const message of entry.messages) { sources.set(message, entry); } }
  // Marginal prefixes preserve the estimator's rounding and the full schema total.
  let prefix = '['; let previous = 0;
  const schemas = toolSchemas(tools);
  schemas.forEach((tool, index) => {
    prefix += (index ? ',' : '') + JSON.stringify(tool) + (index === schemas.length - 1 ? ']' : '');
    const total = estimateTextTokens(prefix);
    rows.push({ id: 'schema-' + index, kind: 'definitions', name: tool.function.name, tokens: total - previous });
    previous = total;
  });
  let framing = 3;
  let summarySeen = false;
  messages.forEach((message, index) => {
    framing += 8;
    const source = sources.get(message);
    const id = 'message-' + index;
    let kind = message.role === 'tool' ? 'results' : message.role === 'assistant' ? 'assistant' : 'user';
    if (message.role === 'system') { kind = 'system'; }
    else if (hasSummary && !summarySeen) { kind = 'summary'; summarySeen = true; }
    const name = message.role === 'tool' ? source?.results?.find((item) => item.call.id === message.toolCallId)?.call.function.name : undefined;
    let contentTokens = estimateTextTokens(message.content);
    const reference = source?.referenceText || '';
    if (kind === 'user' && reference && message.content.endsWith(reference)) {
      const userTokens = estimateTextTokens(message.content.slice(0, message.content.length - reference.length));
      rows.push({ id: id + '-references', kind: 'attachments', name: 'history_references', tokens: contentTokens - userTokens,
        messageId: source?.messageId, step: source?.step });
      contentTokens = userTokens;
    }
    if (kind === 'system' && message.content === renderPrompt(sections)) {
      let rendered = ''; let counted = 0;
      sections.filter((section) => section.content.trim().length > 0).forEach((section, sectionIndex) => {
        rendered += (rendered ? '\n\n' : '') + renderPrompt([section]);
        const total = estimateTextTokens(rendered);
        rows.push({ id: id + '-section-' + sectionIndex, kind: kind, name: section.name, tokens: total - counted });
        counted = total;
      });
    } else {
      rows.push({ id: id, kind: kind, tokens: contentTokens, name: name, messageId: source?.messageId, step: source?.step });
    }
    if (message.reasoningContent) {
      rows.push({ id: id + '-reasoning', kind: 'assistant', name: 'reasoning', tokens: estimateTextTokens(message.reasoningContent), messageId: source?.messageId, step: source?.step });
    }
    if (message.toolCalls) {
      rows.push({ id: id + '-calls', kind: 'assistant', name: 'tool_calls', tokens: estimateTextTokens(JSON.stringify(message.toolCalls)), messageId: source?.messageId, step: source?.step });
    }
    framing += estimateTextTokens(message.toolCallId || '');
    (message.attachments || []).forEach((attachment, attachmentIndex) => {
      rows.push({ id: id + '-attachment-' + attachmentIndex, kind: 'attachments', name: attachment.name,
        tokens: attachmentTokens(attachment), messageId: source?.messageId, step: source?.step });
    });
  });
  rows.push({ id: 'framing', kind: 'overhead', tokens: framing });
  return rows.filter((row) => row.tokens > 0);
}

export function draftBreakdown(text: string, references: string, attachments: Attachment[]): ContextTokenItem[] {
  const rows: ContextTokenItem[] = [];
  if (text.trim() || references || attachments.length) {
    rows.push({ id: 'draft-text', kind: 'user', name: 'draft', tokens: estimateTextTokens(text) });
    rows.push({ id: 'draft-frame', kind: 'overhead', name: 'draft', tokens: 8 });
  }
  if (references) { rows.push({ id: 'draft-references', kind: 'attachments', name: 'references', tokens: estimateTextTokens(references) }); }
  attachments.forEach((attachment, index) => {
    rows.push({ id: 'draft-attachment-' + index, kind: 'attachments', name: attachment.name, tokens: attachmentTokens(attachment) });
  });
  return rows.filter((row) => row.tokens > 0);
}
