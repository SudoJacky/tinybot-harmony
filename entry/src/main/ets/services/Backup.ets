import { BackupKeyPayload, attachBackupKeys } from './BackupKeyRestore';
import { CredentialStore } from './CredentialStore';
import { huaweiAccount } from './HuaweiAccount';
import { CredentialVault } from './ProfileSettings';
import { EncryptedBackupKeys, encryptBackupKeys, decryptBackupKeys } from './BackupKeys';
import { Diagnostics } from '../model/Diagnostics';
import { ProjectData, validateProjects, workspaceIdFor } from '../model/Project';
import { t } from '../model/I18n';
import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { AppData, ThreadData, parseAppData, defaultConfig } from '../model/Conversation';
import { Attachment } from '../model/Productivity';
import { toolReceipts } from '../model/Agent';
import { WorkspaceStore } from '../model/WorkspaceStore';
import { workspaceRelativePath } from './WorkspaceTools';
import { Attachments, writeBytes } from './Attachments';
import { copyFileBytes } from './FileBytes';
import { readUtf8File } from './TextFiles';
import { OpenBackupArchive, openBackupArchive, writeBackupArchive, cleanupBackupArchive } from './BackupArchive';
import { NativeWorkspaceFiles } from './NativeWorkspaceFiles';
import { MiniApps } from './MiniApps';
interface BackupFile { threadId?: string; workspaceId?: string; path: string; bytes: string; }
interface BackupAttachment { id: string; bytes: string; }
interface BackupEnvelope { protectedKeys?: EncryptedBackupKeys; format: string; data: AppData; attachments: BackupAttachment[]; files: BackupFile[]; miniAppWorkspaceIds?: string[]; }
// v3 bytes fields are canonical decimal blob indices; v1/v2 fields contain Base64.
function blobIndex(value: string, archive: OpenBackupArchive): number {
  const index = Number(value);
  if (!Number.isSafeInteger(index) || index < 0 || index >= archive.files.length || String(index) !== value) {
    throw new Error(t('备份文件无效。'));
  }
  return index;
}
function payloadSize(value: string, archive?: OpenBackupArchive): number {
  if (archive) { return archive.sizes[blobIndex(value, archive)]; }
  return new util.Base64Helper().decodeSync(value).byteLength;
}
async function writePayload(value: string, path: string, archive?: OpenBackupArchive): Promise<void> {
  if (archive) { await copyFileBytes(archive.files[blobIndex(value, archive)], path); }
  else { await writeBytes(path, new util.Base64Helper().decodeSync(value).buffer as ArrayBuffer); }
}
function threadAttachments(thread: ThreadData): Attachment[] {
  const result = (thread.attachments || []).concat(...thread.messages.map((message) => message.attachments || []));
  result.push(...(thread.pendingInputs || []).flatMap((input) => input.attachments || []));
  for (const message of thread.messages) {
    for (const step of message.steps || []) {
      result.push(...step.steering?.attachments || []);
      for (const tool of toolReceipts(step.tools)) { if (tool.previewScreenshot) { result.push(tool.previewScreenshot.image); }
        for (const frame of tool.browserObservation?.frames || []) { result.push(frame.image); } }
    }
  }
  return result;
}
function allAttachments(data: AppData): Attachment[] {
  const result = new Map<string, Attachment>();
  for (const thread of data.threads) { for (const item of threadAttachments(thread)) { result.set(item.id, item); } }
  return Array.from(result.values());
}
// Local export and Huawei Cloud share one archive; API keys only appear in the encrypted section.
export async function createBackupFile(context: common.UIAbilityContext, snapshot: AppData, vault: CredentialVault = new CredentialStore()): Promise<string> {
  const data = JSON.parse(JSON.stringify(snapshot)) as AppData;
  const envelope: BackupEnvelope = { format: 'tinybot-harmony.backup.v3', data: data, attachments: [], files: [] };
  validateProjects(data);
  if ((snapshot.providerProfiles || []).length) {
    envelope.protectedKeys = await encryptBackupKeys(snapshot, await huaweiAccount.backupOpenID(context), vault);
  }
  const userDocument = data.config.userDocument || '';
  data.config = defaultConfig(); data.config.userDocument = userDocument;
  for (const profile of data.providerProfiles || []) { profile.credentialAlias = ''; profile.noApiKey = true; profile.enabled = false; }
  for (const server of data.productivity?.servers || []) { server.credentialAlias = ''; server.authType = undefined; server.enabled = false; }
  if (data.productivity?.options?.search) {
    const search = data.productivity.options.search; search.enabled = false;
    if (search.tavily) { search.tavily.credentialAlias = ''; }
    if (search.provider === 'tavily') { search.credentialAlias = ''; } else { search.modelProviderId = undefined; }
  }
  const sources: string[] = [];
  const originals = new Set<string>();
  for (const thread of data.threads) {
    for (const item of threadAttachments(thread)) {
      if (item.original) {
        if (item.workspaceId !== workspaceIdFor(data, thread)) { throw new Error(t('备份附件无效。')); }
        originals.add(item.workspaceId + '/' + item.path);
      }
    }
  }
  for (const item of allAttachments(data)) {
    const source = Attachments.path(item);
    if ((await fs.stat(source)).size !== item.size) { throw new Error(t('备份缺少附件或大小不一致。')); }
    envelope.attachments.push({ id: item.id, bytes: String(sources.length) }); sources.push(source);
  }
  const workspaces = new WorkspaceStore(context.getApplicationContext().filesDir);
  const projectRoots = new Set((data.projects || []).map((project) => project.workspaceId));
  const ownedRoots = Array.from(projectRoots).concat(data.threads.filter((thread) => !thread.projectId).map((thread) => thread.id));
  const appRoots = (await new MiniApps(context.getApplicationContext().filesDir).list()).map((entry) => entry.workspaceId);
  envelope.miniAppWorkspaceIds = Array.from(new Set(appRoots.filter((id) => !ownedRoots.includes(id))));
  const roots = Array.from(new Set(ownedRoots.concat(envelope.miniAppWorkspaceIds)));
  for (const workspaceId of roots) {
    const root = workspaces.pathFor(workspaceId); const pending = [''];
    if (!projectRoots.has(workspaceId) && !await fs.access(root)) { continue; }
    await workspaces.requireWorkspace(workspaceId);
    while (pending.length) {
      const directory = pending.shift() || '';
      for (const name of await fs.listFile(root + (directory ? '/' + directory : ''))) {
        if (name.startsWith('.tinybot-')) { continue; }
        const path = (directory ? directory + '/' : '') + name; workspaceRelativePath(path, false);
        const absolute = root + '/' + path; const stat = await fs.lstat(absolute);
        if (stat.isSymbolicLink()) { throw new Error(t("备份不支持符号链接：") + path); }
        if (stat.isDirectory()) { pending.push(path); }
        else if (stat.isFile()) {
          // Original attachment bytes are already in the attachment section, including shared project copies.
          if (originals.has(workspaceId + '/' + path)) { continue; }
          envelope.files.push({ workspaceId: workspaceId, path: path, bytes: String(sources.length) }); sources.push(absolute);
        }
      }
    }
  }
  const path = context.cacheDir + '/backup-' + util.generateRandomUUID() + '.tinybot';
  await writeBackupArchive(path, JSON.stringify(envelope), sources);
  return path;
}
export async function exportBackup(context: common.UIAbilityContext, data: AppData): Promise<void> {
  const path = await createBackupFile(context, data);
  try {
    const uris = await new picker.DocumentViewPicker(context).save({ newFileNames: ['Tinybot备份.tinybot'] });
    if (!uris.length) { return; }
    const input = await fs.open(path, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
    try {
      const output = await fs.open(uris[0], fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        await fs.copyFile(input.fd, output.fd);
        if ((await fs.stat(input.fd)).size !== (await fs.stat(output.fd)).size) { throw new Error(t('文件写入未完成。')); }
        await fs.fsync(output.fd);
      } finally { await fs.close(output); }
    } finally { await fs.close(input); }
  }
  finally { await fs.unlink(path); }
}
export async function readBackup(context: common.UIAbilityContext, local: AppData): Promise<AppData | undefined> {
  const uris = await new picker.DocumentViewPicker(context).select({ maxSelectNumber: 1, fileSuffixFilters: ['Tinybot 备份|.tinybot,.json'] });
  if (!uris.length) { return undefined; }
  return readBackupFile(context, uris[0], local);
}
export async function readBackupFile(context: common.UIAbilityContext, path: string, local: AppData): Promise<AppData> {
  const started = Date.now();
  let archive: OpenBackupArchive | undefined;
  try {
    let keys: BackupKeyPayload | undefined;
    const unlock = async (envelope: BackupEnvelope): Promise<void> => {
      if (envelope?.protectedKeys !== undefined) {
        if (!envelope.protectedKeys || envelope.protectedKeys.version !== 2) { throw new Error(t('备份密钥格式无效。')); }
        const credential = await huaweiAccount.backupOpenID(context);
        keys = await decryptBackupKeys(envelope.protectedKeys, credential, envelope.data);
      }
    };
    archive = await openBackupArchive(path, context.cacheDir, async (metadata: string) => {
      const envelope = JSON.parse(metadata) as BackupEnvelope;
      await unlock(envelope);
    });
    let text = archive?.metadata || '';
    if (!archive) {
      const file = await fs.open(path, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
      try { text = await readUtf8File(file.fd); }
      finally { await fs.close(file); }
    }
    const envelope = JSON.parse(text) as BackupEnvelope;
    const formats = archive ? ['tinybot-harmony.backup.v3'] : ['tinybot-harmony.backup.v1', 'tinybot-harmony.backup.v2'];
    if (!envelope || !formats.includes(envelope.format) || !Array.isArray(envelope.attachments) || !Array.isArray(envelope.files)) { throw new Error(t('备份格式无效。')); }
    if (!archive) { await unlock(envelope); }
    const result = await restoreEnvelope(context, local, envelope, archive);
    if (keys) { attachBackupKeys(result, keys); }
    Diagnostics.log('info', 'backup', 'restore_completed', { durationMs: Date.now() - started, newChats: result.threads.length });
    return result;
  } catch (error) {
    Diagnostics.log('error', 'backup', 'restore_failed', { durationMs: Date.now() - started }, error as Error);
    throw error as Error;
  } finally { if (archive) { await cleanupBackupArchive(archive.directory); } }
}
async function restoreEnvelope(context: common.UIAbilityContext, local: AppData, envelope: BackupEnvelope,
  archive?: OpenBackupArchive): Promise<AppData> {
  const data = parseAppData(JSON.stringify(envelope.data));
  // Keep record identities across devices and repeated restores. Local records win.
  const legacy = envelope.format === 'tinybot-harmony.backup.v1';
  if (legacy && ((data.projects || []).length > 0 || data.threads.some((thread) => thread.projectId !== undefined))) { throw new Error(t('备份格式无效。')); }
  const workspaceIds = new Set(data.threads.filter((thread) => !thread.projectId).map((thread) => thread.id)
    .concat((data.projects || []).map((project) => project.workspaceId)));
  const retainedRoots = envelope.miniAppWorkspaceIds || [];
  if (!Array.isArray(retainedRoots) || retainedRoots.some((id) => typeof id !== 'string') || new Set(retainedRoots).size !== retainedRoots.length ||
    (legacy && retainedRoots.length > 0)) { throw new Error(t('备份文件无效。')); }
  for (const id of retainedRoots) {
    if (workspaceIds.has(id) || !envelope.files.some((item) => item.workspaceId === id && /^mini-apps\/[^/]+\/app\.json$/.test(item.path))) {
      throw new Error(t('备份文件无效。'));
    }
    workspaceIds.add(id);
  }
  const known = new Set(local.threads.map((thread) => thread.id));
  const workspace = new WorkspaceStore(context.getApplicationContext().filesDir);
  for (const id of Array.from(workspaceIds)) { workspace.pathFor(id); }
  const attachmentIds = new Map<string, string>(); const binaries = new Map<string, string>(); const paths = new Set<string>();
  for (const item of envelope.attachments) {
    if (!item || typeof item.id !== 'string' || typeof item.bytes !== 'string' || binaries.has(item.id)) { throw new Error(t("备份附件无效。")); }
    payloadSize(item.bytes, archive);
    binaries.set(item.id, item.bytes); attachmentIds.set(item.id, util.generateRandomUUID());
  }
  for (const item of allAttachments(data)) { if (!binaries.has(item.id) || payloadSize(binaries.get(item.id) as string, archive) !== item.size) { throw new Error(t("备份缺少附件或大小不一致。")); } }
  for (const item of envelope.files) {
    if (!item) { throw new Error(t("备份文件无效。")); }
    const id = legacy ? item.threadId : item.workspaceId;
    if (typeof id !== 'string' || !workspaceIds.has(id) || (legacy ? item.workspaceId !== undefined : item.threadId !== undefined) || typeof item.bytes !== 'string') { throw new Error(t("备份文件无效。")); }
    workspaceRelativePath(item.path, false); const key = id + '/' + item.path;
    if (paths.has(key)) { throw new Error(t("备份包含重复文件。")); } paths.add(key);
    payloadSize(item.bytes, archive);
  }
  if (archive) {
    const references = envelope.attachments.map((item) => item.bytes).concat(envelope.files.map((item) => item.bytes));
    if (references.length !== archive.files.length || new Set(references).size !== references.length) { throw new Error(t('备份文件无效。')); }
  }
  const totalThreads = data.threads.length;
  data.threads = data.threads.filter((thread) => !known.has(thread.id));
  const additions = new Set(data.threads.map((thread) => thread.id));
  if (!additions.has(data.activeThreadId)) { data.activeThreadId = ''; }
  if (Diagnostics.acceptsLog('info')) { Diagnostics.log('info', 'backup', 'restore_prepared', { newChats: data.threads.length, skippedChats: totalThreads - data.threads.length }); };
  // New projects are restored into fresh roots; existing projects keep their local root and bytes.
  // Until the session manifest commits, prepared files are unreferenced and cannot replace local projects.
  const destinations = new Map<string, string>();
  for (const id of retainedRoots) {
    if (!await fs.access(workspace.pathFor(id))) { destinations.set(id, id); }
    else { await workspace.requireWorkspace(id); }
  }
  for (const thread of data.threads) { if (!thread.projectId) { destinations.set(thread.id, thread.id); } }
  data.projects = (data.projects || []).map((project): ProjectData => {
    const existing = (local.projects || []).find((item) => item.id === project.id);
    if (existing) { return JSON.parse(JSON.stringify(existing)) as ProjectData; }
    const previous = project.workspaceId;
    project.workspaceId = 'project-' + util.generateRandomUUID();
    destinations.set(previous, project.workspaceId);
    return project;
  });
  const merged: AppData = { version: 2, config: local.config, activeThreadId: local.activeThreadId,
    threads: local.threads.concat(data.threads), projects: (local.projects || []).concat((data.projects || [])
      .filter((project) => !(local.projects || []).some((item) => item.id === project.id))) };
  validateProjects(merged);
  for (const project of data.projects || []) {
    if ((local.projects || []).some((item) => item.id === project.id)) { await workspace.requireWorkspace(project.workspaceId); }
  }
  const attachmentRoot = context.getApplicationContext().filesDir + '/attachments'; if (!await fs.access(attachmentRoot)) { await fs.mkdir(attachmentRoot); }
  for (const item of allAttachments(data).filter((item) => !item.original)) { const id = attachmentIds.get(item.id) as string; const path = id + (item.mime === 'image/jpeg' ? '.jpg' : '.txt'); await writePayload(binaries.get(item.id) as string, attachmentRoot + '/' + path, archive); }
  for (const id of Array.from(destinations.values())) { await workspace.ensureThread(id); }
  for (let index = 0; index < envelope.files.length; index++) {
    const item = envelope.files[index];
    const target = destinations.get((legacy ? item.threadId : item.workspaceId) as string);
    if (!target) { continue; }
    const root = workspace.pathFor(target); const parts = item.path.split('/'); let directory = root;
    for (const part of parts.slice(0, -1)) {
      directory += '/' + part;
      if (!await fs.access(directory)) { await fs.mkdir(directory); }
      const stat = await fs.lstat(directory);
      if (!stat.isDirectory() || stat.isSymbolicLink()) { throw new Error(t('工作区路径必须是目录，不能是符号链接。')); }
    }
    if (await fs.access(root + '/' + item.path)) {
      const stat = await fs.lstat(root + '/' + item.path);
      if (!stat.isFile() || stat.isSymbolicLink()) { throw new Error(t('备份文件无效。')); }
    }
    if (archive) {
      await new NativeWorkspaceFiles(root).importFile(archive.files[blobIndex(item.bytes, archive)], item.path, true);
    } else {
      const temporary = attachmentRoot + '/restore-' + util.generateRandomUUID() + '.bin';
      try {
        await writePayload(item.bytes, temporary);
        await new NativeWorkspaceFiles(root).importFile(temporary, item.path, true);
      } finally { if (await fs.access(temporary)) { await fs.unlink(temporary); } }
    }
  }
  // Keep service IDs until SessionService can match them against this device's settings.
  for (const profile of data.providerProfiles || []) { profile.enabled = false; profile.noApiKey = true; profile.credentialAlias = ''; }
  for (const thread of data.threads) {
    thread.pendingInputs = []; thread.queuePaused = true;
    for (const item of threadAttachments(thread)) {
      if (item.original) {
        const workspaceId = workspaceIdFor(data, thread);
        await workspace.ensureThread(workspaceId);
        const value = binaries.get(item.id) as string;
        const files = new NativeWorkspaceFiles(workspace.pathFor(workspaceId));
        if (archive) { await files.importFile(archive.files[blobIndex(value, archive)], item.path, true); }
        else {
          const temporary = attachmentRoot + '/restore-' + util.generateRandomUUID() + '.bin';
          try {
            await writePayload(value, temporary);
            await files.importFile(temporary, item.path, true);
          } finally { if (await fs.access(temporary)) { await fs.unlink(temporary); } }
        }
        item.workspaceId = workspaceId;
        continue;
      }
      const id = attachmentIds.get(item.id); if (id) { item.id = id; item.path = id + (item.mime === 'image/jpeg' ? '.jpg' : '.txt'); }
    }
  }
  for (const server of data.productivity?.servers || []) { server.enabled = false; server.credentialAlias = ''; server.authType = undefined; }
  if (data.productivity?.options?.search) {
    const search = data.productivity.options.search; search.enabled = false;
    if (search.tavily) { search.tavily.credentialAlias = ''; }
    if (search.provider === 'tavily') { search.credentialAlias = ''; } else { search.modelProviderId = undefined; }
  }
  const userDocument = data.config.userDocument || '';
  data.config = defaultConfig();
  data.config.userDocument = userDocument;
  return data;
}
