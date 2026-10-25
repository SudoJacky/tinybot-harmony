import { t } from './I18n';

export type FeedbackFilter = 'all' | 'new' | 'handled';
export type FeedbackType = 'bug' | 'suggestion' | 'other';
export type FeedbackTypeFilter = 'all' | FeedbackType;
export interface FeedbackAttachment {
  id: string; kind: 'image' | 'log'; filename: string; mimeType: string; size: number; createdAt: string;
}
export interface FeedbackUpload {
  localId: string; kind: 'image' | 'log'; filename: string; mimeType: string; size: number; path: string;
  state: 'pending' | 'uploaded' | 'failed' | 'uncertain'; remoteId: string; beforeIds: string[]; error: string;
}
export interface FeedbackReply { body: string; updatedAt: string; }
export interface FeedbackItem {
  id: string; body: string; contact: string; createdAt: string;
  status: 'new' | 'handled'; type: FeedbackType; attachments: FeedbackAttachment[]; reply: FeedbackReply | null;
}
export interface FeedbackPage {
  schemaVersion: number; items: FeedbackItem[]; nextCursor: string | null;
  counts: FeedbackCounts;
}
export interface FeedbackCounts { new: number; handled: number; }
export interface FeedbackIdentity { schemaVersion: number; token: string; identityId: string; createdAt: string; }
export interface FeedbackReceipt { schemaVersion: number; id: string; createdAt: string; }
interface FeedbackDetail { schemaVersion: number; feedback: FeedbackItem; }
export interface FeedbackDraft { body: string; contact: string; type: FeedbackType; }

export function feedbackInput(body: string, contact: string, type: FeedbackType = 'other'): FeedbackDraft {
  const draft: FeedbackDraft = { body: body.trim(), contact: contact.trim(), type: type };
  if (!draft.body || draft.body.length > 5000 || draft.contact.length > 200) {
    throw new Error(t('请填写反馈内容（最多 5,000 字符），联系方式最多 200 字符。'));
  }
  if (!['bug', 'suggestion', 'other'].includes(type)) { throw new Error(t('请选择反馈类型。')); }
  return draft;
}
function invalid(): Error { return new Error(t('反馈服务返回的数据无效，请稍后刷新。')); }
function json(source: string): Object {
  try { return JSON.parse(source) as Object; } catch (_) { throw invalid(); }
}
function validDate(value: string): boolean { return typeof value === 'string' && value.endsWith('Z') && Number.isFinite(Date.parse(value)); }
function validId(value: string): boolean { return typeof value === 'string' && /^[a-f0-9-]{36}$/i.test(value); }
export function validFeedbackToken(value: string): boolean { return typeof value === 'string' && /^fi_[A-Za-z0-9_-]{43}$/.test(value); }
function validItem(item: FeedbackItem): boolean {
  return !!item && validId(item.id) && typeof item.body === 'string' && item.body.length <= 5000 &&
    typeof item.contact === 'string' && item.contact.length <= 200 && validDate(item.createdAt) &&
    (item.status === 'new' || item.status === 'handled') && ['bug', 'suggestion', 'other'].includes(item.type) &&
    Array.isArray(item.attachments) && item.attachments.length <= 4 && item.attachments.every(validAttachment) &&
    item.attachments.filter((file: FeedbackAttachment) => file.kind === 'image').length <= 3 &&
    item.attachments.filter((file: FeedbackAttachment) => file.kind === 'log').length <= 1 && (item.reply === null ||
      !!item.reply && typeof item.reply.body === 'string' && item.reply.body.length <= 5000 && validDate(item.reply.updatedAt));
}
function validAttachment(file: FeedbackAttachment): boolean {
  return !!file && validId(file.id) && typeof file.filename === 'string' && validFeedbackFilename(file.filename) &&
    Number.isInteger(file.size) && file.size > 0 && validDate(file.createdAt) &&
    (file.kind === 'image' && file.mimeType === 'image/webp' && file.size <= 5 * 1024 * 1024 ||
      file.kind === 'log' && /^text\/plain(?:;\s*charset=utf-8)?$/i.test(file.mimeType) && file.size <= 2 * 1024 * 1024);
}
export function validFeedbackFilename(name: string): boolean {
  return !!name && name.length <= 120 && !/^[.]/.test(name) && !/[\\/\u0000-\u001f\u007f]/.test(name);
}
export function parseFeedbackAttachment(source: string): FeedbackAttachment {
  const value = json(source) as FeedbackAttachmentResponse;
  if (!value || value.schemaVersion !== 1 || !validAttachment(value.attachment)) { throw invalid(); }
  return value.attachment;
}
interface FeedbackAttachmentResponse { schemaVersion: number; attachment: FeedbackAttachment; }

