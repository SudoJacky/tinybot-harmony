import { url, util, xml } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { rcp } from '@kit.RemoteCommunicationKit';
import { t } from '../model/I18n';
import { SharedFolder } from '../model/SharedFolders';
import { ToolFailure, toolHttpFailure } from '../model/ToolFailure';
import { applyTextEdits, TextEdit } from '../model/WorkspaceEdit';
import { Cancellation } from './Cancellation';
import { isDocumentPath, readDocumentFile } from './DocumentFiles';
import { withFileMutation } from './FileMutationQueue';
import { readUtf8File } from './TextFiles';
import { withWebDavShare } from './WebDavConnection';
import { WorkspaceEntry, WorkspaceListing, WorkspaceText, WorkspaceWrite } from './WorkspaceFiles';

const DIRECTORY_QUERY = '<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>';

interface Resource {
  href: string;
  directory?: boolean;
}

export interface WebDavDirectoryEntry {
  name: string;
  uri: string;
  kind: string;
}

export interface WebDavMount {
  folder: SharedFolder;
  relative: string;
}

function resources(body?: ArrayBuffer): Resource[] {
  const result: Resource[] = [];
  if (!body?.byteLength) { throw new Error(t('无法读取 WebDAV 文件夹信息。请检查目录地址。')); }
  let entry: Resource | undefined;
  let type: boolean | undefined;
  let href = '';
  let status = '';
  let field = '';
  let document = false;
  try {
    new xml.XmlPullParser(body, 'UTF-8').parseXml({
      tokenValueCallbackFunction: (event: xml.EventType, info: xml.ParseInfo): boolean => {
        if (event === xml.EventType.TEXT || event === xml.EventType.CDSECT) {
          if (field === 'href') { href += info.getText(); }
          if (field === 'status') { status += info.getText(); }
          return true;
        }
        if (event !== xml.EventType.START_TAG && event !== xml.EventType.END_TAG) { return true; }
        if (info.getNamespace() !== 'DAV:') { return true; }
        const depth = info.getDepth();
        const name = info.getName();
        if (event === xml.EventType.START_TAG) {
          if (depth === 1 && name === 'multistatus') { document = true; }
          if (document && depth === 2 && name === 'response') { entry = { href: '' }; }
          if (entry && depth === 3 && name === 'href') { field = name; href = ''; }
          if (entry && depth === 3 && name === 'propstat') { type = undefined; status = ''; }
          if (entry && depth === 4 && name === 'status') { field = name; }
          if (entry && depth === 5 && name === 'resourcetype') { type = false; }
          if (entry && depth === 6 && name === 'collection' && type === false) { type = true; }
        }
        if (event === xml.EventType.END_TAG && entry) {
          if (depth === 3 && name === 'href') { entry.href = href.trim(); field = ''; }
          if (depth === 4 && name === 'status') { field = ''; }
          if (depth === 3 && name === 'propstat' && /^HTTP\/\S+ 2\d\d(?:\s|$)/.test(status.trim()) && type !== undefined) {
            entry.directory = type;
          }
          if (depth === 2 && name === 'response') { result.push(entry); entry = undefined; }
        }
        return true;
      }
    });
  } catch (_) {
    throw new Error(t('无法读取 WebDAV 文件夹信息。请检查目录地址。'));
  }
  if (!document) { throw new Error(t('无法读取 WebDAV 文件夹信息。请检查目录地址。')); }
  return result;
}

function safeName(value: string): boolean {
  return !!value && value !== '.' && value !== '..' && !value.startsWith('.tinybot-') &&
    !/[/\\:\u0000-\u001f\u007f]|%[0-9a-f]{2}/i.test(value);
}

function resourcePath(parent: url.URL, href: string): string | undefined {
  if (!href) { return undefined; }
  try {
    const target = url.URL.parseURL(href, parent.toString());
    if (target.origin !== parent.origin || target.username || target.password || target.search || target.hash) { return undefined; }
    return decodeURIComponent(target.pathname);
  } catch (_) { return undefined; }
}

