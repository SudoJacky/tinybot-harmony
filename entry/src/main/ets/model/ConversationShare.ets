import { ThreadData, MessageData } from './Conversation';
import { ProviderProfile } from './ProviderProfiles';
import { t } from './I18n';

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
    return { id: message.id, role: message.role, content: body, status: message.status, error: '',
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
    '## ' + (message.role === 'user' ? t('用户') : 'Tinybot') + '\n\n' + message.content +
    (message.attachments?.length ? t('\n\n附件：') + message.attachments.map((file) => file.name).join('、') : '')
  ).join('\n\n') + '\n\n---\n\nTinybot · ' + t('含 AI 生成内容') + '\n\n' + t('AI生成内容可能有误，请仔细鉴别。') + '\n';
}

export function conversationFileName(title: string, extension: string): string {
  return (title.replace(/[\\/:*?"<>|\s]+/g, '_').slice(0, 40) || t('Tinybot对话')) + '.' + extension;
}
