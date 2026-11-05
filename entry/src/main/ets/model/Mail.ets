export interface MailAccount {
  id: string; name: string; host: string; port: number; username: string;
  folders: string[]; enabled: boolean; allowBody: boolean;
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
  mailId(account.id); mailText(account.name, 80); mailText(account.username, 254);
  if (typeof account.host !== 'string' || account.host.length > 253 || !/^[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?$/.test(account.host) ||
    !Number.isInteger(account.port) || account.port < 1 || account.port > 65535) { throw new Error('Expected IMAP server hostname and TLS port'); }
  if (!Array.isArray(account.folders) || !account.folders.length || account.folders.length > 16 || new Set(account.folders).size !== account.folders.length) { throw new Error('Choose 1–16 distinct mail folders'); }
  account.folders.forEach((folder: string) => mailText(folder, 200));
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
