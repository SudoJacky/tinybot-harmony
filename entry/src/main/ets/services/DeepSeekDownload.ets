import { url, util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { rcp } from '@kit.RemoteCommunicationKit';
import { Diagnostics } from '../model/Diagnostics';
import { t } from '../model/I18n';

export const DEEPSEEK_LINK_LIMIT: number = 8192;
const MAX_BYTES: number = 512 * 1024 * 1024;
const TRANSFER_TIMEOUT: number = 300000;

function checkedLink(input: string, base?: string): string {
  const invalid = new Error(t('请粘贴有效的 HTTPS 下载链接。'));
  if (!input || input.length > DEEPSEEK_LINK_LIMIT || /[\s\\\u0000-\u001f\u007f]/.test(input) ||
    (!base && !/^https:\/\//i.test(input))) { throw invalid; }
  let parsed: url.URL;
  try { parsed = base ? url.URL.parseURL(input, base) : url.URL.parseURL(input); }
  catch (_) { throw invalid; }
  const host = parsed.hostname;
  if (parsed.protocol !== 'https:' || parsed.username || parsed.password ||
    !/^[a-z0-9-]+(?:\.[a-z0-9-]+)+$/i.test(host) || /^[\d.]+$/.test(host) ||
    /\.(localhost|local|internal|test|arpa)$/i.test(host)) { throw invalid; }
  // Keep the original spelling and query for signed absolute URLs.
  const address = (/^https:\/\//i.test(input) ? input : parsed.toString()).split('#')[0];
  if (address.length > DEEPSEEK_LINK_LIMIT || /^https:\/\/[^/?#]*@/i.test(address)) { throw invalid; }
  return address;
}

function responseHeader(headers: rcp.ResponseHeaders, name: string): string {
  const key = Object.keys(headers).find(item => item.toLowerCase() === name);
  const value = key ? headers[key] : undefined;
  return typeof value === 'string' ? value : Array.isArray(value) && value.length === 1 ? value[0] : '';
}

function tooLarge(): Error { return new Error(t('下载的 DeepSeek ZIP 超过 512 MB。')); }
function downloadError(): Error { return new Error(t('无法下载 DeepSeek 导出包，请检查网络后重试。')); }
function reportTransferError(error: Error): void {
  // Native error text can include the signed download URL.
  Diagnostics.log('warn', 'backup', 'deepseek_download_failed', { code: (error as BusinessError).code || -1 });
}

async function downloadHop(address: string, destination: string, timeout: number): Promise<rcp.Response> {
  let session: rcp.Session | undefined;
  let overLimit = false;
  const enforceLimit = (bytes: number): void => {
    if (!overLimit && bytes > MAX_BYTES) { overLimit = true; session?.cancel(); }
  };
  try {
    session = rcp.createSession({ headers: { Accept: 'application/zip, application/octet-stream, */*' }, requestConfiguration: {
      security: { remoteValidation: 'system' },
      transfer: { autoRedirect: false, timeout: { connectMs: Math.min(10000, timeout), transferMs: timeout } },
      tracing: { httpEventsHandler: {
        onHeaderReceive: (headers: rcp.ResponseHeaders) => enforceLimit(Number(responseHeader(headers, 'content-length'))),
        onDownloadProgress: (total: number, received: number) => enforceLimit(Math.max(total, received))
      } }
    } });
    const response = await session.downloadToFile(address, { kind: 'file', file: destination });
    if (overLimit) { throw tooLarge(); }
    return response;
  } catch (error) {
    if (overLimit) { throw tooLarge(); }
    reportTransferError(error as Error);
    throw downloadError();
  } finally {
    try { session?.close(); }
    catch (error) { reportTransferError(error as Error); }
  }
}

export async function withDeepSeekDownload<T>(cacheDir: string, link: string, use: (path: string) => Promise<T>): Promise<T> {
  let address = checkedLink(link.trim());
  const visited = new Set<string>();
  const deadline = Date.now() + TRANSFER_TIMEOUT;
  const destination = cacheDir + '/deepseek-' + util.generateRandomUUID() + '.zip';
  try {
    for (let hop = 0; hop <= 5; hop++) {
      const timeout = deadline - Date.now();
      if (timeout <= 0) { throw downloadError(); }
      if (visited.has(address)) { break; }
      visited.add(address);
      const response = await downloadHop(address, destination, timeout);
      const status = response.statusCode;
      if ([301, 302, 303, 307, 308].includes(status)) {
        const location = responseHeader(response.headers, 'location').trim();
        if (!location) { break; }
        address = checkedLink(location, address);
        if (await fs.access(destination)) { await fs.unlink(destination); }
        continue;
      }
      if ([401, 403, 404, 410].includes(status)) {
        throw new Error(t('下载链接可能已过期或失效，请从 DeepSeek 重新获取导出链接。'));
      }
      if (status !== 200) { throw new Error(t('DeepSeek 导出包下载失败（HTTP {0}）。', [status])); }
      if (/^(?:text\/html|application\/xhtml\+xml)\b/i.test(responseHeader(response.headers, 'content-type').trim())) {
        throw new Error(t('链接打开的是网页，请粘贴 DeepSeek 导出包的直接下载链接。'));
      }
      if ((await fs.stat(destination)).size > MAX_BYTES) { throw tooLarge(); }
      return await use(destination);
    }
    throw new Error(t('下载链接重定向异常，请重新复制 DeepSeek 导出包链接。'));
  } finally {
    try { if (await fs.access(destination)) { await fs.unlink(destination); } }
    catch (error) { Diagnostics.log('warn', 'backup', 'deepseek_download_cleanup_failed', undefined, error as Error); }
  }
}
