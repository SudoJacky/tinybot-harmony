import { t } from '../model/I18n';
import { ToolCall, ToolDefinition } from '../model/Agent';
import { AgentTools } from './AgentLoop';
import { Cancellation } from './Cancellation';

export const MAX_WEB_BYTES: number = 1024 * 1024;
export const MAX_WEB_TEXT: number = 20000;

export interface WebDocument { url: string; contentType: string; body: string; }
export interface WebTransport {
  get(address: string, cancellation: Cancellation): Promise<WebDocument>;
  resolve(reference: string, base: string): string;
}
export interface WebLink { title: string; url: string; }
export interface WebPage {
  url: string;
  title: string;
  content: string;
  links: WebLink[];
  truncated: boolean;
  linksTruncated: boolean;
  trust: string;
}
interface WebArguments { url: string; }

export function validateWebAddress(value: string): string {
  if (typeof value !== 'string' || value.length > 4096 || /[\s\u0000-\u001f\\]/.test(value)) {
    throw new Error(t("网页地址必须是不含空白的 HTTP 或 HTTPS URL。"));
  }
  const match = /^https?:\/\/([^/?#]+)(?:[/?#]|$)/i.exec(value);
  if (!match || match[1].includes('@')) {
    throw new Error(t("只能读取 HTTP 或 HTTPS 网页，地址不能包含用户名或密码。"));
  }
  return value;
}

export function decodeEntities(value: string): string {
  const named: Record<string, string> = { 'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'", 'nbsp': ' ' };
  return value.replace(/&(#x[0-9a-f]+|#\d+|amp|lt|gt|quot|apos|nbsp);/gi, (_match: string, entity: string): string => {
    if (!entity.startsWith('#')) { return named[entity.toLowerCase()]; }
    const code = entity.toLowerCase().startsWith('#x') ? parseInt(entity.slice(2), 16) : parseInt(entity.slice(1), 10);
    return code > 0 && code <= 0x10ffff && (code < 0xd800 || code > 0xdfff) ? String.fromCodePoint(code) : '\uFFFD';
  });
}

function plainText(value: string): string {
  return decodeEntities(value.replace(/<[^>]*>/g, ' ')).replace(/[ \t\f\v]+/g, ' ')
    .replace(/ *\n */g, '\n').replace(/\n{3,}/g, '\n\n').trim();
}

export function extractWebPage(document: WebDocument, transport: WebTransport): WebPage {
  const mime = document.contentType.split(';')[0].trim().toLowerCase();
  const html = mime === 'text/html' || mime === 'application/xhtml+xml';
  if (!html && !mime.startsWith('text/') && mime !== 'application/json' && mime !== 'application/xml') {
    throw new Error(t("暂不支持此网页内容类型：") + (mime || t("未声明")) + t("。请使用 HTML 或文本链接。"));
  }
  let title = '';
  let content = document.body;
  const links: WebLink[] = [];
  let linksTruncated = false;
  if (html) {
    const clean = document.body.replace(/<!--[\s\S]*?-->/g, '')
      .replace(/<(script|style|template|svg|noscript)\b[^>]*>[\s\S]*?<\/\1\s*>/gi, '');
    title = plainText(/<title\b[^>]*>([\s\S]*?)<\/title\s*>/i.exec(clean)?.[1] || '').slice(0, 300);
    // Prefer the article/main region, but do not execute JavaScript or load subresources.
    content = /<(?:main|article)\b[^>]*>([\s\S]*?)<\/(?:main|article)\s*>/i.exec(clean)?.[1] ||
      clean.replace(/<head\b[^>]*>[\s\S]*?<\/head\s*>/gi, '');
    const anchors = /<a\b[^>]*\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))[^>]*>([\s\S]*?)<\/a\s*>/gi;
    const seen = new Set<string>();
    let match = anchors.exec(content);
    while (match) {
      const reference = decodeEntities(match[1] || match[2] || match[3] || '');
      if (reference.length > 0 && !/^(?:#|javascript:|mailto:|tel:|data:)/i.test(reference)) {
        // Non-web links are presentation data, not failed tool operations.
        let address = '';
        try { address = validateWebAddress(transport.resolve(reference, document.url)); } catch (_) { address = ''; }
        if (address.length > 0 && !seen.has(address)) {
          seen.add(address);
          if (links.length < 30) { links.push({ title: plainText(match[4]).slice(0, 200), url: address }); }
          else { linksTruncated = true; }
        }
      }
      match = anchors.exec(content);
    }
    content = plainText(content.replace(/<(?:br\b[^>]*|\/(?:p|div|li|h[1-6]|tr|section|article|main))\s*>/gi, '\n'));
  }
  if (content.includes('\u0000')) { throw new Error(t("网页返回了二进制内容或不支持的文本编码。")); }
  if (content.trim().length === 0) { throw new Error(t("网页没有可读取的正文，可能需要登录或 JavaScript。")); }
  return { url: document.url, title: title, content: content.slice(0, MAX_WEB_TEXT), links: links,
    truncated: content.length > MAX_WEB_TEXT, linksTruncated: linksTruncated, trust: 'untrusted' };
}

export class WebTools implements AgentTools {
  private transport: WebTransport;
  constructor(transport: WebTransport) { this.transport = transport; }

  definitions(): ToolDefinition[] {
    return [{ type: 'function', function: {
      name: 'read_web', description: '读取指定 HTTP/HTTPS 网页的静态正文、标题和链接，供引用来源。不是搜索引擎或浏览器；不登录、不执行 JavaScript。最多下载 1 MiB，正文最多 20000 字符，截断会明确标记。',
      parameters: { type: 'object', properties: {
        'url': { type: 'string', description: '用户提供或已知来源的完整网页 URL，不要编造地址。' }
      }, required: ['url'], additionalProperties: false }
    } }];
  }

  async execute(call: ToolCall, cancellation: Cancellation): Promise<string> {
    cancellation.check();
    if (call.function.name !== 'read_web') { throw new Error(t("不支持的网页工具。")); }
    const args = JSON.parse(call.function.arguments) as WebArguments;
    if (!args || Array.isArray(args) || typeof args.url !== 'string' || Object.keys(args).some((key: string) => key !== 'url')) {
      throw new Error(t("read_web 参数必须仅包含 url。"));
    }
    const document = await this.transport.get(validateWebAddress(args.url), cancellation);
    cancellation.check();
    return JSON.stringify(extractWebPage(document, this.transport));
  }
}