function remoteUrl(mount: WebDavMount): string {
  const parts = mount.relative ? mount.relative.split('/') : [];
  if (!parts.every(safeName)) {
    throw new ToolFailure('FS_INVALID_PATH', t('云端共享文件的路径无效。'), 'fix_path');
  }
  return mount.folder.uri + parts.map((part) => encodeURIComponent(part)).join('/');
}

async function request(session: rcp.Session, operation: () => Promise<rcp.Response>, cancellation: Cancellation,
  expected: number[]): Promise<rcp.Response> {
  cancellation.check();
  const stop = cancellation.onCancel(() => session.cancel());
  let response: rcp.Response;
  try { response = await operation(); }
  catch (error) {
    cancellation.check();
    throw new ToolFailure('NETWORK_ERROR', t('WebDAV 文件请求失败，请检查连接。'), 'inspect_service',
      { service: 'webdav', nativeCode: (error as BusinessError).code });
  } finally { stop(); }
  if (expected.includes(response.statusCode)) { return response; }
  throw toolHttpFailure(response.statusCode, t('WebDAV 文件请求失败（HTTP {0}）。', [response.statusCode]), 'webdav');
}

export async function listWebDavDirectory(id: string, directory: string, cancellation: Cancellation): Promise<WebDavDirectoryEntry[]> {
  return withWebDavShare(id, directory, async (session) => {
    const response = await request(session, () => session.fetch(new rcp.Request(directory, 'PROPFIND',
      { Depth: '1', 'content-type': 'application/xml; charset=utf-8' }, DIRECTORY_QUERY)), cancellation, [207]);
    return parseWebDavDirectory(response.body, directory, cancellation);
  });
}

export function parseWebDavDirectory(body: ArrayBuffer | undefined, directory: string, cancellation: Cancellation): WebDavDirectoryEntry[] {
    const parent = url.URL.parseURL(directory);
    const parentPath = decodeURIComponent(parent.pathname);
    let listed = false;
    const entries = new Map<string, WebDavDirectoryEntry>();
    for (const item of resources(body)) {
      cancellation.check();
      if (item.directory === undefined) { continue; }
      const path = resourcePath(parent, item.href);
      if (item.directory && (path === parentPath || path + '/' === parentPath)) { listed = true; continue; }
      if (!path?.startsWith(parentPath)) { continue; }
      const name = path.slice(parentPath.length).replace(/\/$/, '');
      if (safeName(name)) {
        entries.set(name, { name: name, uri: directory + encodeURIComponent(name) + (item.directory ? '/' : ''),
          kind: item.directory ? 'directory' : 'file' });
      }
    }
    if (!listed) { throw new Error(t('无法读取 WebDAV 文件夹信息。请检查目录地址。')); }
    return Array.from(entries.values()).sort((a, b) => a.name.localeCompare(b.name));
}

function strongEtag(headers: rcp.ResponseHeaders): string {
  const key = Object.keys(headers).find((name) => name.toLowerCase() === 'etag');
  const header = key ? headers[key] : undefined;
  const value = typeof header === 'string' ? header : header?.[0];
  return value && /^"[\x21\x23-\x7e\x80-\xff]*"$/.test(value) ? value : '';
}

export class WebDavWorkspaceFiles {
  private root: string;
  constructor(root: string) { this.root = root; }

  async list(mount: WebDavMount, path: string, cancellation: Cancellation, offset: number): Promise<WorkspaceListing> {
    const address = remoteUrl(mount);
    const entries = await listWebDavDirectory(mount.folder.webDavConnectionId as string,
      address.endsWith('/') ? address : address + '/', cancellation);
    const more = entries.length > offset + 200;
    return { path: path, entries: entries.slice(offset, offset + 200).map((entry): WorkspaceEntry => ({ name: entry.name, kind: entry.kind })),
      truncated: more, nextOffset: more ? offset + 200 : undefined };
  }

