import { ToolFailure, toolHttpFailure } from '../model/ToolFailure';
import { t } from '../model/I18n';
import { url, util } from '@kit.ArkTS';
import { Cancellation, RunCancelledError } from './Cancellation';
import { NetworkTransfers } from './NetworkTransfers';
import { MAX_WEB_BYTES, WebDocument, WebTransport, validateWebAddress } from './WebTools';
import { CompatHttp, CompatResponse } from './CompatHttp';

function headerValue(headers: Record<string, string>, name: string): string {
  const key = Object.keys(headers).find((item: string) => item.toLowerCase() === name);
  return key ? headers[key] : '';
}

export class NativeWebTransport implements WebTransport {
  resolve(reference: string, base: string): string {
    const parsed = url.URL.parseURL(reference, base);
    parsed.hash = '';
    return validateWebAddress(parsed.toString());
  }

  async get(address: string, cancellation: Cancellation): Promise<WebDocument> {
    let current = this.resolve(address, address);
    const visited = new Set<string>();
    const deadline = Date.now() + 30000;
    for (let redirects = 0; redirects <= 5; redirects++) {
      cancellation.check();
      if (visited.has(current)) { throw new ToolFailure('INVALID_RESPONSE', t("网页重定向形成循环。"), 'inspect_service'); }
      visited.add(current);
      const response = await this.request(current, cancellation, deadline - Date.now());
      if ([301, 302, 303, 307, 308].indexOf(response.status) >= 0) {
        const location = headerValue(response.header, 'location');
        if (location.length === 0) { throw new ToolFailure('INVALID_RESPONSE', t("网页重定向缺少 Location。"), 'inspect_service'); }
        current = this.resolve(location, current);
        continue;
      }
      if (response.status < 200 || response.status >= 300) {
        throw toolHttpFailure(response.status, t("网页返回 HTTP {0}，无法读取；不会绕过登录或验证。", [response.status]), 'web');
      }
      const contentType = headerValue(response.header, 'content-type');
      if (response.bytes.byteLength > MAX_WEB_BYTES) {
        throw new ToolFailure('INVALID_RESPONSE', t("网页响应不是可读取的数据，或超过 1 MiB 上限。"), 'inspect_service');
      }
      let encoding = /charset\s*=\s*["']?([^\s;"']+)/i.exec(contentType)?.[1] || '';
      if (encoding.length === 0 && /html/i.test(contentType)) {
        const prefix = new Uint8Array(response.bytes.slice(0, 2048));
        let ascii = '';
        for (const byte of prefix) { ascii += byte < 128 ? String.fromCharCode(byte) : ' '; }
        encoding = /<meta\b[^>]*charset\s*=\s*["']?([^\s;"'/>]+)/i.exec(ascii)?.[1] || '';
      }
      let body: string;
      try { body = new util.TextDecoder(encoding || 'utf-8', { fatal: true }).decodeToString(new Uint8Array(response.bytes)); }
      catch (_) { throw new ToolFailure('UNSUPPORTED_CONTENT', t("网页文本编码无法解析：") + (encoding || 'utf-8'), 'use_supported_source'); }
      cancellation.check();
      return { url: current, contentType: contentType, body: body };
    }
    throw new ToolFailure('LIMIT_EXCEEDED', t("网页重定向超过 5 次。"), 'reduce_input');
  }

  // One hop at a time: each hop is a fresh request with no model credentials, cookies, or
  // caller-supplied headers. CompatHttp returns the 3xx response instead of following it on
  // every supported system, so the hop validation below is the only redirect logic in play.
  private async request(address: string, cancellation: Cancellation, timeout: number): Promise<CompatResponse> {
    cancellation.check();
    if (timeout <= 0) { throw new ToolFailure('TIMEOUT', t("网页读取超过 30 秒。"), 'check_connection'); }
    const endTransfer = await NetworkTransfers.begin(cancellation);
    try {
      return await new Promise<CompatResponse>((resolve, reject) => {
        let settled = false;
        let timer = -1;
        let unsubscribe = (): void => {};
        let abort = (): void => {};
        const finish = (response?: CompatResponse, error?: Error | ToolFailure | RunCancelledError): void => {
          if (settled) { return; }
          settled = true;
          clearTimeout(timer);
          unsubscribe();
          if (error) { abort(); reject(error); }
          else if (response) { resolve(response); }
          else { abort(); reject(new ToolFailure('INVALID_RESPONSE', t("网页请求没有返回结果。"), 'inspect_service')); }
        };
        timer = setTimeout(() => finish(undefined, new ToolFailure('TIMEOUT', t("网页读取超过 30 秒。"), 'check_connection')), timeout);
        unsubscribe = cancellation.onCancel(() => finish(undefined, new RunCancelledError() as Error));
        if (settled) { return; }
        CompatHttp.request({
          url: address, method: 'GET',
          headers: { 'Accept': 'text/html, text/plain, text/markdown, application/json, application/xhtml+xml',
            'User-Agent': 'Tinybot-Harmony/0.1' },
          connectTimeout: Math.min(timeout, 10000), readTimeout: timeout, maxBytes: MAX_WEB_BYTES,
          dataType: 'buffer', redirect: 'return'
        }, (stop: () => void) => { abort = stop; })
          .then((response: CompatResponse) => finish(response))
          .catch((error: Error) => finish(undefined, error));
      });
    } finally { await endTransfer(); }
  }
}
