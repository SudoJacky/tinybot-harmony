import { common } from '@kit.AbilityKit';
import { url, util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { rcp } from '@kit.RemoteCommunicationKit';
import { AppData } from '../model/Conversation';
import { Diagnostics } from '../model/Diagnostics';
import { t } from '../model/I18n';
import { createBackupFile, readBackupFile, withBackupOperation } from './Backup';
import { CredentialStore } from './CredentialStore';
import { withFileMutation } from './FileMutationQueue';
import { huaweiAccount } from './HuaweiAccount';

export interface WebDavSettings {
  directory: string;
  username: string;
}

interface WebDavConnection extends WebDavSettings {
  password: string;
}

const CONNECTION_ALIAS = 'tinybot.webdav.backup.v1';
const SNAPSHOT_NAME = 'tinybot-latest.tinybot';
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

async function connection(): Promise<WebDavConnection | undefined> {
  const raw = await vault.readOptional(CONNECTION_ALIAS);
  return raw === undefined ? undefined : JSON.parse(raw) as WebDavConnection;
}

async function requireConnection(): Promise<WebDavConnection> {
  const saved = await connection();
  if (!saved) { throw new Error(t('请先保存 WebDAV 连接设置。')); }
  return saved;
}

function sessionFor(saved: WebDavConnection): rcp.Session {
  const credentials = new util.TextEncoder().encodeInto(saved.username + ':' + saved.password);
  return rcp.createSession({
    headers: { authorization: 'Basic ' + new util.Base64Helper().encodeToStringSync(credentials) },
    requestConfiguration: {
      security: { remoteValidation: 'system' },
      transfer: { autoRedirect: false, timeout: { connectMs: 15000, transferMs: 600000 } }
    }
  });
}

async function send(method: string, request: () => Promise<rcp.Response>, expected: number[]): Promise<void> {
  let response: rcp.Response;
  try { response = await request(); }
  catch (error) {
    const code = (error as BusinessError).code;
    Diagnostics.log('warn', 'backup', 'webdav_failed', { operation: method, code: code });
    throw new Error(t('WebDAV 请求 {0} 失败（网络错误 {1}）。', [method, code ?? 0]));
  }
  const status = response.statusCode;
  if (expected.includes(status)) { return; }
  Diagnostics.log('warn', 'backup', 'webdav_failed', { operation: method, http: status });
  if (status === 401) { throw new Error(t('WebDAV 账号或密码验证失败（HTTP 401）。')); }
  if (status === 403) { throw new Error(t('WebDAV 账号没有执行此操作的权限（HTTP 403）。')); }
  if (method === 'GET' && status === 404) { throw new Error(t('WebDAV 目录中没有可恢复的备份（HTTP 404）。')); }
  if (status >= 300 && status < 400) { throw new Error(t('WebDAV 服务器返回重定向，请填写最终 HTTPS 目录地址（HTTP {0}）。', [status])); }
  throw new Error(t('WebDAV 请求 {0} 失败（HTTP {1}）。', [method, status]));
}

async function cleanLocal(path: string): Promise<void> {
  try { if (await fs.access(path)) { await fs.unlink(path); } }
  catch (error) { Diagnostics.log('warn', 'backup', 'webdav_cleanup_failed', { operation: 'local' }, error as Error); }
}

export class WebDavBackup {
  static async settings(): Promise<WebDavSettings | undefined> {
    const saved = await connection();
    return saved ? { directory: saved.directory, username: saved.username } : undefined;
  }

  static async save(directory: string, username: string, password: string): Promise<void> {
    const address = directoryUrl(directory);
    const user = username.trim();
    if (!user || /[:\u0000-\u001f\u007f]/.test(user) || /[\u0000-\u001f\u007f]/.test(password)) {
      throw new Error(t('请输入有效的 WebDAV 账号和密码。'));
    }
    await withFileMutation(CONNECTION_ALIAS, async () => {
      const previous = await connection();
      const secret = password || (previous?.directory === address && previous.username === user ? previous.password : '');
      if (!secret) { throw new Error(t('新增连接或修改地址、账号时，请填写 WebDAV 密码。')); }
      const settings: WebDavConnection = { directory: address, username: user, password: secret };
      const raw = JSON.stringify(settings);
      if (new util.TextEncoder().encodeInto(raw).length > 1024) {
        throw new Error(t('WebDAV 连接设置超出安全存储限制。'));
      }
      if (previous) { await vault.update(CONNECTION_ALIAS, raw); }
      else { await vault.write(CONNECTION_ALIAS, raw); }
    });
  }

  static clear(): Promise<void> {
    return withFileMutation(CONNECTION_ALIAS, () => vault.remove(CONNECTION_ALIAS));
  }

  static create(context: common.UIAbilityContext, data: AppData): Promise<void> {
    return withBackupOperation(async () => {
      const openID = await huaweiAccount.backupOpenID(context);
      const saved = await requireConnection();
      const source = await createBackupFile(context, data, undefined, openID);
      try {
        const session = sessionFor(saved);
        const temporary = saved.directory + 'tinybot-' + util.generateRandomUUID() + '.partial';
        try {
          await send('PUT', () => session.fetch(new rcp.Request(temporary, 'PUT',
            { 'content-type': 'application/octet-stream' }, new rcp.UploadFromFile(source))), [200, 201, 204]);
          await send('MOVE', () => session.fetch(new rcp.Request(temporary, 'MOVE',
            { Destination: saved.directory + SNAPSHOT_NAME, Overwrite: 'T' })), [201, 204]);
        } catch (error) {
          try { await send('DELETE', () => session.fetch(new rcp.Request(temporary, 'DELETE')), [200, 204, 404]); }
          catch (cleanup) { Diagnostics.log('warn', 'backup', 'webdav_cleanup_failed', { operation: 'remote' }, cleanup as Error); }
          throw error as Error;
        } finally { session.close(); }
      } finally { await cleanLocal(source); }
      Diagnostics.log('info', 'backup', 'webdav_uploaded');
    });
  }

  static restore(context: common.UIAbilityContext, local: AppData): Promise<AppData> {
    return withBackupOperation(async () => {
      const openID = await huaweiAccount.backupOpenID(context);
      const saved = await requireConnection();
      const temporary = context.cacheDir + '/webdav-' + util.generateRandomUUID() + '.tinybot';
      try {
        const session = sessionFor(saved);
        try {
          await send('GET', () => session.downloadToFile(saved.directory + SNAPSHOT_NAME,
            { kind: 'file', file: temporary }), [200]);
        } finally { session.close(); }
        return await readBackupFile(context, temporary, local, openID);
      } finally { await cleanLocal(temporary); }
    });
  }
}
