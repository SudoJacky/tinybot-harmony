import { t } from './I18n';
import { ThreadData } from './Conversation';

export function threadTitle(value: string): string {
  const title = value.trim();
  if (title.length === 0 || title.length > 80) { throw new Error(t("对话名称需要 1 至 80 个字符。")); }
  return title;
}

export function matchingThreads(threads: ThreadData[], query: string, archived: boolean): ThreadData[] {
  const needle = query.trim().toLocaleLowerCase();
  return threads.filter((thread: ThreadData) => (thread.archived === true) === archived &&
    (needle.length === 0 || thread.title.toLocaleLowerCase().includes(needle) ||
      thread.messages.some((message) => message.content.toLocaleLowerCase().includes(needle) ||
        (message.steps || []).some((step) => step.steering?.text.toLocaleLowerCase().includes(needle))) ||
      (thread.pendingInputs || []).some((input) => input.text.toLocaleLowerCase().includes(needle))))
    .sort((left: ThreadData, right: ThreadData) => {
      const pinned = Number(right.pinned === true) - Number(left.pinned === true);
      return pinned !== 0 ? pinned : right.updatedAt - left.updatedAt;
    });
}
