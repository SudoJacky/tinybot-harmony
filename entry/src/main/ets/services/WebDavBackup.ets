import { common } from '@kit.AbilityKit';
import { util, xml } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { rcp } from '@kit.RemoteCommunicationKit';
import { AppData } from '../model/Conversation';
import { Diagnostics } from '../model/Diagnostics';
import { t } from '../model/I18n';
import { createBackupFile, readBackupFile, withBackupOperation } from './Backup';
import { requireWebDavConnection, webDavSession } from './WebDavConnection';
import { huaweiAccount } from './HuaweiAccount';

const SNAPSHOT_NAME = 'tinybot-latest.tinybot';
const NUTSTORE_ROOT = 'https://dav.jianguoyun.com/dav/';
const FOLDER_QUERY = '<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>';
async function send(method: string, request: () => Promise<rcp.Response>, expected: number[]): Promise<rcp.Response> {
  let response: rcp.Response;
  try { response = await request(); }
  catch (error) {
    const code = (error as BusinessError).code;
    Diagnostics.log('warn', 'backup', 'webdav_failed', { operation: method, code: code });
    throw new Error(t('WebDAV 请求 {0} 失败（网络错误 {1}）。', [method, code ?? 0]));
  }
  if (expected.includes(response.statusCode)) { return response; }
  return failResponse(method, response.statusCode);
}

function failResponse(method: string, status: number): never {
  Diagnostics.log('warn', 'backup', 'webdav_failed', { operation: method, http: status });
  if (status === 401) { throw new Error(t('WebDAV 账号或密码验证失败（HTTP 401）。')); }
  if (method === 'MKCOL' && [403, 404, 405, 409].includes(status)) {
    throw new Error(t('无法创建 WebDAV 的 Tinybot 文件夹（HTTP {0}）。请在坚果云创建该文件夹，或填写已有的可写目录地址。', [status]));
  }
  if (status === 403) { throw new Error(t('WebDAV 账号没有执行此操作的权限（HTTP 403）。')); }
  if (method === 'GET' && status === 404) { throw new Error(t('WebDAV 目录中没有可恢复的备份（HTTP 404）。')); }
  if (status >= 300 && status < 400) { throw new Error(t('WebDAV 服务器返回重定向，请填写最终 HTTPS 目录地址（HTTP {0}）。', [status])); }
  throw new Error(t('WebDAV 请求 {0} 失败（HTTP {1}）。', [method, status]));
}

async function folderExists(session: rcp.Session, directory: string): Promise<boolean> {
  const result = await send('PROPFIND', () => session.fetch(new rcp.Request(directory, 'PROPFIND',
    { Depth: '0', 'content-type': 'application/xml; charset=utf-8' }, FOLDER_QUERY)), [207, 404]);
  if (result.statusCode === 404) { return false; }
  let collection = false;
  let typeDepth = -1;
  try {
    if (result.body?.byteLength) {
      new xml.XmlPullParser(result.body, 'UTF-8').parseXml({
        tokenValueCallbackFunction: (event: xml.EventType, info: xml.ParseInfo): boolean => {
          if (event === xml.EventType.START_TAG && info.getNamespace() === 'DAV:') {
            if (info.getName() === 'resourcetype') { typeDepth = info.getDepth(); }
            if (info.getName() === 'collection' && typeDepth >= 0 && info.getDepth() === typeDepth + 1) {
              collection = true;
            }
          }
          if (event === xml.EventType.END_TAG && info.getDepth() === typeDepth) { typeDepth = -1; }
          return true;
        }
      });
    }
  } catch (error) {
    Diagnostics.log('warn', 'backup', 'webdav_failed', { operation: 'PROPFIND', http: 207 }, error as Error);
    throw new Error(t('无法读取 WebDAV 文件夹信息。请检查目录地址。'));
  }
  if (!collection) {
    Diagnostics.log('warn', 'backup', 'webdav_failed', { operation: 'PROPFIND', http: 207 });
    throw new Error(t('WebDAV 备份目标不是文件夹。请填写可写目录地址。'));
  }
  return true;
}

