import { ThreadData, MessageData } from './Conversation';
import { ProviderProfile } from './ProviderProfiles';
import { t } from './I18n';
import { AgentStep } from './Agent';
import { previewReferenceParts, previewReferenceTargets } from './PreviewReferences';

export interface ConversationShareData {
  thread: ThreadData;
  profiles: ProviderProfile[];
}

// Aggregate message.content also contains narration from intermediate tool rounds.
// Share only the final answer, never reasoning, tool receipts or failed attempts.
export function sharingMessages(messages: MessageData[]): MessageData[] {
  return messages.map((message): MessageData => {
    let body = message.content;
    if (message.role === 'assistant' && message.steps?.length) {
      const steps = message.steps.filter((step) => !step.requestError && !step.uiValidation);
      const last = steps[steps.length - 1];
      body = last && !last.tools.length ? last.content : '';
    }
    const referenced = previewReferenceParts(body).filter((part) => part.kind === 'preview').map((part) => part.previewId);
    const previews = previewReferenceTargets(message.steps || []).filter((target) => referenced.includes(target.previewId));
    // Keep only referenced artifact metadata for static image export, never process narration or unrelated tool results.
    const steps: AgentStep[] | undefined = previews.length ? [{ content: '', tools: previews.map((target) => target.tool) }, { content: body, tools: [] }] : undefined;
    return { id: message.id, role: message.role, content: body, status: message.status, error: '', steps: steps,
      attachments: message.attachments, modelRef: message.modelRef };
  }).filter((message) => message.content.trim().length > 0 || (message.attachments?.length || 0) > 0);
}

// Both formats use the same selection in original conversation order.
export function selectedConversation(thread: ThreadData, ids: string[]): ThreadData {
  const selected = JSON.parse(JSON.stringify(thread)) as ThreadData;
  selected.messages = sharingMessages(selected.messages.filter((message) => ids.includes(message.id)));
  if (selected.messages.length === 0) { throw new Error(t('请至少选择一条消息')); }
  return selected;
}

export function conversationMarkdown(thread: ThreadData): string {
  return '# ' + thread.title + '\n\n' + sharingMessages(thread.messages).map((message) =>
    '## ' + (message.role === 'user' ? t('用户') : 'Tinybot') + '\n\n' + markdownPreviewText(message) +
    (message.attachments?.length ? t('\n\n附件：') + message.attachments.map((file) => file.name).join('、') : '')
  ).join('\n\n') + '\n\n---\n\nTinybot · ' + t('含 AI 生成内容') + '\n\n' + t('AI生成内容可能有误，请仔细鉴别。') + '\n';
}
function markdownPreviewText(message: MessageData): string {
  if (message.role !== 'assistant') { return message.content; }
  const targets = previewReferenceTargets(message.steps || []);
  return previewReferenceParts(message.content).map((part) => part.kind === 'text' ? part.content :
    '[' + (targets.find((target) => target.previewId === part.previewId)?.title || 'Preview unavailable') + ']\n').join('');
}

export function conversationFileName(title: string, extension: string): string {
  return (title.replace(/[\\/:*?"<>|\s]+/g, '_').slice(0, 40) || t('Tinybot对话')) + '.' + extension;
}
