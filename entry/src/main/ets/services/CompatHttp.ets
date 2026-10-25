import { http } from '@kit.NetworkKit';
import { rcp } from '@kit.RemoteCommunicationKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { ApiLevel } from '../common/ApiLevel';
import { t } from '../model/I18n';

// One HTTP exchange with an explicit redirect policy, on every supported system.
//
// API 23 added http.HttpRequestOptions.maxRedirects and API 22 added the interceptor chain. On
// API 20 both are ignored, so http silently follows up to five hops; a bearer token or search key
// would then be sent to whatever origin the redirect names. rcp (@kit.RemoteCommunicationKit) has
// offered TransferConfiguration.autoRedirect since API 11 and hands back the real 3xx response, so
// it is the API 20 transport. The API 23+ path keeps the previous http options unchanged.

export type CompatRedirect = 'return' | 'refuse';

export interface CompatRequest {
  url: string;
  method: string;
  headers: Record<string, string>;
  body?: string | ArrayBuffer;
  connectTimeout: number;
  readTimeout: number;
  maxBytes: number;
  dataType: 'string' | 'buffer';
  // 'return' hands back the 3xx response so the caller validates the next hop itself.
  // 'refuse' means the caller must never talk to a redirect target.
  redirect: CompatRedirect;
}

export interface CompatResponse {
  status: number;
  header: Record<string, string>;
  text: string;
  bytes: ArrayBuffer;
}

export interface CompatHandlers {
  onStatus: (status: number) => void;
  onHeaders: (headers: Record<string, string>) => void;
  onData: (chunk: ArrayBuffer) => void;
  onEnd: () => void;
  onError: (error: Error) => void;
}

class StopRedirect implements http.HttpInterceptor {
  interceptorType: http.InterceptorType = http.InterceptorType.REDIRECTION;
  async interceptorHandle(_request: http.HttpRequestContext, _response: http.HttpResponse): Promise<boolean> {
    // Return the 3xx response so the caller can validate and resolve the next hop.
    // maxRedirects: 0 alone produces error 2300047 instead of a usable response.
    return false;
  }
}

function headerMap(headers: Object | undefined): Record<string, string> {
  const result: Record<string, string> = {};
  if (!headers) { return result; }
  const fields = headers as Record<string, string | string[]>;
  for (const key of Object.keys(fields)) {
    const value = fields[key];
    result[key] = typeof value === 'string' ? value : Array.isArray(value) ? value.join('; ') : '';
  }
  return result;
}

export class CompatHttp {
  // True when the system itself can suppress redirects through http.
  static get nativeRedirectControl(): boolean { return ApiLevel.redirectLimit; }

  private static method(method: string): http.RequestMethod {
    switch (method.toUpperCase()) {
      case 'POST': return http.RequestMethod.POST;
      case 'DELETE': return http.RequestMethod.DELETE;
      case 'PUT': return http.RequestMethod.PUT;
      case 'HEAD': return http.RequestMethod.HEAD;
      default: return http.RequestMethod.GET;
    }
  }

  private static options(spec: CompatRequest): http.HttpRequestOptions {
    const options: http.HttpRequestOptions = {
      method: CompatHttp.method(spec.method),
      header: spec.headers, extraData: spec.body, usingCache: false, maxLimit: spec.maxBytes,
      connectTimeout: spec.connectTimeout, readTimeout: spec.readTimeout,
      expectDataType: spec.dataType === 'string' ? http.HttpDataType.STRING : http.HttpDataType.ARRAY_BUFFER
    };
    // Only the native API 23 field may be set; assigning it on API 20 would be silently ignored.
    if (spec.redirect === 'refuse') { options.maxRedirects = 0; }
    return options;
  }

  private static async httpRequest(spec: CompatRequest, registerAbort?: (abort: () => void) => void): Promise<CompatResponse> {
    const request = http.createHttp();
    if (registerAbort) { registerAbort(() => request.destroy()); }
    try {
      if (spec.redirect === 'return') {
        const chain = new http.HttpInterceptorChain();
        if (!chain.addChain([new StopRedirect()]) || !chain.apply(request)) {
          throw new Error(t('无法安装重定向校验。'));
        }
      }
      const response = await request.request(spec.url, CompatHttp.options(spec));
      const body = response.result;
      return {
        status: response.responseCode, header: headerMap(response.header),
        text: typeof body === 'string' ? body : '',
        bytes: body instanceof ArrayBuffer ? body : new ArrayBuffer(0)
      };
    } finally { request.destroy(); }
  }