async function backupDirectory(session: rcp.Session, directory: string, create: boolean): Promise<string> {
  if (directory !== NUTSTORE_ROOT) { return directory; }
  const target = directory + 'Tinybot/';
  if (await folderExists(session, target)) { return target; }
  const lowercase = directory + 'tinybot/';
  if (await folderExists(session, lowercase)) { return lowercase; }
  if (!create) { throw new Error(t('WebDAV 目录中没有可恢复的备份（HTTP 404）。')); }
  const created = await send('MKCOL', () => session.fetch(new rcp.Request(target, 'MKCOL')), [201, 405]);
  // A second device can create the folder between the probe and MKCOL.
  if (created.statusCode === 405 && !await folderExists(session, target)) { return failResponse('MKCOL', 405); }
  return target;
}

async function cleanLocal(path: string): Promise<void> {
  try { if (await fs.access(path)) { await fs.unlink(path); } }
  catch (error) { Diagnostics.log('warn', 'backup', 'webdav_cleanup_failed', { operation: 'local' }, error as Error); }
}

async function uploadBackupFile(session: rcp.Session, address: string, source: string): Promise<void> {
  await send('PUT', () => session.fetch(new rcp.Request(address, 'PUT',
    { 'content-type': 'application/octet-stream' }, new rcp.UploadFromFile(source))), [200, 201, 204]);
}

export class WebDavBackup {
  static create(context: common.UIAbilityContext, data: AppData, connectionId: string): Promise<void> {
    return withBackupOperation(async () => {
      const openID = await huaweiAccount.backupOpenID(context);
      const saved = await requireWebDavConnection(connectionId);
      const source = await createBackupFile(context, data, undefined, openID);
      try {
        const session = webDavSession(saved);
        let temporary = '';
        try {
          const directory = await backupDirectory(session, saved.directory, true);
          const destination = directory + SNAPSHOT_NAME;
          if (directory.startsWith(NUTSTORE_ROOT)) {
            // Nutstore accepts PUT over an existing file but returns 409 for MOVE with Overwrite: T.
            await uploadBackupFile(session, destination, source);
          } else {
            temporary = directory + 'tinybot-' + util.generateRandomUUID() + '.partial';
            await uploadBackupFile(session, temporary, source);
            await send('MOVE', () => session.fetch(new rcp.Request(temporary, 'MOVE',
              { Destination: destination, Overwrite: 'T' })), [201, 204]);
          }
        } catch (error) {
          if (temporary) {
            try { await send('DELETE', () => session.fetch(new rcp.Request(temporary, 'DELETE')), [200, 204, 404]); }
            catch (cleanup) { Diagnostics.log('warn', 'backup', 'webdav_cleanup_failed', { operation: 'remote' }, cleanup as Error); }
          }
          throw error as Error;
        } finally { session.close(); }
      } finally { await cleanLocal(source); }
      Diagnostics.log('info', 'backup', 'webdav_uploaded');
    });
  }

  static restore(context: common.UIAbilityContext, local: AppData, connectionId: string): Promise<AppData> {
    return withBackupOperation(async () => {
      const openID = await huaweiAccount.backupOpenID(context);
      const saved = await requireWebDavConnection(connectionId);
      const temporary = context.cacheDir + '/webdav-' + util.generateRandomUUID() + '.tinybot';
      try {
        const session = webDavSession(saved);
        try {
          const directory = await backupDirectory(session, saved.directory, false);
          await send('GET', () => session.downloadToFile(directory + SNAPSHOT_NAME,
            { kind: 'file', file: temporary }), [200]);
        } finally { session.close(); }
        return await readBackupFile(context, temporary, local, openID);
      } finally { await cleanLocal(temporary); }
    });
  }
}
