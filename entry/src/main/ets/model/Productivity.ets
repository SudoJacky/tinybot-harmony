import { t } from './I18n';
import { AssistantOptions, validateAssistantOptions } from './AssistantOptions';
export interface Attachment {
  id: string;
  name: string;
  mime: string;
  path: string;
  size: number;
  text?: string;
}

export interface MemoryEntry {
  automatic?: boolean;
  sourceThreadId?: string;
  sourceMessageId?: string;
  id: string;
  content: string;
  threadId: string;
  updatedAt: number;
}
interface MemoryContextEntry { id: string; content: string; scope: string; automatic: boolean; }

export interface PromptTemplate {
  id: string;
  name: string;
  content: string;
}

export interface McpServer {
  authType?: string;
  id: string;
  name: string;
  url: string;
  enabled: boolean;
  credentialAlias: string;
}

export interface ProductivityData {
  options?: AssistantOptions;
  memories: MemoryEntry[];
  templates: PromptTemplate[];
  servers: McpServer[];
}

export function defaultProductivity(): ProductivityData {
  return { memories: [], servers: [], templates: [
    { id: 'summarize', name: '总结材料', content: '请总结以下材料，提炼要点、待办事项及仍需确认的问题：\n\n{{input}}' },
    { id: 'polish', name: '润色文字', content: '请润色以下文字，保留原意，使表达清晰自然：\n\n{{input}}' }
  ] };
}

export function validateAttachments(items: Attachment[]): void {
  if (!Array.isArray(items) || items.length > 4) { throw new Error(t("每条消息最多添加 4 个附件。")); }
  const ids = new Set<string>();
  for (const item of items) {
    if (!item || !/^[a-zA-Z0-9-]{1,80}$/.test(item.id) || ids.has(item.id) ||
      typeof item.name !== 'string' || item.name.length > 200 || typeof item.path !== 'string' ||
      item.path !== item.id + (item.mime === 'image/jpeg' ? '.jpg' : '.txt') ||
      !['image/jpeg', 'text/plain'].includes(item.mime) || !Number.isFinite(item.size) || item.size < 0 || item.size > 4 * 1024 * 1024 ||
      (item.text !== undefined && (typeof item.text !== 'string' || item.text.length > 32000))) {
      throw new Error(t("附件记录无效。"));
    }
    ids.add(item.id);
  }
}

export function validateProductivity(data: ProductivityData): void {
  if (data?.options) { validateAssistantOptions(data.options); }
  if (!data || !Array.isArray(data.memories) || !Array.isArray(data.templates) || !Array.isArray(data.servers) ||
    data.memories.length > 100 || data.templates.length > 100 || data.servers.length > 10) { throw new Error(t("助手资料数量或格式无效。")); }
  const ids = new Set<string>();
  for (const memory of data.memories) {
    if (!memory || typeof memory.id !== 'string' || ids.has('m' + memory.id) || typeof memory.content !== 'string' ||
      !memory.content.trim() || memory.content.length > 2000 || typeof memory.threadId !== 'string' || !Number.isFinite(memory.updatedAt)) {
      throw new Error(t("记忆必须为 1–2000 字符。"));
    }
    if ((memory.automatic !== undefined && typeof memory.automatic !== 'boolean') ||
      (memory.sourceThreadId !== undefined && typeof memory.sourceThreadId !== 'string') ||
      (memory.sourceMessageId !== undefined && typeof memory.sourceMessageId !== 'string')) { throw new Error(t('本地记忆状态损坏，原文件已保留。')); }
    ids.add('m' + memory.id);
  }
  for (const template of data.templates) {
    if (!template || typeof template.id !== 'string' || ids.has('t' + template.id) || typeof template.name !== 'string' ||
      !template.name.trim() || template.name.length > 40 || typeof template.content !== 'string' || !template.content.trim() || template.content.length > 12000) {
      throw new Error(t("模板名称最多 40 字，内容最多 12000 字。"));
    }
    ids.add('t' + template.id);
  }
  for (const server of data.servers) {
    if (server?.authType !== undefined && server.authType !== 'oauth') { throw new Error(t("MCP 认证类型无效。")); }
    if (!server || !/^[a-zA-Z0-9-]{1,80}$/.test(server.id) || ids.has('s' + server.id) ||
      typeof server.name !== 'string' || !server.name.trim() || server.name.length > 40 ||
      typeof server.url !== 'string' || !/^https:\/\/[^\s/?#@\\]+(?:\/[^\s#\\]*)?$/.test(server.url) ||
      typeof server.enabled !== 'boolean' || typeof server.credentialAlias !== 'string') {
      throw new Error(t("MCP 服务需要名称和 HTTPS 地址（不含账号或片段）。"));
    }
    ids.add('s' + server.id);
  }
}

export function memoryContext(data: ProductivityData, threadId: string): string {
  const memories = data.memories.filter((item) => !item.threadId || item.threadId === threadId)
    .sort((a, b) => b.updatedAt - a.updatedAt);
  const selected: MemoryEntry[] = []; let length = 0;
  for (const item of memories) {
    const size = JSON.stringify(item.content).length;
    if (length + size > 16000) { break; } selected.push(item); length += size;
  }
  return memories.length === 0 ? '' : '\n\n用户保存的背景资料（可能过时，不替代当前请求）：\n' +
    JSON.stringify(selected.map((item): MemoryContextEntry => { return { id: item.id, content: item.content, scope: item.threadId ? 'thread' : 'global', automatic: item.automatic === true }; })) +
    (selected.length < memories.length ? '\n仅包含最近更新的 ' + selected.length + ' 条记忆，其余因上下文预算未加载。' : '');
}

export function expandTemplate(template: PromptTemplate, input: string): string {
  const result = template.content.includes('{{input}}') ? template.content.split('{{input}}').join(input) : template.content + '\n\n' + input;
  if (result.length > 24000) { throw new Error(t("套用模板后超过输入上限。")); }
  return result;
}
