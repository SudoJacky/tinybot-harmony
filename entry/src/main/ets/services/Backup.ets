import { t } from '../model/I18n';
import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { AppData, parseAppData, defaultConfig } from '../model/Conversation';
import { Attachment } from '../model/Productivity';
import { WorkspaceStore } from '../model/WorkspaceStore';
import { workspaceRelativePath } from './WorkspaceTools';
import { Attachments, readBounded, writeBytes } from './Attachments';
import { exportFile } from './NativeActions';
interface BackupFile { threadId: string; path: string; bytes: string; }
interface BackupAttachment { id: string; bytes: string; }
interface BackupEnvelope { format: string; data: AppData; attachments: BackupAttachment[]; files: BackupFile[]; }
const MAX_BACKUP = 20 * 1024 * 1024;
async function encodeFile(path: string): Promise<string> {
  const file = await fs.open(path, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
  try { return new util.Base64Helper().encodeToString(new Uint8Array(await readBounded(file.fd, 4 * 1024 * 1024))); }
  finally { await fs.close(file); }
}
function allAttachments(data: AppData): Attachment[] {
  const result = new Map<string, Attachment>();
  for (const thread of data.threads) { for (const item of (thread.attachments || []).concat(...thread.messages.map((message) => message.attachments || []))) { result.set(item.id, item); } }
  return Array.from(result.values());
}
export async function exportBackup(context: common.UIAbilityContext, data: AppData): Promise<void> {
  const envelope: BackupEnvelope = { format: 'tinybot-harmony.backup.v1', data: data, attachments: [], files: [] };
  data.config = defaultConfig();
  for (const profile of data.providerProfiles || []) { profile.credentialAlias = ''; profile.noApiKey = true; profile.enabled = false; }
  for (const server of data.productivity?.servers || []) { server.credentialAlias = ''; server.authType = undefined; server.enabled = false; }
  let size = JSON.stringify(data).length * 3;
  for (const item of allAttachments(data)) { const bytes = await encodeFile(Attachments.path(item)); size += bytes.length; if (size > MAX_BACKUP) { throw new Error(t("备份超过 20 MB，请先清理不需要的附件。")); } envelope.attachments.push({ id: item.id, bytes: bytes }); }
  const workspaces = new WorkspaceStore(context.getApplicationContext().filesDir);
  for (const thread of data.threads) {
    const root = workspaces.pathFor(thread.id); const pending = [''];
    if (!await fs.access(root)) { continue; }
    while (pending.length) {
      const directory = pending.shift() || '';
      for (const name of await fs.listFile(root + (directory ? '/' + directory : ''))) {
        if (name.startsWith('.tinybot-')) { continue; }
        const path = (directory ? directory + '/' : '') + name; workspaceRelativePath(path, false);
        const absolute = root + '/' + path; const stat = await fs.lstat(absolute);
        if (stat.isSymbolicLink()) { throw new Error(t("备份不支持符号链接：") + path); }
        if (stat.isDirectory()) { pending.push(path); }
        else if (stat.isFile()) {
          const bytes = await encodeFile(absolute); size += bytes.length;
          if (size > MAX_BACKUP || envelope.files.length >= 1000) { throw new Error(t("备份最多 20 MB、1000 个文件。")); }
          envelope.files.push({ threadId: thread.id, path: path, bytes: bytes });
        }
      }
    }
  }
  const bytes = new util.TextEncoder().encodeInto(JSON.stringify(envelope));
  if (bytes.byteLength > MAX_BACKUP) { throw new Error(t("备份超过 20 MB。")); }
  const path = context.cacheDir + '/backup-' + util.generateRandomUUID() + '.json';
  await writeBytes(path, bytes.buffer as ArrayBuffer); await exportFile(context, path, 'Tinybot备份.json');
}
export async function readBackup(context: common.UIAbilityContext): Promise<AppData | undefined> {
  const uris = await new picker.DocumentViewPicker(context).select({ maxSelectNumber: 1, fileSuffixFilters: ['Tinybot 备份|.json'] });
  if (!uris.length) { return undefined; }
  const file = await fs.open(uris[0], fs.OpenMode.READ_ONLY); let text = '';
  try { text = new util.TextDecoder('utf-8', { fatal: true }).decodeToString(new Uint8Array(await readBounded(file.fd, MAX_BACKUP))); }
  finally { await fs.close(file); }
  const envelope = JSON.parse(text) as BackupEnvelope;
  if (!envelope || envelope.format !== 'tinybot-harmony.backup.v1' || !Array.isArray(envelope.attachments) || !Array.isArray(envelope.files) || envelope.files.length > 1000) { throw new Error(t("备份格式无效。")); }
  const data = parseAppData(JSON.stringify(envelope.data));
  const threadIds = new Map<string, string>(); const messageIds = new Map<string, string>();
  for (const thread of data.threads) { threadIds.set(thread.id, util.generateRandomUUID()); for (const message of thread.messages) { if (!messageIds.has(message.id)) { messageIds.set(message.id, util.generateRandomUUID()); } } }
  const attachmentIds = new Map<string, string>(); const binaries = new Map<string, Uint8Array>(); const paths = new Set<string>();
  for (const item of envelope.attachments) {
    if (!item || typeof item.id !== 'string' || typeof item.bytes !== 'string' || item.bytes.length > 6 * 1024 * 1024 || binaries.has(item.id)) { throw new Error(t("备份附件无效。")); }
    binaries.set(item.id, new util.Base64Helper().decodeSync(item.bytes)); attachmentIds.set(item.id, util.generateRandomUUID());
  }
  for (const item of allAttachments(data)) { if (!binaries.has(item.id) || binaries.get(item.id)?.byteLength !== item.size) { throw new Error(t("备份缺少附件或大小不一致。")); } }
  for (const item of envelope.files) {
    if (!threadIds.has(item.threadId) || typeof item.bytes !== 'string' || item.bytes.length > 6 * 1024 * 1024) { throw new Error(t("备份文件无效。")); }
    workspaceRelativePath(item.path, false); const key = item.threadId + '/' + item.path;
    if (paths.has(key)) { throw new Error(t("备份包含重复文件。")); } paths.add(key);
  }
  const workspace = new WorkspaceStore(context.getApplicationContext().filesDir);
  const attachmentRoot = context.getApplicationContext().filesDir + '/attachments'; if (!await fs.access(attachmentRoot)) { await fs.mkdir(attachmentRoot); }
  for (const item of allAttachments(data)) { const id = attachmentIds.get(item.id) as string; const path = id + (item.mime === 'image/jpeg' ? '.jpg' : '.txt'); await writeBytes(attachmentRoot + '/' + path, (binaries.get(item.id) as Uint8Array).buffer as ArrayBuffer); }
  for (const thread of data.threads) { await workspace.ensureThread(threadIds.get(thread.id) as string); }
  for (const item of envelope.files) {
    const root = workspace.pathFor(threadIds.get(item.threadId) as string); const parts = item.path.split('/'); let directory = root;
    for (const part of parts.slice(0, -1)) { directory += '/' + part; if (!await fs.access(directory)) { await fs.mkdir(directory); } }
    await writeBytes(root + '/' + item.path, new util.Base64Helper().decodeSync(item.bytes).buffer as ArrayBuffer);
  }
  const providers = new Map<string, string>();
  for (const profile of data.providerProfiles || []) { const id = 'provider-' + util.generateRandomUUID(); providers.set(profile.id, id); profile.id = id; profile.enabled = false; profile.noApiKey = true; profile.credentialAlias = ''; profile.name += '（恢复后请配置密钥）'; }
  for (const thread of data.threads) {
    thread.id = threadIds.get(thread.id) as string; thread.parentThreadId = threadIds.get(thread.parentThreadId || ''); thread.parentMessageId = messageIds.get(thread.parentMessageId || '');
    thread.pendingInputs = []; thread.queuePaused = true;
    for (const reference of (thread.references || []).concat(...thread.messages.map((message) => message.references || []))) {
      reference.threadId = threadIds.get(reference.threadId) || reference.threadId;
    }
    thread.disabledMcpIds = [];
    for (const run of thread.teams || []) {
      if (run.ownerMessageId) { run.ownerMessageId = messageIds.get(run.ownerMessageId) || run.ownerMessageId; }
      run.id = util.generateRandomUUID(); run.model.providerId = providers.get(run.model.providerId) || run.model.providerId;
      for (const record of run.tasks) { for (const attempt of record.attempts) { attempt.id = util.generateRandomUUID(); } }
    }
    if (thread.compaction) { thread.compaction.firstKeptMessageId = messageIds.get(thread.compaction.firstKeptMessageId) || thread.compaction.firstKeptMessageId; }
    if (thread.modelRef) { thread.modelRef.providerId = providers.get(thread.modelRef.providerId) || thread.modelRef.providerId; }
    for (const message of thread.messages) { message.id = messageIds.get(message.id) as string; if (message.modelRef) { message.modelRef.providerId = providers.get(message.modelRef.providerId) || message.modelRef.providerId; } }
    for (const item of (thread.attachments || []).concat(...thread.messages.map((message) => message.attachments || []))) {
      const id = attachmentIds.get(item.id); if (id) { item.id = id; item.path = id + (item.mime === 'image/jpeg' ? '.jpg' : '.txt'); }
    }
  }
  for (const memory of data.productivity?.memories || []) { memory.id = util.generateRandomUUID(); memory.threadId = threadIds.get(memory.threadId) || ''; memory.sourceThreadId = threadIds.get(memory.sourceThreadId || ''); memory.sourceMessageId = messageIds.get(memory.sourceMessageId || ''); }
  for (const template of data.productivity?.templates || []) { template.id = util.generateRandomUUID(); }
  for (const server of data.productivity?.servers || []) { server.id = util.generateRandomUUID(); server.enabled = false; server.credentialAlias = ''; server.authType = undefined; }
  data.activeThreadId = threadIds.get(data.activeThreadId) || ''; data.config = defaultConfig();
  return data;
}
