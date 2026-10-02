import { t } from '../model/I18n';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { McpServer } from '../model/Productivity';
import { Cancellation } from './Cancellation';
import { McpOAuth } from './McpOAuth';

interface RpcRequest { jsonrpc: string; id?: number; method: string; params?: Object; }
interface RpcError { code: number; message: string; }
export interface RpcResponse { jsonrpc: string; id?: number; result?: Object; error?: RpcError; }
interface ClientInfo { name: string; version: string; }
interface InitializeParams { protocolVersion: string; capabilities: Record<string, string>; clientInfo: ClientInfo; }
interface CursorParams { cursor?: string; }
interface CallParams { name: string; arguments: Object; }
interface InitializeResult { protocolVersion: string; }
export interface McpToolInfo { name: string; description?: string; inputSchema: Object; }
interface ToolsResult { tools: McpToolInfo[]; nextCursor?: string; }

export function mcpResponse(text: string, id: number): RpcResponse | undefined {
  const frames = text.trim().startsWith('{') ? [text] : text.replace(/\r\n/g, '\n').split('\n\n')
    .filter((frame) => frame.includes('data:')).map((frame) => frame.split('\n').filter((line) => line.startsWith('data:')).map((line) => line.slice(5).trimStart()).join('\n'));
  for (const frame of frames) {
    let response: RpcResponse;
    try { response = JSON.parse(frame) as RpcResponse; } catch (_) { continue; }
    if (response && response.jsonrpc === '2.0' && response.id === id) { return response; }
  }
  return undefined;
}

// One client per server per run. No retry of tool calls with uncertain side effects.
export class McpClient {
  private server: McpServer;
  private session: string = '';
  private version: string = '2025-06-18';
  private initialized: boolean = false;
  private sequence: number = 0;
  constructor(server: McpServer) { this.server = server; }

