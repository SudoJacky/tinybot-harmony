// Metadata describes an AI-assisted export, never a device or user identity.
export interface AigcFields {
  Label: string;
  ContentProducer: string;
  ProduceID: string;
  ReservedCode1: string;
  ContentPropagator: string;
  PropagateID: string;
  ReservedCode2: string;
}
export interface ExportMetadata { AIGC: AigcFields; }
export function exportMetadata(id: string): ExportMetadata {
  return { AIGC: { Label: '1', ContentProducer: 'Tinybot', ProduceID: id, ReservedCode1: '',
    ContentPropagator: 'Tinybot', PropagateID: id, ReservedCode2: '' } };
}

const MARKER = 'tinybot-export-aigc';
// Escape markup delimiters even when a future metadata field contains user text.
function safeJson(metadata: ExportMetadata): string {
  return JSON.stringify(metadata).replace(/</g, '\\u003c').replace(/>/g, '\\u003e').replace(/&/g, '\\u0026');
}
function attribute(value: string): string { return value.replace(/&/g, '&amp;').replace(/"/g, '&quot;'); }
export function stampMarkdown(source: string, metadata: ExportMetadata): string {
  const bom = source.startsWith('\ufeff') ? '\ufeff' : '';
  const body = source.slice(bom.length).replace(/^<!-- tinybot-export-aigc \{[^\r\n]*\} -->\r?\n(?:\r?\n)?/, '');
  // A front matter header must remain the first line for Markdown tools that use it.
  const front = body.match(/^---\r?\n[\s\S]*?\r?\n(?:---|\.\.\.)(?:\r?\n|$)/);
  const at = front ? front[0].length : 0;
  const rest = body.slice(at).replace(/^<!-- tinybot-export-aigc \{[^\r\n]*\} -->\r?\n(?:\r?\n)?/, '');
  return bom + body.slice(0, at) + (at && !body.slice(0, at).endsWith('\n') ? '\n' : '') +
    '<!-- ' + MARKER + ' ' + safeJson(metadata) + ' -->\n\n' + rest;
}

// Inspect only the document prologue. Never match a fake <head> inside scripts,
// comments, attributes or body text. Fragments carry a non-rendering comment.
export function stampHtml(source: string, metadata: ExportMetadata): string {
  const tag = '<meta name="AIGC" data-tinybot-export="1" content="' + attribute(safeJson(metadata)) + '">';
  const tokens = /<!--[\s\S]*?-->|<![^>]*>|<\/?[a-zA-Z][^>"']*(?:"[^"]*"[^>"']*|'[^']*'[^>"']*)*>|[^<]+|</g;
  let match = tokens.exec(source);
  while (match) {
    const token = match[0];
    if (/^<head(?:\s|>)/i.test(token)) {
      const at = match.index + token.length;
      const tail = source.slice(at).replace(/^\r?\n<meta name="AIGC" data-tinybot-export="1" content="[^"]*">\r?\n?/, '');
      return source.slice(0, at) + '\n' + tag + '\n' + tail;
    }
    if (!/^\s*$/.test(token) && !/^<!--|^<!|^<html(?:\s|>)/i.test(token)) { break; }
    match = tokens.exec(source);
  }
  return stampMarkdown(source, metadata);
}

function crc32(bytes: Uint8Array): number {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) { crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0); }
  }
  return (crc ^ 0xffffffff) >>> 0;
}
// iTXt stores UTF-8 metadata; image payload and all other chunks stay byte-identical.
export function stampPng(source: Uint8Array, utf8Metadata: Uint8Array): Uint8Array {
  const signature = [137, 80, 78, 71, 13, 10, 26, 10];
  if (signature.some((byte: number, index: number) => source[index] !== byte)) { throw new Error('Invalid PNG signature.'); }
  let at = 8;
  while (at + 12 <= source.length) {
    const view = new DataView(source.buffer, source.byteOffset + at, 12);
    const size = view.getUint32(0);
    if (at + size + 12 > source.length) { throw new Error('Invalid PNG chunk.'); }
    if (source[at + 4] === 73 && source[at + 5] === 68 && source[at + 6] === 65 && source[at + 7] === 84) { break; }
    at += size + 12;
  }
  if (at + 12 > source.length) { throw new Error('PNG has no image data.'); }
  const data = new Uint8Array(9 + utf8Metadata.length);
  data.set([65, 73, 71, 67, 0, 0, 0, 0, 0]); // keyword, compression flag/method, language, translated keyword
  data.set(utf8Metadata, 9);
  const chunk = new Uint8Array(data.length + 12);
  const chunkView = new DataView(chunk.buffer);
  chunkView.setUint32(0, data.length); chunk.set([105, 84, 88, 116], 4); chunk.set(data, 8);
  chunkView.setUint32(chunk.length - 4, crc32(chunk.subarray(4, chunk.length - 4)));
  const result = new Uint8Array(source.length + chunk.length);
  result.set(source.subarray(0, at)); result.set(chunk, at); result.set(source.subarray(at), at + chunk.length);
  return result;
}
