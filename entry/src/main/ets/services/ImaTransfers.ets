import { url, util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { rcp } from '@kit.RemoteCommunicationKit';
import { t } from '../model/I18n';
import { ToolFailure, toolHttpFailure } from '../model/ToolFailure';
import { Cancellation } from './Cancellation';
import { NetworkTransfers } from './NetworkTransfers';

const MIB: number = 1024 * 1024;
export const IMA_FILE_LIMIT: number = 200 * MIB;

export interface ImaFileType { extension: string; media: number; mime: string; maximum: number; }
const FILE_TYPES: ImaFileType[] = [
  { extension: 'pdf', media: 1, mime: 'application/pdf', maximum: IMA_FILE_LIMIT },
  { extension: 'doc', media: 3, mime: 'application/msword', maximum: IMA_FILE_LIMIT },
  { extension: 'docx', media: 3, mime: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', maximum: IMA_FILE_LIMIT },
  { extension: 'ppt', media: 4, mime: 'application/vnd.ms-powerpoint', maximum: IMA_FILE_LIMIT },
  { extension: 'pptx', media: 4, mime: 'application/vnd.openxmlformats-officedocument.presentationml.presentation', maximum: IMA_FILE_LIMIT },
  { extension: 'xls', media: 5, mime: 'application/vnd.ms-excel', maximum: 10 * MIB },
  { extension: 'xlsx', media: 5, mime: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', maximum: 10 * MIB },
  { extension: 'csv', media: 5, mime: 'text/csv', maximum: 10 * MIB },
  { extension: 'md', media: 7, mime: 'text/markdown', maximum: 10 * MIB },
  { extension: 'markdown', media: 7, mime: 'text/markdown', maximum: 10 * MIB },
  { extension: 'png', media: 9, mime: 'image/png', maximum: 30 * MIB },
  { extension: 'jpg', media: 9, mime: 'image/jpeg', maximum: 30 * MIB },
  { extension: 'jpeg', media: 9, mime: 'image/jpeg', maximum: 30 * MIB },
  { extension: 'webp', media: 9, mime: 'image/webp', maximum: 30 * MIB },
  { extension: 'txt', media: 13, mime: 'text/plain', maximum: 10 * MIB },
  { extension: 'xmind', media: 14, mime: 'application/x-xmind', maximum: 10 * MIB },
  { extension: 'mp3', media: 15, mime: 'audio/mpeg', maximum: IMA_FILE_LIMIT },
  { extension: 'm4a', media: 15, mime: 'audio/x-m4a', maximum: IMA_FILE_LIMIT },
  { extension: 'wav', media: 15, mime: 'audio/wav', maximum: IMA_FILE_LIMIT },
  { extension: 'aac', media: 15, mime: 'audio/aac', maximum: IMA_FILE_LIMIT },
  { extension: 'html', media: 20, mime: 'text/html', maximum: 10 * MIB },
  { extension: 'htm', media: 20, mime: 'text/html', maximum: 10 * MIB },
  { extension: 'epub', media: 21, mime: 'application/epub+zip', maximum: 50 * MIB }
];

export interface ImaUploadGrant {
  token: string;
  secret_id: string;
  secret_key: string;
  start_time: number;
  expired_time: number;
  bucket_name: string;
  region: string;
  cos_key: string;
}

export interface ImaMediaLink { url: string; headers?: Record<string, string>; }

export function imaFileType(extension: string): ImaFileType {
  const type = FILE_TYPES.find(item => item.extension === extension);
  if (!type) { throw new ToolFailure('INVALID_ARGUMENTS', t('腾讯 ima 不支持上传此文件类型。'), 'choose_another_path'); }
  return type;
}

export function imaWebUrl(value: string): url.URL {
  const invalid = new ToolFailure('INVALID_ARGUMENTS', t('腾讯 ima 要求使用有效的 HTTP 或 HTTPS 网页地址。'), 'fix_arguments');
  let parsed: url.URL;
  try { parsed = url.URL.parseURL(value); } catch (_) { throw invalid; }
  if (!/^https?:\/\//i.test(value) || !parsed.hostname || parsed.username || parsed.password || /[\s\\\u0000-\u001f]/.test(value)) { throw invalid; }
  return parsed;
}

function responseHeaders(link: ImaMediaLink): Record<string, string> {
  const parsed = imaWebUrl(link.url);
  if (parsed.protocol !== 'https:' || !/^[a-z0-9-]+(?:\.[a-z0-9-]+)+$/i.test(parsed.hostname) ||
    /^[\d.]+$/.test(parsed.hostname) || /\.(local|localhost|internal)$/i.test(parsed.hostname)) {
    throw new ToolFailure('PERMISSION_DENIED', t('腾讯 ima 未提供可安全访问的原文地址。'), 'check_permissions');
  }
  const headers: Record<string, string> = {};
  if (link.headers === undefined) { return headers; }
  if (!link.headers || typeof link.headers !== 'object' || Array.isArray(link.headers)) {
    throw new ToolFailure('INVALID_RESPONSE', t('腾讯 ima 返回了无效响应。'), 'inspect_service');
  }
  for (const key of Object.keys(link.headers)) {
    const lower = key.toLowerCase();
    const value = link.headers?.[key];
    if (!/^[a-z0-9-]+$/i.test(key) || typeof value !== 'string' || /[\r\n]/.test(value) ||
      lower.startsWith('ima-openapi-') || ['host', 'connection', 'content-length', 'transfer-encoding', 'proxy-authorization'].includes(lower)) {
      throw new ToolFailure('INVALID_RESPONSE', t('腾讯 ima 返回了无效响应。'), 'inspect_service');
    }
    headers[key] = value;
  }
  return headers;
}

function hex(bytes: Uint8Array): string {
  let result = '';
  for (const byte of bytes) { result += byte.toString(16).padStart(2, '0'); }
  return result;
}

async function hmac(secret: string, value: string): Promise<string> {
  const encoder = new util.TextEncoder();
  const generator = cryptoFramework.createSymKeyGenerator('HMAC');
  const key = await generator.convertKey({ data: encoder.encodeInto(secret) });
  const mac = cryptoFramework.createMac('SHA1');
  await mac.init(key);
  await mac.update({ data: encoder.encodeInto(value) });
  return hex((await mac.doFinal()).data);
}

async function signedUpload(grant: ImaUploadGrant, host: string, pathname: string, size: number): Promise<string> {
  const keyTime = grant.start_time + ';' + grant.expired_time;
  const signingKey = await hmac(grant.secret_key, keyTime);
  const digest = cryptoFramework.createMd('SHA1');
  await digest.update({ data: new util.TextEncoder().encodeInto('put\n' + pathname + '\n\ncontent-length=' + size + '&host=' + host + '\n') });
  const signature = await hmac(signingKey, 'sha1\n' + keyTime + '\n' + hex((await digest.digest()).data) + '\n');
  return 'q-sign-algorithm=sha1&q-ak=' + grant.secret_id + '&q-sign-time=' + keyTime + '&q-key-time=' + keyTime +
    '&q-header-list=content-length;host&q-url-param-list=&q-signature=' + signature;
}

async function exchange(headers: Record<string, string>, maximum: number, cancellation: Cancellation,
  checkAccess: () => void, perform: (session: rcp.Session) => Promise<rcp.Response>): Promise<rcp.Response> {
  const end = await NetworkTransfers.begin(cancellation);
  let session: rcp.Session | undefined;
  let off = (): void => {};
  let limitReached = false;
  const oversized = new ToolFailure('LIMIT_EXCEEDED', t('响应超过大小上限。'), 'choose_another_path');
  try {
    checkAccess();
    const active = rcp.createSession({ headers: headers, requestConfiguration: {
      security: { remoteValidation: 'system' },
      transfer: { autoRedirect: false, timeout: { connectMs: 10000, transferMs: 300000 } },
      tracing: { httpEventsHandler: { onDownloadProgress: (total: number, bytes: number) => {
        if (!limitReached && (total > maximum || bytes > maximum)) { limitReached = true; session?.cancel(); }
      } } }
    } });
    session = active;
    off = cancellation.onCancel(() => active.cancel());
    cancellation.check();
    let response: rcp.Response;
    try { response = await perform(active); }
    catch (error) {
      cancellation.check();
      if (limitReached) { throw oversized; }
      throw new ToolFailure('NETWORK_ERROR', t('腾讯 ima 文件传输失败。'), 'check_connection',
        { service: 'ima', nativeCode: (error as BusinessError).code });
    }
    checkAccess();
    if (limitReached) { throw oversized; }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw toolHttpFailure(response.statusCode, t('腾讯 ima 请求失败（HTTP {0}）。', [response.statusCode]), 'ima');
    }
    return response;
  } finally {
    off();
    try { session?.close(); } finally { await end(); }
  }
}

export class ImaTransfers {
  async upload(grant: ImaUploadGrant, fd: number, size: number, mime: string, cancellation: Cancellation,
    checkAccess: () => void): Promise<void> {
    if (!grant || typeof grant.bucket_name !== 'string' || typeof grant.region !== 'string' ||
      !/^[a-z0-9][a-z0-9-]*$/i.test(grant.bucket_name) || !/^[a-z0-9][a-z0-9-]*$/i.test(grant.region) ||
      typeof grant.cos_key !== 'string' || !grant.cos_key || grant.cos_key.split('/').some(part => !part || part === '.' || part === '..') ||
      typeof grant.token !== 'string' || typeof grant.secret_id !== 'string' || typeof grant.secret_key !== 'string' ||
      !/^[!-~]+$/.test(grant.token) || !/^[a-z0-9_-]+$/i.test(grant.secret_id) || !grant.secret_key ||
      !Number.isSafeInteger(grant.start_time) || !Number.isSafeInteger(grant.expired_time) || grant.start_time >= grant.expired_time) {
      throw new ToolFailure('INVALID_RESPONSE', t('腾讯 ima 返回了无效响应。'), 'inspect_service');
    }
    const host = grant.bucket_name + '.cos.' + grant.region + '.myqcloud.com';
    const pathname = '/' + grant.cos_key;
    const address = 'https://' + host + pathname.split('/').map(part => encodeURIComponent(part)).join('/');
    const authorization = await signedUpload(grant, host, pathname, size);
    const headers: Record<string, string> = { 'Content-Type': mime, 'Content-Length': String(size),
      'Authorization': authorization, 'x-cos-security-token': grant.token };
    await exchange(headers, 256 * 1024, cancellation, checkAccess, (session) => session.put(address, new rcp.UploadFromFile(fd)));
  }

  async download(link: ImaMediaLink, destination: string, cancellation: Cancellation, checkAccess: () => void): Promise<string> {
    const response = await exchange(responseHeaders(link), IMA_FILE_LIMIT, cancellation, checkAccess,
      (session) => session.downloadToFile(link.url, { kind: 'file', file: destination }));
    if (response.statusCode !== 200 || (await fs.stat(destination)).size > IMA_FILE_LIMIT) {
      throw new ToolFailure('INVALID_RESPONSE', t('腾讯 ima 未返回完整的原文文件。'), 'inspect_service');
    }
    const key = Object.keys(response.headers).find(name => name.toLowerCase() === 'content-type');
    return key ? String(response.headers[key]).split(';')[0].trim().toLowerCase() : '';
  }
}
