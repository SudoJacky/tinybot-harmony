import { MAX_REASONING_CONTENT } from './Agent';
import { MessageData, ThreadData } from './Conversation';
import { MAX_MESSAGE_ATTACHMENTS } from './Productivity';
import { t } from './I18n';

export const DEEPSEEK_IMPORT_GROUP: string = '@imported';
export const DEEPSEEK_SESSION_PATH: RegExp = /^chat_sessions\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.json$/i;
export interface DeepSeekFile { path: string; name: string; image: boolean; }
export interface DeepSeekPlan { threads: ThreadData[]; files: Map<string, DeepSeekFile[]>; }
interface SourceFile { file_name: string; export_path: string | null; is_image: boolean; }
interface SourceLink { title?: string | null; url?: string | null; }
interface Fragment extends SourceLink { type: string; content?: string; files?: SourceFile[]; results?: SourceLink[]; }
interface SourceMessage { id: number; parent_id: number | null; role: string; status: string; fragments: Fragment[]; }
interface SourceSession {
  id: string; title: string; pinned: boolean; current_message_id: number | null;
  inserted_at: string; updated_at: string; messages: SourceMessage[];
}

function invalidSession(): Error { return new Error(t('DeepSeek 会话数据不完整或格式无效。')); }

function addSource(sources: Map<string, string>, source: SourceLink): void {
  if (!source || typeof source.url !== 'string' || !/^https?:\/\/[^\s<>\\]+$/i.test(source.url) ||
    source.url.length > 4096 || sources.has(source.url)) { return; }
  const title = typeof source.title === 'string' ? source.title.replace(/[\r\n]+/g, ' ').slice(0, 250).trim() : '';
  sources.set(source.url, title);
}

function importMessage(session: string, entry: SourceMessage, plan: DeepSeekPlan): MessageData {
  const assistant = entry.role === 'ASSISTANT';
  if ((!assistant && entry.role !== 'USER') || typeof entry.status !== 'string' || !Array.isArray(entry.fragments)) { throw invalidSession(); }
  const id = 'ds-' + session + '-' + entry.id;
  const content: string[] = [], reasoning: string[] = [], notes: string[] = [];
  const sources = new Map<string, string>(), files: DeepSeekFile[] = [];
  const filePaths = new Set<string>();
  for (const fragment of entry.fragments) {
    if (!fragment || typeof fragment.type !== 'string') { throw invalidSession(); }
    if (fragment.type === 'REQUEST' || fragment.type === 'RESPONSE' || fragment.type === 'TEMPLATE_RESPONSE') {
      if (typeof fragment.content !== 'string') { throw invalidSession(); }
      content.push(fragment.content);
    } else if (fragment.type === 'THINK' && assistant) {
      if (typeof fragment.content !== 'string') { throw invalidSession(); }
      reasoning.push(fragment.content);
    } else if ((fragment.type === 'TIP' || fragment.type === 'CONTENT_RISK') && typeof fragment.content === 'string') {
      notes.push(fragment.content);
    } else if (fragment.type === 'TOOL_SEARCH' && assistant && Array.isArray(fragment.results)) {
      fragment.results.forEach((source: SourceLink) => addSource(sources, source));
    } else if (fragment.type === 'TOOL_OPEN' && assistant) {
      addSource(sources, fragment);
    } else if (fragment.type === 'FILE') {
      if (!Array.isArray(fragment.files)) { throw invalidSession(); }
      for (const file of fragment.files) {
        if (!file || typeof file.file_name !== 'string' || typeof file.is_image !== 'boolean') { throw invalidSession(); }
        const path = file.export_path;
        if (path === null || path === '') {
          notes.push(t('DeepSeek 导出包中缺少附件：{0}', [file.file_name]));
          continue;
        }
        const prefix = 'chat_sessions/' + session + '_files/';
        if (typeof path !== 'string' || !path.startsWith(prefix) || !/^[^/\\\u0000-\u001f]+$/.test(path.slice(prefix.length)) ||
          ['.', '..'].includes(path.slice(prefix.length))) { throw invalidSession(); }
        if (!filePaths.has(path)) {
          filePaths.add(path);
          files.push({ path: path, name: file.file_name, image: file.is_image });
        }
      }
    }
  }
  if (files.length > MAX_MESSAGE_ATTACHMENTS) { throw new Error(t('每条消息最多添加 {0} 个附件。', [MAX_MESSAGE_ATTACHMENTS])); }
  if (files.length > 0) { plan.files.set(id, files); }
  const sourceLines: string[] = [];
  sources.forEach((title: string, url: string) => {
    sourceLines.push('- ' + (title ? title.replace(/[\\\[\]<>*_]/g, '\\$&') + ' · ' : '') + '<' + url + '>');
  });
  const body = [content.join('\n\n'), notes.join('\n\n'),
    sourceLines.length ? '**' + t('DeepSeek 搜索来源') + '**\n\n' + sourceLines.join('\n') : ''].filter(line => line.length > 0).join('\n\n');
  const reasoningContent = reasoning.join('\n\n');
  if (reasoningContent.length > MAX_REASONING_CONTENT) { throw invalidSession(); }
  const complete = !assistant || entry.status === 'FINISHED';
  return { id: id, role: assistant ? 'assistant' : 'user', content: body, status: complete ? 'complete' : 'stopped',
    error: complete ? '' : t('这条回复在 DeepSeek 中未完成。'),
    steps: reasoningContent ? [{ content: body, reasoningContent: reasoningContent, tools: [] }] : undefined };
}

