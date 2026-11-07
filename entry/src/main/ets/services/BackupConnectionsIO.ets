import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { AppData } from '../model/Conversation';
import { BackupConnections } from '../model/BackupConnections';
import { MailAccount } from '../model/Mail';
import { defaultAssistantOptions } from '../model/AssistantOptions';
import { PanelRecord, parsePanelRecord } from '../model/LifePanel';
import { WorkspaceStore } from '../model/WorkspaceStore';
import { WorkspaceOwnership } from './WorkspaceRetention';
import { CredentialStore } from './CredentialStore';
import { MailAccounts } from './MailAccounts';
import { PanelCredentials } from './PanelCredentials';
import { NativeWorkspaceFiles } from './NativeWorkspaceFiles';
import { Cancellation } from './Cancellation';
import { SessionImportCandidate } from './SessionCandidates';
import { rollbackBackupActions, rollbackBackupFailure } from '../model/BackupImport';

export interface RestoredPanelFile { workspaceId: string; path: string; }
interface ChangedPanel { files: NativeWorkspaceFiles; path: string; before: string; version: string; }
export async function captureBackupConnections(data: AppData, root: string, inventory: WorkspaceOwnership[]): Promise<BackupConnections> {
  const vault = new CredentialStore(), result: BackupConnections = { mcp: [], mail: [], panels: [] };
  for (const server of data.productivity?.servers || []) {
    if (!server.credentialAlias) { continue; }
    result.mcp!.push({ server: server, secret: await vault.read(server.credentialAlias) });
  }
  const search = data.productivity?.options?.search;
  if (search) {
    result.search = { config: search };
    if (search.credentialAlias) { result.search.key = await vault.read(search.credentialAlias); }
    if (search.tavily?.credentialAlias) { result.search.tavilyKey = await vault.read(search.tavily.credentialAlias); }
  }
  for (const stored of await new MailAccounts().backup()) { result.mail!.push({ account: stored.account, secret: stored.secret }); }
  const workspaces = new WorkspaceStore(root);
  for (const owner of inventory.filter((item) => item.manifests.includes('life-panels'))) {
    const directory = workspaces.pathFor(owner.id) + '/life-panels';
    for (const id of await fs.listFile(directory)) {
      const path = directory + '/' + id + '/panel.json'; if (!await fs.access(path)) { continue; }
      const panel = parsePanelRecord(await fs.readText(path), id), source = panel.definition.source;
      if (source?.type !== 'api' || !source.auth) { continue; }
      const secret = await new PanelCredentials(workspaces.pathFor(owner.id)).backup(id, source);
      if (secret) { result.panels!.push({ workspaceId: owner.id, panelId: id, source: source, secret: secret.secret, oauth: secret.oauth }); }
    }
  }
  result.feedbackIdentity = await vault.readOptional('tinybot.feedback.identity.v1');
  return result;
}

