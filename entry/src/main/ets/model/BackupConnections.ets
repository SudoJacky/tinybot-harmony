import { McpServer, validateProductivity } from './Productivity';
import { SearchConfig, validateSearchConfig } from './WebSearch';
import { MailAccount, validateMailAccount } from './Mail';
import { PanelSource, validatePanelSource } from './PanelSource';
import { panelId } from './LifePanel';
import { threadWorkspacePath } from './Workspace';
import { validFeedbackToken } from './Feedback';

export interface BackupMcpConnection { server: McpServer; secret: string; }
export interface BackupSearchConnection { config: SearchConfig; key?: string; tavilyKey?: string; }
export interface BackupMailConnection { account: MailAccount; secret: string; }
export interface BackupPanelConnection { workspaceId: string; panelId: string; source: PanelSource; secret?: string; oauth?: string; }
export interface BackupConnections {
  mcp?: BackupMcpConnection[]; search?: BackupSearchConnection; mail?: BackupMailConnection[];
  panels?: BackupPanelConnection[]; feedbackIdentity?: string;
}
export function validateBackupConnections(value: BackupConnections): void {
  if (!value || typeof value !== 'object' || Array.isArray(value)) { throw new Error('Invalid backup connections'); }
  if (value.mcp !== undefined && (!Array.isArray(value.mcp) || value.mcp.some((item) => !item?.server || typeof item.secret !== 'string' || !item.secret || typeof item.server.url !== 'string'))) { throw new Error('Invalid MCP backup connection'); }
  if (value.mcp) { validateProductivity({ memories: [], templates: [], servers: value.mcp.map((item) => item.server) }); }
  if (value.mail !== undefined) {
    if (!Array.isArray(value.mail) || value.mail.length > 8) { throw new Error('Invalid mailbox backup connections'); }
    const ids = new Set<string>();
    for (const item of value.mail) {
      validateMailAccount(item.account);
      if (ids.has(item.account.id) || typeof item.secret !== 'string' || !item.secret || /[\u0000-\u001f\u007f]/.test(item.secret)) { throw new Error('Invalid mailbox backup connection'); }
      ids.add(item.account.id);
    }
  }
  if (value.panels !== undefined) {
    if (!Array.isArray(value.panels)) { throw new Error('Invalid panel backup connections'); }
    const ids = new Set<string>();
    for (const item of value.panels) {
      if (!item || typeof item.workspaceId !== 'string' || typeof item.panelId !== 'string' ||
        (typeof item.secret === 'string') === (typeof item.oauth === 'string')) { throw new Error('Invalid panel backup connection'); }
      validatePanelSource(item.source);
      threadWorkspacePath('/workspace', item.workspaceId); panelId(item.panelId);
      const key = item.workspaceId + '/' + item.panelId;
      if (ids.has(key) || item.source.type !== 'api' || !item.source.auth ||
        (item.source.auth.type === 'oauth' ? !item.oauth : !item.secret || item.secret.length > 8192 || /[\r\n]/.test(item.secret))) { throw new Error('Invalid panel backup connection'); }
      ids.add(key);
    }
  }
  if (value.search !== undefined && (!value.search.config ||
    [value.search.key, value.search.tavilyKey].some((key) => key !== undefined && (typeof key !== 'string' || !key)))) { throw new Error('Invalid search backup connection'); }
  if (value.search) { validateSearchConfig(value.search.config, true); }
  if (value.feedbackIdentity !== undefined && !validFeedbackToken(value.feedbackIdentity)) { throw new Error('Invalid feedback backup identity'); }
}
export function backupSearchConfig(source: SearchConfig): SearchConfig {
  const config = JSON.parse(JSON.stringify(source)) as SearchConfig;
  if (config.tavily) { config.tavily.credentialAlias = ''; }
  if (config.provider === 'tavily') { config.credentialAlias = ''; config.enabled = false; }
  return config;
}