  read(mount: WebDavMount, path: string, cancellation: Cancellation, maximumTextBytes?: number): Promise<WorkspaceText> {
    return withWebDavShare(mount.folder.webDavConnectionId as string, mount.folder.uri,
      (session) => this.readFile(session, remoteUrl(mount), path, cancellation, maximumTextBytes));
  }

  private async readFile(session: rcp.Session, address: string, path: string, cancellation: Cancellation,
    maximumTextBytes?: number): Promise<WorkspaceText> {
    if (address.endsWith('/')) { throw new Error(t('请选择共享文件夹中的文件。')); }
    if (maximumTextBytes !== undefined && isDocumentPath(path)) {
      throw new ToolFailure('INVALID_ARGUMENTS', t('请用 read_file 读取云端文档的提取文本。'), 'fix_arguments');
    }
    const temporary = this.root + '/.tinybot-webdav-' + util.generateRandomUUID();
    try {
      const response = await request(session, () => session.downloadToFile(address, { kind: 'file', file: temporary }), cancellation, [200]);
      cancellation.check();
      const file = await fs.open(temporary, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
      try {
        const content = maximumTextBytes === undefined ? await readDocumentFile(file.fd, path, this.root, cancellation) :
          await readUtf8File(file.fd, cancellation, maximumTextBytes);
        return { path: path, content: content, version: strongEtag(response.headers) };
      } finally { await fs.close(file); }
    } finally { if (await fs.access(temporary)) { await fs.unlink(temporary); } }
  }

  async write(mount: WebDavMount, path: string, content: string, edits: TextEdit[],
    expected: string | null | undefined, cancellation: Cancellation, checkGrant: () => void): Promise<WorkspaceWrite> {
    if (expected === undefined) {
      throw new ToolFailure('FS_NOT_OBSERVED', t('覆盖已有文件前，请先用 read_file 读取。'), 'read_file', { path: path });
    }
    if (expected !== null && !expected) {
      throw new ToolFailure('READ_ONLY', t('WebDAV 服务器未提供可安全覆盖文件的版本标识。'), 'choose_another_path', { path: path });
    }
    const address = remoteUrl(mount);
    if (!mount.relative) { throw new Error(t('请选择共享文件夹中的文件。')); }
    return withFileMutation(address, () => withWebDavShare(mount.folder.webDavConnectionId as string, mount.folder.uri,
      async (session, verify): Promise<WorkspaceWrite> => {
        checkGrant();
        let before = '';
        if (expected !== null) {
          const original = await this.readFile(session, address, path, cancellation);
          if (original.version !== expected) { throw this.conflict(path, false); }
          before = original.content;
        }
        const after = edits.length ? applyTextEdits(before, edits) : content;
        if (after.includes('\u0000')) { throw new Error(t('文本不能包含空字符。')); }
        if (expected === null) {
          let parent = mount.folder.uri;
          for (const segment of mount.relative.split('/').slice(0, -1)) {
            await verify();
            checkGrant();
            parent += encodeURIComponent(segment) + '/';
            await request(session, () => session.fetch(new rcp.Request(parent, 'MKCOL')), cancellation, [201, 405]);
          }
        }
        const headers: rcp.RequestHeaders = { 'content-type': 'text/plain; charset=utf-8' };
        if (expected === null) { headers['If-None-Match'] = '*'; }
        else { headers['If-Match'] = expected; }
        await verify();
        checkGrant();
        const result = await request(session, () => session.fetch(new rcp.Request(address, 'PUT', headers, after)),
          cancellation, [200, 201, 204, 412]);
        if (result.statusCode === 412) { throw this.conflict(path, expected === null); }
        return { path: path, before: before, after: after, created: expected === null, written: true, version: strongEtag(result.headers),
          bytes: after.length ? new util.TextEncoder().encodeInto(after).length : 0 };
      }));
  }

  private conflict(path: string, create: boolean): ToolFailure {
    return new ToolFailure(create ? 'FS_NOT_OBSERVED' : 'FS_STALE_VERSION',
      create ? t('覆盖已有文件前，请先用 read_file 读取。') : t('文件自上次读取后已变化，请重新读取再修改。'), 'read_file', { path: path });
  }
}