// Additional redaction after the diagnostic source has applied its field allowlist.
export function redactFeedbackLog(source: string): string {
  if (!source || source.includes('\u0000')) { throw new Error(t('请选择非空的 UTF-8 文本日志。')); }
  let result = source.replace(/-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*?-----END [^-]*PRIVATE KEY-----/g, '[REDACTED KEY]')
    .replace(/("(?:content|prompt|messages|conversation|chat|authorization|cookie|password|secret|api[_-]?key|access[_-]?token|refresh[_-]?token|open[_-]?id|account)"\s*:\s*)"(?:\\.|[^"\\])*"/gi, '$1"[REDACTED]"')
    .split('\n').map((line: string) => /(?:authorization|bearer\s|cookie|password|passwd|secret|api[_ -]?key|access[_ -]?token|refresh[_ -]?token|open[_ -]?id|account|user[_ -]?id|聊天|对话|密钥|密码|账号|用户消息|(?:^|\s)(?:prompt|content|messages|conversation|chat)\s*[:=])/i.test(line) ? '[REDACTED SENSITIVE LINE]' : line)
    .join('\n').replace(/\b(?:fi_[A-Za-z0-9_-]{43}|sk-[A-Za-z0-9_-]{10,})\b/g, '[REDACTED TOKEN]');
  // Bound both sides of an email match; unbounded local/domain scans can be quadratic on long log lines.
  if (result.includes('@')) { result = result.replace(/[A-Z0-9._%+-]{1,64}@[A-Z0-9.-]{1,253}\.[A-Z]{2,63}/gi, '[REDACTED EMAIL]'); }
  return result.replace(/\b1[3-9]\d{9}\b/g, '[REDACTED PHONE]');
}
export function parseFeedbackIdentity(source: string): FeedbackIdentity {
  const value = json(source) as FeedbackIdentity;
  if (!value || value.schemaVersion !== 1 || !validFeedbackToken(value.token) || !validId(value.identityId) || !validDate(value.createdAt)) { throw invalid(); }
  return value;
}
export function parseFeedbackReceipt(source: string): FeedbackReceipt {
  const value = json(source) as FeedbackReceipt;
  if (!value || value.schemaVersion !== 1 || !validId(value.id) || !validDate(value.createdAt)) { throw invalid(); }
  return value;
}
export function parseFeedbackPage(source: string): FeedbackPage {
  const value = json(source) as FeedbackPage;
  if (!value || value.schemaVersion !== 1 || !Array.isArray(value.items) || value.items.length > 20 ||
    !value.items.every((item: FeedbackItem) => validItem(item)) ||
    !(value.nextCursor === null || typeof value.nextCursor === 'string' && value.nextCursor.length > 0) ||
    !value.counts || !Number.isInteger(value.counts.new) || value.counts.new < 0 ||
    !Number.isInteger(value.counts.handled) || value.counts.handled < 0) { throw invalid(); }
  return value;
}
export function parseFeedbackDetail(source: string): FeedbackItem {
  const value = json(source) as FeedbackDetail;
  if (!value || value.schemaVersion !== 1 || !validItem(value.feedback)) { throw invalid(); }
  return value.feedback;
}