// Only imported records are changed. Existing local services and credential aliases always win.
export async function prepareBackupConnections(root: string, local: AppData, candidate: SessionImportCandidate,
  connections: BackupConnections | undefined, panels: RestoredPanelFile[], workspaceIds: Map<string, string>): Promise<() => Promise<void>> {
  const vault = new CredentialStore(), aliases: string[] = [], mailIds: string[] = [], connected: PanelCredentials[] = [], connectedIds: string[] = [];
  const changed: ChangedPanel[] = [], workspaces = new WorkspaceStore(root), signal = new Cancellation();
  const rollback = async (): Promise<void> => {
    const actions: (() => Promise<void>)[] = changed.slice().reverse().map((item) => async (): Promise<void> => {
      await item.files.writeLifePanel(item.path, item.before, signal, { version: item.version });
    });
    connected.forEach((credentials, index) => actions.push(() => credentials.disconnect(connectedIds[index])));
    mailIds.forEach((id) => actions.push(() => new MailAccounts().remove(id)));
    aliases.forEach((alias) => actions.push(() => vault.remove(alias)));
    await rollbackBackupActions(actions);
  };
  try {
    for (const item of connections?.mcp || []) {
      const id = candidate.serverIds.get(item.server.id), server = candidate.data.productivity?.servers.find((entry) => entry.id === id);
      if (!server || (local.productivity?.servers || []).some((entry) => entry.id === id)) { continue; }
      if (server.url !== item.server.url) { throw new Error('MCP backup scope mismatch'); }
      server.credentialAlias = 'tinybot-mcp-' + util.generateRandomUUID(); aliases.push(server.credentialAlias);
      await vault.write(server.credentialAlias, item.secret); server.authType = item.server.authType; server.enabled = item.server.enabled;
    }
    const search = candidate.data.productivity?.options?.search, savedSearch = connections?.search;
    const localSearch = local.productivity?.options?.search;
    if (search && savedSearch && (!localSearch || JSON.stringify(localSearch) === JSON.stringify(defaultAssistantOptions().search)) && search.provider === savedSearch.config.provider &&
      search.baseUrl === savedSearch.config.baseUrl) {
      search.enabled = savedSearch.config.enabled;
      if (savedSearch.key && !search.credentialAlias) {
        search.credentialAlias = 'tinybot-search-' + util.generateRandomUUID(); aliases.push(search.credentialAlias); await vault.write(search.credentialAlias, savedSearch.key);
        search.enabled = savedSearch.config.enabled;
      }
      if (savedSearch.tavilyKey && search.tavily && !search.tavily.credentialAlias && search.tavily.baseUrl === savedSearch.config.tavily?.baseUrl) {
        if (search.provider === 'tavily' && search.credentialAlias && savedSearch.key === savedSearch.tavilyKey) { search.tavily.credentialAlias = search.credentialAlias; }
        else {
          search.tavily.credentialAlias = 'tinybot-tavily-' + util.generateRandomUUID(); aliases.push(search.tavily.credentialAlias);
          await vault.write(search.tavily.credentialAlias, savedSearch.tavilyKey);
        }
        if (search.provider === 'tavily') { search.enabled = savedSearch.config.enabled; }
      }
    }
    const mailMap = new Map<string, string>(), accounts = new MailAccounts(), existing = await accounts.list();
    for (const item of connections?.mail || []) {
      const match = existing.find((account) => account.host === item.account.host && account.port === item.account.port && account.username === item.account.username);
      if (match) { mailMap.set(item.account.id, match.id); continue; }
      const account = JSON.parse(JSON.stringify(item.account)) as MailAccount;
      if (existing.some((entry) => entry.id === account.id)) { account.id = 'mail-' + util.generateRandomUUID(); }
      mailMap.set(item.account.id, account.id); await accounts.save(account, item.secret); mailIds.push(account.id); existing.push(account);
    }
    if (connections?.feedbackIdentity && await vault.readOptional('tinybot.feedback.identity.v1') === undefined) {
      await vault.write('tinybot.feedback.identity.v1', connections.feedbackIdentity); aliases.push('tinybot.feedback.identity.v1');
    }
    for (const item of panels) {
      const files = new NativeWorkspaceFiles(workspaces.pathFor(item.workspaceId)), file = await files.read(item.path, signal);
      const panel = parsePanelRecord(file.content, item.path.split('/')[1]);
      remapPanelConnections(panel, candidate.providerIds, mailMap);
      const serialized = JSON.stringify(panel);
      if (serialized !== file.content) {
        const written = await files.writeLifePanel(item.path, serialized, signal, { version: file.version });
        changed.push({ files: files, path: item.path, before: file.content, version: written.version });
      }
    }
    for (const item of connections?.panels || []) {
      const owner = workspaceIds.get(item.workspaceId) || item.workspaceId;
      if (!panels.some((file) => file.workspaceId === owner && file.path === 'life-panels/' + item.panelId + '/panel.json')) { continue; }
      const files = new NativeWorkspaceFiles(workspaces.pathFor(owner)), current = parsePanelRecord((await files.read('life-panels/' + item.panelId + '/panel.json', signal)).content, item.panelId);
      if (JSON.stringify(current.definition.source) !== JSON.stringify(item.source)) { throw new Error('Panel backup scope mismatch'); }
      const credentials = new PanelCredentials(workspaces.pathFor(owner));
      if (await credentials.restore(item.panelId, item.source, { secret: item.secret, oauth: item.oauth })) { connected.push(credentials); connectedIds.push(item.panelId); }
    }
    return rollback;
  } catch (error) { await rollbackBackupFailure(error as Error, rollback); throw error as Error; }
}
function remapPanelConnections(panel: PanelRecord, providers: Map<string, string>, mail: Map<string, string>): void {
  const source = panel.definition.source;
  if (source?.type === 'mail' && source.mail) {
    source.mail.accountId = mail.get(source.mail.accountId) || source.mail.accountId;
    for (const value of [panel.data, panel.definition.data]) {
      const snapshot = value as MailSnapshot;
      if (snapshot && typeof snapshot.accountId === 'string') { snapshot.accountId = mail.get(snapshot.accountId) || snapshot.accountId; }
    }
  }
  if (source?.type !== 'provider-balance') { return; }
  source.providerIds = Array.from(new Set((source.providerIds || []).map((id: string) => providers.get(id) || id)));
  const input = panel.definition.inputs?.['providerId'];
  if (input) {
    if (typeof input.default === 'string') { input.default = providers.get(input.default) || input.default; }
    input.options = input.options ? Array.from(new Set(input.options.map((value) => typeof value === 'string' ? providers.get(value) || value : value))) : undefined;
  }
  if (typeof panel.inputs?.['providerId'] === 'string') { const id = panel.inputs['providerId'] as string; panel.inputs['providerId'] = providers.get(id) || id; }
  for (const value of [panel.data, panel.definition.data]) {
    const data = value as BalanceSnapshot;
    if (data && typeof data.providerId === 'string') { data.providerId = providers.get(data.providerId) || data.providerId; }
    if (data && Array.isArray(data.accounts)) { data.accounts.forEach((item) => { if (item && typeof item.id === 'string') { item.id = providers.get(item.id) || item.id; } }); }
  }
}
interface BalanceSnapshot { providerId?: string; accounts?: BalanceAccount[]; }
interface BalanceAccount { id: string; }
interface MailSnapshot { accountId?: string; }