  private async initialize(cancellation: Cancellation): Promise<void> {
    if (this.initialized) { return; }
    const params: InitializeParams = { protocolVersion: this.version, capabilities: {}, clientInfo: { name: 'tinybot-harmony', version: '0.2.0' } };
    const result = await this.post('initialize', params, cancellation) as InitializeResult;
    if (!result || !['2025-03-26', '2025-06-18', '2025-11-25'].includes(result.protocolVersion)) { throw new Error(t("MCP 协议版本不受支持。")); }
    this.version = result.protocolVersion;
    await this.post('notifications/initialized', undefined, cancellation, true); this.initialized = true;
  }
  async list(cancellation: Cancellation): Promise<McpToolInfo[]> {
    await this.initialize(cancellation); const tools: McpToolInfo[] = []; let cursor = '';
    for (let page = 0; page < 10; page++) {
      const params: CursorParams = { cursor: cursor || undefined };
      const result = await this.post('tools/list', params, cancellation) as ToolsResult;
      if (!result || !Array.isArray(result.tools)) { throw new Error(t("MCP 工具目录格式无效。")); }
      for (const tool of result.tools) {
        if (typeof tool.name !== 'string' || !tool.name || !tool.inputSchema || typeof tool.inputSchema !== 'object') { throw new Error(t("MCP 工具定义无效。")); }
        tools.push(tool);
      }
      if (tools.length > 200) { throw new Error(t("MCP 服务工具超过 200 个，请缩小服务范围。")); }
      if (!result.nextCursor) { return tools; }
      if (result.nextCursor === cursor) { throw new Error(t("MCP 分页游标重复。")); } cursor = result.nextCursor;
    }
    throw new Error(t("MCP 工具目录分页过多。"));
  }
  async call(name: string, args: Object, cancellation: Cancellation): Promise<Object> {
    await this.initialize(cancellation); const params: CallParams = { name: name, arguments: args };
    return this.post('tools/call', params, cancellation);
  }
  private async post(method: string, params: Object | undefined, cancellation: Cancellation, notification: boolean = false): Promise<Object> {
    cancellation.check();
    const key = await McpOAuth.bearer(this.server); cancellation.check();
    const id = ++this.sequence;
    const body: RpcRequest = { jsonrpc: '2.0', id: notification ? undefined : id, method: method, params: params };
    const headers: Record<string, string> = { 'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream', 'MCP-Protocol-Version': this.version };
    if (key) { headers['Authorization'] = 'Bearer ' + key; }
    if (this.session) { headers['Mcp-Session-Id'] = this.session; }
    const request = http.createHttp();
    return new Promise<Object>((resolve, reject) => {
      let done = false; let code = 0; let text = ''; let bytes = 0; let ended = false;
      let remove = (): void => {}; let timer = -1;
      const decoder = new util.TextDecoder('utf-8');
      const finish = (error?: Error, result?: Object): void => {
        if (done) { return; } done = true; clearTimeout(timer); remove(); request.destroy();
        if (error) { reject(error); } else { const empty: Record<string, string> = {}; resolve(result || empty); }
      };
      const inspect = (): void => {
        if (!code || done) { return; }
        if (code < 200 || code >= 300) {
          if (code === 404) { this.session = ''; this.initialized = false; }
          finish(new Error('MCP HTTP ' + code + (code === 401 ? t("：请检查 Bearer Token 或重新进行 OAuth 登录。") : t("。调用未自动重试；如已提交写操作，请先检查结果。")))); return;
        }
        if (notification) { finish(); return; }
        const response = mcpResponse(text, id);
        if (response?.error) {
          const message = typeof response.error.message === 'string' ? response.error.message.slice(0, 500) : '服务返回无效错误信息';
          finish(new Error(t("MCP 错误 ") + response.error.code + '：' + message));
        }
        else if (response?.result !== undefined) { finish(undefined, response.result); }
        else if (ended) { finish(new Error(t("MCP 响应缺少对应请求结果。"))); }
      };
      timer = setTimeout(() => finish(new Error(t("MCP 请求超时，结果未知；请检查服务端状态。"))), 60000);
      remove = cancellation.onCancel(() => {
        finish(new Error(t("MCP 已停止等待，已提交的远程操作可能仍在执行。")));
        if (method === 'tools/call') {
          const params: Record<string, string | number> = { 'requestId': id, 'reason': 'User cancelled' };
          this.post('notifications/cancelled', params, new Cancellation(), true).catch(() => {});
        }
      });
      if (done) { return; }
      request.on('headersReceive', (value: Object) => {
        const received = value as Record<string, string>;
        for (const name of Object.keys(received)) {
          if (name.toLowerCase() === 'mcp-session-id') {
            const session = received[name];
            if (typeof session === 'string' && /^[\x21-\x7e]{1,512}$/.test(session)) { this.session = session; }
          }
        }
      });
      request.on('dataReceive', (buffer: ArrayBuffer) => {
        if (done) { return; } bytes += buffer.byteLength;
        if (bytes > 1024 * 1024) { finish(new Error(t("MCP 响应超过 1 MB。"))); return; }
        try { text += decoder.decodeToString(new Uint8Array(buffer), { stream: true }); inspect(); }
        catch (_) { finish(new Error(t("MCP 返回了无法解析的数据。"))); }
      });
      request.on('dataEnd', () => {
        if (done) { return; }
        try { ended = true; text += decoder.decodeToString(new Uint8Array(0)); inspect(); }
        catch (_) { finish(new Error(t("MCP 返回了无法解析的数据。"))); }
      });
      try { request.requestInStream(this.server.url, { method: http.RequestMethod.POST, header: headers, extraData: JSON.stringify(body),
        usingCache: false, connectTimeout: 15000, readTimeout: 60000, maxRedirects: 0 }, (error, status) => {
        if (error) { finish(new Error(t("MCP 网络请求失败（") + error.code + '）。')); } else { code = status; inspect(); }
      }); } catch (_) { finish(new Error(t("无法创建 MCP 请求。"))); }
    });
  }
}
