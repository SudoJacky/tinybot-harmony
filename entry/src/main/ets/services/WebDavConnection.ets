import { url, util } from '@kit.ArkTS';
import { rcp } from '@kit.RemoteCommunicationKit';
import { t } from '../model/I18n';
import { ToolFailure } from '../model/ToolFailure';
import { CredentialStore } from './CredentialStore';
import { withFileMutation } from './FileMutationQueue';

export interface WebDavSettings {
  id: string;
  name: string;
  directory: string;
  username: string;
  grantId?: string;
}

interface WebDavConnection {
  name?: string;
  directory: string;
  username: string;
  password: string;
  id?: string;
}

const LEGACY_ID = 'legacy';
const LEGACY_ALIAS = 'tinybot.webdav.backup.v1';
const CONNECTION_GROUP = 'tinybot.webdav.connections';
const CONNECTION_PREFIX = CONNECTION_GROUP + '.';
const vault = new CredentialStore();

function directoryUrl(value: string): string {
  const address = value.trim();
  if (!/^https:\/\/[^/]/i.test(address) || /[?#\\\u0000-\u001f\u007f]/.test(address)) {
    throw new Error(t('请输入 HTTPS WebDAV 目录地址，地址中不要包含账号、密码、查询参数或片段。'));
  }
  let parsed: url.URL;
  try { parsed = url.URL.parseURL(address); }
  catch (_) { throw new Error(t('请输入有效的 WebDAV 目录地址。')); }
  if (!parsed.hostname || parsed.username || parsed.password || address.slice(8).split('/')[0].includes('@')) {
    throw new Error(t('请输入 HTTPS WebDAV 目录地址，地址中不要包含账号、密码、查询参数或片段。'));
  }
  const canonical = parsed.toString();
  return canonical.endsWith('/') ? canonical : canonical + '/';
}

function connectionAlias(id: string): string {
  return id === LEGACY_ID ? LEGACY_ALIAS : CONNECTION_PREFIX + id;
}

async function connection(id: string): Promise<WebDavConnection | undefined> {
  const raw = await vault.readOptional(connectionAlias(id));
  return raw === undefined ? undefined : JSON.parse(raw) as WebDavConnection;
}

async function store(id: string, saved: WebDavConnection, replace: boolean): Promise<void> {
  const raw = JSON.stringify(saved);
  if (new util.TextEncoder().encodeInto(raw).length > 1024) { throw new Error(t('WebDAV 连接设置超出安全存储限制。')); }
  if (replace) { await vault.update(connectionAlias(id), raw); }
  else { await vault.write(connectionAlias(id), raw, CONNECTION_GROUP); }
}

export async function requireWebDavConnection(id: string): Promise<WebDavConnection> {
  const saved = await connection(id);
  if (!saved) { throw new Error(t('请先保存 WebDAV 连接设置。')); }
  saved.directory = directoryUrl(saved.directory);
  return saved;
}

export function webDavSession(saved: WebDavConnection): rcp.Session {
  const credentials = new util.TextEncoder().encodeInto(saved.username + ':' + saved.password);
  return rcp.createSession({
    headers: { authorization: 'Basic ' + new util.Base64Helper().encodeToStringSync(credentials) },
    requestConfiguration: {
      security: { remoteValidation: 'system' },
      transfer: { autoRedirect: false, timeout: { connectMs: 15000, transferMs: 600000 } }
    }
  });
}

function settingsFor(id: string, saved: WebDavConnection): WebDavSettings {
  return { id: id, name: saved.name || t('默认 WebDAV'), directory: saved.directory, username: saved.username, grantId: saved.id };
}

export function webDavSettings(): Promise<WebDavSettings[]> {
  return withFileMutation(CONNECTION_GROUP, async (): Promise<WebDavSettings[]> => {
    const settings: WebDavSettings[] = [];
    const legacy = await connection(LEGACY_ID);
    if (legacy) { settings.push(settingsFor(LEGACY_ID, legacy)); }
    for (const alias of await vault.listAliases(CONNECTION_GROUP)) {
      const id = alias.slice(CONNECTION_PREFIX.length);
      const saved = await connection(id);
      if (saved) { settings.push(settingsFor(id, saved)); }
    }
    return settings;
  });
}

function newGrantId(id: string): string { return id + '_' + util.generateRandomUUID(); }

export async function saveWebDavConnection(id: string, name: string, directory: string, username: string, password: string): Promise<WebDavSettings> {
  const label = name.trim();
  if (!label || label.length > 64 || /[\u0000-\u001f\u007f]/.test(label)) {
    throw new Error(t('WebDAV 连接名称需要 1 至 64 个字符。'));
  }
  const address = directoryUrl(directory);
  const user = username.trim();
  if (!user || /[:\u0000-\u001f\u007f]/.test(user) || /[\u0000-\u001f\u007f]/.test(password)) {
    throw new Error(t('请输入有效的 WebDAV 账号和密码。'));
  }
  return withFileMutation(CONNECTION_GROUP, async (): Promise<WebDavSettings> => {
    const previous = id ? await requireWebDavConnection(id) : undefined;
    const same = previous?.directory === address && previous.username === user;
    const secret = password || (same ? previous?.password || '' : '');
    if (!secret) { throw new Error(t('新增连接或修改地址、账号时，请填写 WebDAV 密码。')); }
    const key = id || util.generateRandomUUID();
    const grant = same && previous?.id ? previous.id : newGrantId(key);
    const saved: WebDavConnection = { name: label, directory: address, username: user, password: secret, id: grant };
    await store(key, saved, previous !== undefined);
    return settingsFor(key, saved);
  });
}

export function clearWebDavConnection(id: string): Promise<void> {
  return withFileMutation(CONNECTION_GROUP, () => vault.remove(connectionAlias(id)));
}

export interface WebDavShareRoot {
  id: string;
  directory: string;
}

export function webDavShareRoot(id: string): Promise<WebDavShareRoot> {
  return withFileMutation(CONNECTION_GROUP, async (): Promise<WebDavShareRoot> => {
    const saved = await requireWebDavConnection(id);
    if (!saved.id) { saved.id = newGrantId(id); await store(id, saved, true); }
    return { id: saved.id, directory: saved.directory };
  });
}

async function checkedShare(id: string, directory: string): Promise<WebDavConnection> {
  // Existing projects stored a single UUID before multiple connections were supported.
  const separator = id.indexOf('_');
  const saved = await connection(separator < 0 ? LEGACY_ID : id.slice(0, separator));
  if (!saved || saved.id !== id || directoryUrl(directory) !== directory || !directory.startsWith(directoryUrl(saved.directory))) {
    throw new ToolFailure('SHARED_FOLDER_AUTH_REQUIRED', t('WebDAV 连接已变更，请在项目设置中重新添加云端文件夹。'), 'reselect_shared_folder');
  }
  return saved;
}

export async function withWebDavShare<T>(id: string, directory: string,
  action: (session: rcp.Session, verify: () => Promise<void>) => Promise<T>): Promise<T> {
  const session = webDavSession(await checkedShare(id, directory));
  try { return await action(session, async () => { await checkedShare(id, directory); }); }
  finally { session.close(); }
}
