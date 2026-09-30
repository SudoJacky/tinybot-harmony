import { http } from '@kit.NetworkKit';
import { url, util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { Cancellation, RunCancelledError } from './Cancellation';
import { MAX_WEB_BYTES, WebDocument, WebTransport, validateWebAddress } from './WebTools';

function headerValue(headers: Object, name: string): string {
  const fields = headers as Record<string, string | string[]>;
  const key = Object.keys(fields).find((item: string) => item.toLowerCase() === name);
  if (!key) { return ''; }
  const value = fields[key];
  return typeof value === 'string' ? value : Array.isArray(value) ? value.join('; ') : '';
}

class StopRedirect implements http.HttpInterceptor {
  interceptorType: http.InterceptorType = http.InterceptorType.REDIRECTION;
  async interceptorHandle(_request: http.HttpRequestContext, _response: http.HttpResponse): Promise<boolean> {
    // Return the 3xx response so get() can validate and resolve the next hop.
    // maxRedirects: 0 alone produces 2300047 on device rather than a usable response.
    return false;
  }
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
      if (visited.has(current)) { throw new Error('网页重定向形成循环。'); }
      visited.add(current);
      const response = await this.request(current, cancellation, deadline - Date.now());
      if ([301, 302, 303, 307, 308].indexOf(response.responseCode) >= 0) {
        const location = headerValue(response.header, 'location');
        if (location.length === 0) { throw new Error('网页重定向缺少 Location。'); }
        current = this.resolve(location, current);
        continue;
      }
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error(`网页返回 HTTP ${response.responseCode}，无法读取；不会绕过登录或验证。`);
      }
      const contentType = headerValue(response.header, 'content-type');
      if (!(response.result instanceof ArrayBuffer) || response.result.byteLength > MAX_WEB_BYTES) {
        throw new Error('网页响应不是可读取的数据，或超过 1 MiB 上限。');
      }
      let encoding = /charset\s*=\s*["']?([^\s;"']+)/i.exec(contentType)?.[1] || '';
      if (encoding.length === 0 && /html/i.test(contentType)) {
        const prefix = new Uint8Array(response.result.slice(0, 2048));
        let ascii = '';
        for (const byte of prefix) { ascii += byte < 128 ? String.fromCharCode(byte) : ' '; }
        encoding = /<meta\b[^>]*charset\s*=\s*["']?([^\s;"'/>]+)/i.exec(ascii)?.[1] || '';
      }
      let body: string;
      try { body = new util.TextDecoder(encoding || 'utf-8', { fatal: true }).decodeToString(new Uint8Array(response.result)); }
      catch (_) { throw new Error('网页文本编码无法解析：' + (encoding || 'utf-8')); }
      cancellation.check();
      return { url: current, contentType: contentType, body: body };
    }
    throw new Error('网页重定向超过 5 次。');
  }

  private request(address: string, cancellation: Cancellation, timeout: number): Promise<http.HttpResponse> {
    cancellation.check();
    if (timeout <= 0) { throw new Error('网页读取超过 30 秒。'); }
    const request = http.createHttp();
    return new Promise<http.HttpResponse>((resolve, reject) => {
      let settled = false;
      let timer = -1;
      let unsubscribe = (): void => {};
      const finish = (response?: http.HttpResponse, error?: Error): void => {
        if (settled) { return; }
        settled = true;
        clearTimeout(timer);
        unsubscribe();
        request.destroy();
        if (error) { reject(error); }
        else if (response) { resolve(response); }
        else { reject(new Error('网页请求没有返回结果。')); }
      };
      timer = setTimeout(() => finish(undefined, new Error('网页读取超过 30 秒。')), timeout);
      unsubscribe = cancellation.onCancel(() => finish(undefined, new RunCancelledError() as Error));
      if (settled) { return; }
      try {
        const chain = new http.HttpInterceptorChain();
        if (!chain.addChain([new StopRedirect()]) || !chain.apply(request)) {
          throw new Error('无法安装网页重定向校验。');
        }
        // Each hop has a fresh request: no model credentials, cookies, or caller-supplied headers.
        request.request(address, { method: http.RequestMethod.GET, usingCache: false,
          header: { 'Accept': 'text/html, text/plain, text/markdown, application/json, application/xhtml+xml',
            'User-Agent': 'Tinybot-Harmony/0.1' },
          expectDataType: http.HttpDataType.ARRAY_BUFFER, maxLimit: MAX_WEB_BYTES, maxRedirects: 5,
          connectTimeout: Math.min(timeout, 10000), readTimeout: timeout
        }, (error: BusinessError, response: http.HttpResponse) => {
          if (error) { finish(undefined, new Error(`网页网络请求失败（${error.code}）：${error.message}`)); }
          else { finish(response); }
        });
      } catch (error) { finish(undefined, error as Error); }
    });
  }
}
