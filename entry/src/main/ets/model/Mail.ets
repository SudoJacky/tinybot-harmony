import { t } from './I18n';
export interface MailAccount {
  id: string; name: string; host: string; port: number; username: string;
  enabled: boolean; allowBody: boolean;
}
export interface MailQuery {
  accountId: string; folder: string; limit?: number; unreadOnly?: boolean; from?: string; subject?: string;
}
export interface MailMessage {
  id: string; uid: number; uidValidity: number; folder: string; subject: string; from: string;
  to: string; date: string; unread: boolean; size: number;
}
export interface MailSnapshot {
  accountId: string; folder: string; uidValidity: number; total: number; unread: number;
  matched: number; limited: boolean; checkedAt: number; messages: MailMessage[];
}
export interface MailBody { message: MailMessage; text: string; }
export function mailId(id: string): string {
  if (typeof id !== 'string' || !/^[a-zA-Z0-9_-]{1,80}$/.test(id)) { throw new Error('Invalid mail account ID'); } return id;
}
export function mailText(value: string, max: number): string {
  if (typeof value !== 'string' || !value.trim() || value.length > max || /[\u0000-\u001f\u007f]/.test(value)) { throw new Error('Invalid mail setting or search text'); } return value;
}
export function validateMailAccount(account: MailAccount): void {
  mailId(account.id);
  if (typeof account.name !== 'string' || !account.name.trim() || account.name.length > 80 || /[\u0000-\u001f\u007f]/.test(account.name)) { throw new Error(t('请填写连接名称，最多 80 个字符，不能包含换行。')); }
  if (typeof account.host !== 'string' || account.host.length > 253 || !/^[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?$/.test(account.host)) { throw new Error(t('请填写有效的 IMAP 服务器域名，例如 imap.example.com。')); }
  if (!Number.isInteger(account.port) || account.port < 1 || account.port > 65535) { throw new Error(t('TLS 端口必须是 1–65535 之间的整数。')); }
  if (typeof account.username !== 'string' || !account.username.trim() || account.username.length > 254 || /[\u0000-\u001f\u007f]/.test(account.username)) { throw new Error(t('请填写邮箱登录账号，最多 254 个字符，不能包含换行。')); }
  if (typeof account.enabled !== 'boolean' || typeof account.allowBody !== 'boolean') { throw new Error('Expected mail access settings'); }
}
export function validateMailQuery(query: MailQuery): void {
  if (!query || typeof query !== 'object' || Array.isArray(query) || Object.keys(query).some((key: string) => !['accountId', 'folder', 'limit', 'unreadOnly', 'from', 'subject'].includes(key))) { throw new Error('Invalid mail query'); }
  mailId(query.accountId); mailText(query.folder, 200);
  if (query.limit !== undefined && (!Number.isInteger(query.limit) || query.limit < 1 || query.limit > 20)) { throw new Error('Mail limit must be 1–20'); }
  if (query.unreadOnly !== undefined && typeof query.unreadOnly !== 'boolean') { throw new Error('Expected unreadOnly boolean'); }
  if (query.from !== undefined) { mailText(query.from, 200); }
  if (query.subject !== undefined) { mailText(query.subject, 200); }
}