export function appendDeepSeekSession(plan: DeepSeekPlan, sessionId: string, json: string): void {
  const session = JSON.parse(json) as SourceSession;
  if (!session || session.id !== sessionId || typeof session.title !== 'string' || typeof session.pinned !== 'boolean' ||
    !Array.isArray(session.messages) || session.messages.length > 10000) { throw invalidSession(); }
  if (session.messages.length === 0) { return; }
  const updated = Date.parse(session.updated_at);
  if (!Number.isFinite(updated)) { throw invalidSession(); }
  const nodes = new Map<number, SourceMessage>(), parents = new Set<number>();
  for (const node of session.messages) {
    if (!node || !Number.isSafeInteger(node.id) || node.id < 0 || nodes.has(node.id) ||
      (node.parent_id !== null && (!Number.isSafeInteger(node.parent_id) || node.parent_id < 0))) { throw invalidSession(); }
    nodes.set(node.id, node);
    if (node.parent_id !== null) { parents.add(node.parent_id); }
  }
  const active = session.current_message_id;
  if (active === null || !nodes.has(active)) { throw invalidSession(); }
  const endpoints = [active].concat(Array.from(nodes.keys()).filter(id => id !== active && !parents.has(id)));
  if (endpoints.length > 200) { throw invalidSession(); }
  const converted = new Map<number, MessageData>();
  const rootId = 'deepseek-' + sessionId;
  let primary: MessageData[] = [];
  let expanded = 0;
  let branch = 0;
  for (const endpoint of endpoints) {
    const ancestry = new Set<number>(), messages: MessageData[] = [];
    let current: number | null = endpoint;
    while (current !== null) {
      if (++expanded > 50000 || ancestry.has(current)) { throw invalidSession(); }
      ancestry.add(current);
      const source = nodes.get(current);
      if (!source) { throw invalidSession(); }
      let message = converted.get(current);
      if (!message) { message = importMessage(sessionId, source, plan); converted.set(current, message); }
      messages.push(message);
      current = source.parent_id;
    }
    messages.reverse();
    if (messages.some((message, index) => message.role !== (index % 2 === 0 ? 'user' : 'assistant'))) { throw invalidSession(); }
    if (endpoint === active) { primary = messages; }
    let common = 0;
    while (endpoint !== active && common < primary.length && common < messages.length && primary[common].id === messages[common].id) { common++; }
    const title = session.title.trim() || t('无标题');
    plan.threads.push({ id: endpoint === active ? rootId : rootId + '-' + endpoint,
      title: endpoint === active ? title : t('{0}（分支 {1}）', [title, ++branch]),
      updatedAt: updated, messages: messages, pinned: endpoint === active && session.pinned, titleEdited: true, importSource: 'deepseek',
      parentThreadId: endpoint === active ? undefined : rootId,
      parentMessageId: common > 0 ? primary[common - 1].id : undefined });
  }
  if (converted.size !== nodes.size) { throw invalidSession(); }
}
