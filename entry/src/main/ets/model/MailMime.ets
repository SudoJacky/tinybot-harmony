import { util } from '@kit.ArkTS';
export function mailBytes(raw: string): Uint8Array {
  const result = new Uint8Array(raw.length); for (let i = 0; i < raw.length; i++) { result[i] = raw.charCodeAt(i); } return result;
}
export function mailBinary(bytes: Uint8Array): string {
  let text = ''; for (let i = 0; i < bytes.length; i++) { text += String.fromCharCode(bytes[i]); } return text;
}
function decode(raw: string, charset: string): string {
  try { return new util.TextDecoder(charset).decodeToString(mailBytes(raw)); }
  catch (_) { throw new Error('Unsupported or invalid email character encoding'); }
}
function quotedPrintable(raw: string, header: boolean = false): string {
  return (header ? raw.replace(/_/g, ' ') : raw).replace(/=\r?\n/g, '').replace(/=([0-9a-f]{2})/gi, (_all: string, hex: string) => String.fromCharCode(parseInt(hex, 16)));
}
function base64(raw: string): string {
  const compact = raw.replace(/\s/g, '');
  if (compact.length % 4 !== 0 || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(compact)) { throw new Error('Invalid email base64 encoding'); }
  return mailBinary(new util.Base64Helper().decodeSync(compact));
}
export function mailHeader(raw: string): string {
  const text = /[\x80-\xff]/.test(raw) ? decode(raw, 'utf-8') : raw;
  return text.replace(/(\?=)[ \t\r\n]+(?==\?)/g, '$1').replace(/=\?([^?]+)\?([bq])\?([^?]*)\?=/gi,
    (_all: string, charset: string, encoding: string, content: string) => decode(encoding.toLowerCase() === 'b' ? base64(content) : quotedPrintable(content, true), charset));
}
export function mailHeaders(raw: string): Record<string, string> {
  const headers: Record<string, string> = {};
  for (const line of raw.split(/\r?\n\r?\n/)[0].replace(/\r?\n[ \t]+/g, ' ').split(/\r?\n/)) {
    const colon = line.indexOf(':'); if (colon <= 0) { continue; }
    const key = line.slice(0, colon).toLowerCase(), value = line.slice(colon + 1).trim();
    headers[key] = headers[key] ? headers[key] + ', ' + value : value;
  } return headers;
}
function parameter(header: string, name: string): string {
  const match = new RegExp('(?:^|;)\\s*' + name + '\\s*=\\s*(?:"([^"]*)"|([^;\\s]+))', 'i').exec(header); return match ? match[1] || match[2] || '' : '';
}
// Return inert plain text only. Attachments and remote images are never opened.
export function mailBodyText(raw: string, depth: number = 0): string {
  if (depth > 8 || raw.length > 512 * 1024) { throw new Error('Email MIME structure exceeds limits'); }
  const split = /\r?\n\r?\n/.exec(raw); if (!split) { throw new Error('Email has no MIME header separator'); }
  const headers = mailHeaders(raw), type = headers['content-type'] || 'text/plain', body = raw.slice(split.index + split[0].length);
  if (/^attachment(?:;|$)/i.test(headers['content-disposition'] || '')) { return ''; }
  if (/^multipart\//i.test(type)) {
    const boundary = parameter(type, 'boundary'); if (!boundary || boundary.length > 200) { throw new Error('Email MIME boundary is missing or invalid'); }
    // MIME delimiters must occupy their own line; a matching substring in the
    // message text or an attachment is not a boundary.
    const delimiter = new RegExp('^--' + boundary.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '(--)?[ \\t]*(?:\\r?\\n|$)', 'gm');
    const pieces: string[] = []; let start = -1, closed = false;
    let match = delimiter.exec(body);
    while (match) {
      if (start >= 0) { pieces.push(body.slice(start, match.index).replace(/\r?\n$/, '')); }
      if (pieces.length > 100) { throw new Error('Oversized multipart email'); }
      if (match[1]) { closed = true; break; }
      start = match.index + match[0].length; match = delimiter.exec(body);
    }
    if (!closed || !pieces.length) { throw new Error('Incomplete multipart email'); }
    const texts: string[] = [];
    for (const part of pieces) {
      const text = mailBodyText(part, depth + 1); if (text) { texts.push(text); }
      if (/^multipart\/alternative/i.test(type) && /^text\/plain/i.test(mailHeaders(part)['content-type'] || 'text/plain') && text) { return text; }
    }
    return texts.join('\n\n');
  }
  if (!/^text\/(plain|html)(?:;|$)/i.test(type)) { return ''; }
  const transfer = (headers['content-transfer-encoding'] || '7bit').toLowerCase();
  if (!['base64', 'quoted-printable', '7bit', '8bit', 'binary'].includes(transfer)) { throw new Error('Unsupported email transfer encoding'); }
  const bytes = transfer === 'base64' ? base64(body) : transfer === 'quoted-printable' ? quotedPrintable(body) : body;
  let text = decode(bytes, parameter(type, 'charset') || 'utf-8');
  if (/^text\/html/i.test(type)) {
    text = text.replace(/<(script|style)\b[^>]*>[\s\S]*?<\/\1\s*>/gi, '').replace(/<(br|\/p|\/div|\/tr)\b[^>]*>/gi, '\n').replace(/<[^>]*>/g, '')
      .replace(/&(?:amp|lt|gt|quot|apos|nbsp);/g, (entity: string) => ({ '&amp;': '&', '&lt;': '<', '&gt;': '>', '&quot;': '"', '&apos;': "'", '&nbsp;': ' ' } as Record<string, string>)[entity]);
  }
  if (text.length > 128 * 1024) { throw new Error('Email text exceeds 128 KiB'); } return text.trim();
}
export function imapFolder(folder: string): string {
  return folder.replace(/&|[^\x20-\x7e]+/g, (part: string) => {
    if (part === '&') { return '&-'; }
    const bytes = new Uint8Array(part.length * 2);
    for (let i = 0; i < part.length; i++) { bytes[i * 2] = part.charCodeAt(i) >> 8; bytes[i * 2 + 1] = part.charCodeAt(i) & 255; }
    return '&' + new util.Base64Helper().encodeToStringSync(bytes).replace(/=/g, '').replace(/\//g, ',') + '-';
  });
}
