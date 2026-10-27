import { ToolFailure, parseToolArguments } from '../model/ToolFailure';
import { t } from '../model/I18n';
import { ToolCall, ToolDefinition } from '../model/Agent';
import { AgentTools, ToolInvocationContext } from './AgentLoop';
import { Cancellation } from './Cancellation';

// Default download buffer budget, adjustable by the caller rather than a content ceiling.
export const MAX_WEB_BYTES: number = 1024 * 1024;
const DEFAULT_WEB_TEXT: number = 8000;

export interface WebDocument { url: string; contentType: string; body: string; }
export interface WebTransport {
  get(address: string, cancellation: Cancellation, maxBytes?: number): Promise<WebDocument>;
  resolve(reference: string, base: string): string;
}
export interface WebLink { title: string; url: string; }
export interface WebPage {
  url: string;
  favicon?: string;
  title: string;
  content: string;
  links: WebLink[];
  truncated: boolean;
  offset?: number;
  totalChars?: number;
  nextOffset?: number;
  linksTruncated: boolean;
  trust: string;
}
interface WebArguments { url: string; offset?: number; maxChars?: number; maxBytes?: number; }

export function validateWebAddress(value: string): string {
  if (typeof value !== 'string' || value.length > 4096 || /[\s\u0000-\u001f\\]/.test(value)) {
    throw new ToolFailure('INVALID_ARGUMENTS', t("网页地址必须是不含空白的 HTTP 或 HTTPS URL。"), 'fix_arguments');
  }
  const match = /^https?:\/\/([^/?#]+)(?:[/?#]|$)/i.exec(value);
  if (!match || match[1].includes('@')) {
    throw new ToolFailure('INVALID_ARGUMENTS', t("只能读取 HTTP 或 HTTPS 网页，地址不能包含用户名或密码。"), 'fix_arguments');
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

function htmlAttribute(tag: string, name: string): string {
  const match = new RegExp('\\s' + name + '\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\'|([^\\s>]+))', 'i').exec(tag);
  return decodeEntities(match?.[1] || match?.[2] || match?.[3] || '').trim();
}

// Metadata only: reading a page does not fetch its subresources.
function pageFavicon(clean: string, address: string, transport: WebTransport): string {
  const head = /<head\b[^>]*>([\s\S]*?)<\/head\s*>/i.exec(clean)?.[1] || clean;
  let base = address;
  const baseTag = /<base\b[^>]*>/i.exec(head)?.[0] || '';
  try { base = validateWebAddress(transport.resolve(htmlAttribute(baseTag, 'href') || address, address)); }
  catch (_) { /* An invalid optional base does not invalidate the page. */ }
  let touchIcon = '';
  for (const tag of head.match(/<link\b[^>]*>/gi) || []) {
    const rel = htmlAttribute(tag, 'rel').toLowerCase().split(/\s+/);
    const href = htmlAttribute(tag, 'href');
    if (!href || (!rel.includes('icon') && !rel.includes('apple-touch-icon'))) { continue; }
    try {
      const icon = validateWebAddress(transport.resolve(href, base));
      if (rel.includes('icon')) { return icon; }
      if (!touchIcon) { touchIcon = icon; }
    } catch (_) { /* Ignore non-web or malformed optional icons. */ }
  }
  return touchIcon || validateWebAddress(transport.resolve('/favicon.ico', address));
}

export function extractWebPage(document: WebDocument, transport: WebTransport, offset: number = 0, maxChars: number = DEFAULT_WEB_TEXT): WebPage {
  const mime = document.contentType.split(';')[0].trim().toLowerCase();
  const html = mime === 'text/html' || mime === 'application/xhtml+xml';
  const structured = mime === 'application/json' || mime === 'application/xml' || /^application\/[a-z0-9.+-]+\+(?:xml|json)$/.test(mime);
  if (!html && !mime.startsWith('text/') && !structured) {
    throw new ToolFailure('UNSUPPORTED_CONTENT', t("暂不支持此网页内容类型：") + (mime || t("未声明")) + t("。请使用 HTML 或文本链接。"), 'use_supported_source');
  }
  let title = '';
  let favicon: string | undefined = undefined;
  let content = document.body;
  const links: WebLink[] = [];
  let linksTruncated = false;
  if (html) {
    const clean = document.body.replace(/<!--[\s\S]*?-->/g, '')
      .replace(/<(script|style|template|svg|noscript)\b[^>]*>[\s\S]*?<\/\1\s*>/gi, '');
    favicon = pageFavicon(clean, document.url, transport);
    title = plainText(/<title\b[^>]*>([\s\S]*?)<\/title\s*>/i.exec(clean)?.[1] || '');
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
          if (links.length < 30) { links.push({ title: plainText(match[4]), url: address }); }
          else { linksTruncated = true; }
        }
      }
      match = anchors.exec(content);
    }
    content = plainText(content.replace(/<(?:br\b[^>]*|\/(?:p|div|li|h[1-6]|tr|section|article|main))\s*>/gi, '\n'));
  }
  if (content.includes('\u0000')) { throw new ToolFailure('UNSUPPORTED_CONTENT', t("网页返回了二进制内容或不支持的文本编码。"), 'use_supported_source'); }
  if (content.trim().length === 0) { throw new ToolFailure('CONTENT_UNAVAILABLE', t("网页没有可读取的正文，可能需要登录或 JavaScript。"), 'use_supported_source'); }
  return { url: document.url, favicon: favicon, title: title, content: content.slice(offset, offset + maxChars), links: links,
    offset: offset, totalChars: content.length, nextOffset: offset + maxChars < content.length ? offset + maxChars : undefined,
    truncated: offset > 0 || content.length > maxChars, linksTruncated: linksTruncated, trust: 'untrusted' };
}

export class WebTools implements AgentTools {
  private transport: WebTransport;
  constructor(transport: WebTransport) { this.transport = transport; }

  definitions(): ToolDefinition[] {
    return [{ type: 'function', promptSnippet: '读取已知 URL 的静态网页',
      promptGuidelines: ['read_web 不提供联网搜索。引用使用工具返回的来源 URL，区分网页陈述与推断；读取失败、内容过期或截断时说明证据局限。',
        '按需读取正文，使用 nextOffset 继续读取所需部分，不必把全部脚注放入上下文。SEC 财报先从 FilingSummary.xml 定位报表，不要猜测 R 编号。'], function: {
      name: 'read_web', description: '读取指定 HTTP/HTTPS 网页的静态正文、标题和链接，供引用来源。不是搜索引擎或浏览器；不登录、不执行 JavaScript。下载缓冲预算默认 1 MiB，可调大 maxBytes；正文默认返回 8000 字符，可指定 offset/maxChars 分页或调大每页字符数。truncated 标记非全文；nextOffset 存在时可继续读取。HTTP 403 时可用浏览器或更换有依据的公开来源。',
      parameters: { type: 'object', properties: {
        'url': { type: 'string', description: '用户提供或已知来源的完整网页 URL，不要编造地址。' },
        'offset': { type: 'integer', description: '正文字符偏移，首次为 0；继续读取时使用返回的 nextOffset。', minimum: 0 },
        'maxChars': { type: 'integer', description: '本次所需正文字符数，默认 8000，可调大。', minimum: 1 },
        'maxBytes': { type: 'integer', description: '下载缓冲字节预算，默认 1048576；下载超出预算时可调大。', minimum: 1 }
      }, required: ['url'], additionalProperties: false }
    } }];
  }

  async execute(call: ToolCall, cancellation: Cancellation, context?: ToolInvocationContext): Promise<string> {
    cancellation.check();
    if (call.function.name !== 'read_web') { throw new ToolFailure('TOOL_UNAVAILABLE', t("不支持的网页工具。"), 'check_available_tools'); }
    const args = parseToolArguments(call.function.arguments) as WebArguments;
    if (!args || Array.isArray(args) || typeof args.url !== 'string' || Object.keys(args).some((key: string) => !['url', 'offset', 'maxChars', 'maxBytes'].includes(key)) ||
      (args.offset !== undefined && (!Number.isSafeInteger(args.offset) || args.offset < 0)) ||
      (args.maxChars !== undefined && (!Number.isSafeInteger(args.maxChars) || args.maxChars < 1)) ||
      (args.maxBytes !== undefined && (!Number.isSafeInteger(args.maxBytes) || args.maxBytes < 1))) {
      throw new ToolFailure('INVALID_ARGUMENTS', 'read_web requires url, optional nonnegative integer offset and positive integer maxChars/maxBytes.', 'fix_arguments');
    }
    const document = await this.transport.get(validateWebAddress(args.url), cancellation, args.maxBytes);
    cancellation.check();
    const page = extractWebPage(document, this.transport, args.offset, args.maxChars);
    if (context) { context.execution.websiteIcon = page.favicon; }
    page.favicon = undefined;
    return JSON.stringify(page);
  }
}