  // Buffer only bytes accepted by the same bounded receiver used for live streams.
  private static rcpRequest(spec: CompatRequest, registerAbort?: (abort: () => void) => void): Promise<CompatResponse> {
    return new Promise<CompatResponse>((resolve, reject) => {
      let status = 0;
      let header: Record<string, string> = {};
      let length = 0;
      const chunks: ArrayBuffer[] = [];
      const stop = CompatHttp.rcpStream(spec, {
        onStatus: (value: number): void => { status = value; },
        onHeaders: (value: Record<string, string>): void => { header = value; },
        onData: (chunk: ArrayBuffer): void => { chunks.push(chunk.slice(0)); length += chunk.byteLength; },
        onEnd: (): void => {
          try {
            const bytes = new Uint8Array(length);
            let offset = 0;
            for (const chunk of chunks) { bytes.set(new Uint8Array(chunk), offset); offset += chunk.byteLength; }
            resolve({ status: status, header: header, bytes: bytes.buffer as ArrayBuffer,
              text: spec.dataType === 'string' && length > 0 ? new util.TextDecoder('utf-8').decodeToString(bytes) : '' });
          } catch (error) { reject(error as Error); }
        },
        onError: (error: Error): void => { reject(error); }
      });
      if (registerAbort) {
        registerAbort(() => { stop(); reject(new Error('HTTP request cancelled')); });
      }
    });
  }

  // Never follows a redirect. The status is the first response the origin sent. registerAbort
  // receives a function that ends the exchange early, for cancellation and page teardown.
  static async request(spec: CompatRequest, registerAbort?: (abort: () => void) => void): Promise<CompatResponse> {
    if (!CompatHttp.nativeRedirectControl) { return CompatHttp.rcpRequest(spec, registerAbort); }
    return CompatHttp.httpRequest(spec, registerAbort);
  }

  // Streaming exchange. The caller decides when it is finished: an MCP server ends the request
  // when its JSON-RPC answer arrives, not when the server closes an SSE connection.
  static stream(spec: CompatRequest, handlers: CompatHandlers): () => void {
    if (CompatHttp.nativeRedirectControl) { return CompatHttp.httpStream(spec, handlers); }
    return CompatHttp.rcpStream(spec, handlers);
  }

  private static httpStream(spec: CompatRequest, handlers: CompatHandlers): () => void {
    const request = http.createHttp();
    let closed = false;
    const close = (): void => { if (closed) { return; } closed = true; request.destroy(); };
    request.on('headersReceive', (value: Object) => handlers.onHeaders(headerMap(value)));
    request.on('dataReceive', (chunk: ArrayBuffer) => handlers.onData(chunk));
    request.on('dataEnd', () => handlers.onEnd());
    try {
      request.requestInStream(spec.url, CompatHttp.options(spec), (error: BusinessError, status: number) => {
        if (error) { handlers.onError(error); } else { handlers.onStatus(status); }
      });
    } catch (error) { handlers.onError(error as Error); }
    return close;
  }

  // RCP's callbacks are available on API 20. Deliver frames before EOF, and cancel native I/O
  // immediately when the caller has its result or reception crosses the byte budget.
  private static rcpStream(spec: CompatRequest, handlers: CompatHandlers): () => void {
    let closed = false;
    let bytes = 0;
    let statusReceived = false;
    let headersReceived = false;
    let session: rcp.Session | undefined;
    const release = (cancel: boolean): void => {
      const active = session;
      session = undefined;
      if (active) { try { if (cancel) { active.cancel(); } } finally { active.close(); } }
    };
    const stop = (): void => { if (closed) { return; } closed = true; release(true); };
    const fail = (error: Error): void => {
      if (closed) { return; }
      closed = true;
      try { release(true); } finally { handlers.onError(error); }
    };
    const events: rcp.HttpEventsHandler = {
      onStatusCodeReceive: (status: number): void => {
        if (closed) { return; } statusReceived = true; handlers.onStatus(status);
      },
      onHeaderReceive: (headers: rcp.ResponseHeaders): void => {
        if (closed) { return; } headersReceived = true; handlers.onHeaders(headerMap(headers));
      },
      onDataReceive: (chunk: ArrayBuffer): number => {
        if (closed) { return 0; }
        if (chunk.byteLength > spec.maxBytes - bytes) { fail(new Error(t('响应超过大小上限。'))); return 0; }
        bytes += chunk.byteLength;
        handlers.onData(chunk);
        return chunk.byteLength;
      }
    };
    try {
      session = rcp.createSession({ requestConfiguration: {
        transfer: { autoRedirect: false, timeout: { connectMs: spec.connectTimeout, transferMs: spec.readTimeout } },
        tracing: { httpEventsHandler: events }
      } });
      session.fetch(new rcp.Request(spec.url, spec.method.toUpperCase(), spec.headers, spec.body))
        .then((response: rcp.Response): void => {
          if (closed) { return; }
          if (!statusReceived) { handlers.onStatus(response.statusCode); }
          if (closed) { return; }
          if (!headersReceived) { handlers.onHeaders(headerMap(response.headers)); }
          if (closed) { return; }
          closed = true;
          release(false);
          handlers.onEnd();
        }).catch((error: Error) => fail(error));
    } catch (error) { fail(error as Error); }
    return stop;
  }
}
