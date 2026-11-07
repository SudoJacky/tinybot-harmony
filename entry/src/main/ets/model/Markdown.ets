export interface MarkdownBlock { kind: string; text: string; level: number; rows: string[][]; }
export interface MarkdownSpan { text: string; kind: string; url: string; }
interface MarkdownParse { blocks: MarkdownBlock[]; starts: number[]; }
// Only a whole line turns into an image block; an image written inside prose stays a link.
// HTTPS only: a model reply must not make the app fetch cleartext or local sources.
const IMAGE_LINE: RegExp = /^\s*!\[([^\]]*)\]\((https:\/\/[^\s)]+)(?:\s+"[^"]*")?\)\s*$/;
export function markdownBlocks(source: string): MarkdownBlock[] {
  return parseMarkdown(source.replace(/\r\n/g, '\n')).blocks;
}
function parseMarkdown(source: string): MarkdownParse {
  const lines = source.split('\n'); const blocks: MarkdownBlock[] = [];
  const offsets: number[] = []; let offset = 0;
  for (const line of lines) { offsets.push(offset); offset += line.length + 1; }
  const starts: number[] = [];
  let index = 0;
  while (index < lines.length) {
    const line = lines[index];
    if (!line.trim()) { index++; continue; }
    // Our export header is metadata, not prose. Fence bodies are consumed below
    // as one block, so examples of the marker inside code remain visible.
    if (/^<!-- tinybot-export-aigc \{[^\r\n]*\} -->$/.test(line)) { index++; continue; }
    starts.push(offsets[index]);
    const fence = line.match(/^\s*(```+|~~~+)(.*)$/);
    if (fence) {
      const content: string[] = []; index++;
      while (index < lines.length && !lines[index].trim().startsWith(fence[1])) { content.push(lines[index++]); }
      if (index < lines.length) { index++; }
      blocks.push({ kind: 'code', text: content.join('\n'), level: 0, rows: [[fence[2].trim()]] }); continue;
    }
    const math = line.match(/^\s*(\$\$|\\\[)(.*)$/);
    if (math) {
      const close = math[1] === '$$' ? '$$' : '\\]';
      const body: string[] = [math[2]]; const raw: string[] = [line]; index++;
      while (!body[body.length - 1].trimEnd().endsWith(close) && index < lines.length) {
        const next = lines[index++]; body.push(next); raw.push(next);
      }
      const complete = body[body.length - 1].trimEnd().endsWith(close);
      if (complete) { body[body.length - 1] = body[body.length - 1].trimEnd().slice(0, -close.length); }
      // Retain an open display as one block, so incremental updates can revisit its opener.
      blocks.push({ kind: complete ? 'math' : 'math-pending', text: complete ? body.join('\n').trim() : raw.join('\n'), level: 0, rows: [] }); continue;
    }
    if (index + 1 < lines.length && line.includes('|') && /^\s*\|?\s*:?-{3,}/.test(lines[index + 1])) {
      const rows: string[][] = [tableCells(line)]; index += 2;
      while (index < lines.length && lines[index].includes('|') && lines[index].trim()) { rows.push(tableCells(lines[index++])); }
      blocks.push({ kind: 'table', text: '', level: 0, rows: rows }); continue;
    }
    if (/^>\s?/.test(line)) {
      // Consecutive quote lines form one block so the accent bar stays continuous.
      const quoted: string[] = [];
      while (index < lines.length && /^>\s?/.test(lines[index])) { quoted.push(lines[index++].replace(/^>\s?/, '')); }
      blocks.push({ kind: 'quote', text: quoted.join('\n'), level: 0, rows: [] }); continue;
    }
    const image = line.match(IMAGE_LINE);
    if (image) {
      // rows[0] is [alt, url]; an unclosed or still-streaming URL keeps parsing as text.
      blocks.push({ kind: 'image', text: '', level: 0, rows: [[image[1], image[2]]] });
      index++; continue;
    }
    const heading = line.match(/^(#{1,6})\s+(.+)$/);
    const bullet = line.match(/^(\s*)([-*+]|\d+[.)])\s+(.*)$/);
    if (bullet && !/^\s*([-*_])(?:\s*\1){2,}\s*$/.test(line)) {
      // rows[0][0] is the gutter marker: bullet, number or task checkbox; level is the nesting depth.
      const task = bullet[3].match(/^\[([ xX])\]\s+(.*)$/);
      const marker = task ? (task[1] === ' ' ? '☐' : '☑') : /\d/.test(bullet[2]) ? bullet[2].replace(')', '.') : '•';
      blocks.push({ kind: 'list', text: task ? task[2] : bullet[3], rows: [[marker]],
        level: Math.min(3, Math.floor(bullet[1].replace(/\t/g, '  ').length / 2)) });
      index++; continue;
    }
    blocks.push({ kind: heading ? 'heading' : /^\s*([-*_])(?:\s*\1){2,}\s*$/.test(line) ? 'rule' : 'text',
      text: heading ? heading[2] : line, level: heading ? heading[1].length : 0, rows: [] });
    index++;
  }
  return { blocks: blocks, starts: starts };
}

export interface MarkdownUpdate { start: number; blocks: MarkdownBlock[]; }
// Keep the final two blocks mutable: a partial table separator may initially
// parse as its own block, then turn the preceding line into a table header.
export class MarkdownDocument {
  private source: string = '';
  private starts: number[] = [];
  update(content: string): MarkdownUpdate {
    const source = content.replace(/\r\n/g, '\n');
    if (source === this.source) { return { start: this.starts.length, blocks: [] }; }
    const append = source.startsWith(this.source);
    const start = append ? Math.max(0, this.starts.length - 2) : 0;
    const offset = append && this.starts.length ? this.starts[start] : 0;
    const parsed = parseMarkdown(source.slice(offset));
    this.starts.length = start;
    for (const position of parsed.starts) { this.starts.push(offset + position); }
    this.source = source;
    return { start: start, blocks: parsed.blocks };
  }
}
function tableCells(line: string): string[] { return line.trim().replace(/^\|/, '').replace(/\|$/, '').split('|').map((cell) => cell.trim()); }
// Bare URLs stop before CJK/fullwidth punctuation and trailing sentence punctuation.
const SPAN_PATTERN: RegExp = new RegExp('!?\\[([^\\]]*)\\]\\((https?://[^\\s)]+)\\)|\\*\\*([^*]+)\\*\\*|__([^_]+)__|`([^`]+)`|\\*([^*]+)\\*|~~([^~]+)~~|' +
  '(https?://[^\\s<>()\\[\\]\\u3000-\\u303f\\uff01-\\uff1f]*[^\\s<>()\\[\\].,;:!?\'"\\u3000-\\u303f\\uff01-\\uff1f])', 'g');
export function markdownSpans(text: string): MarkdownSpan[] {
  if (!text.includes('$') && !text.includes('\\(')) { return plainSpans(text); }
  const spans: MarkdownSpan[] = [];
  // Consume the earliest token, so code protects delimiters and math protects TeX asterisks.
  const protectedToken = /(`+)[\s\S]*?\1|!?\[[^\]]*\]\(https?:\/\/[^\s)]+\)|\*\*[^*]+\*\*|__[^_]+__|\*[^*]+\*|~~[^~]+~~/g;
  let start = 0; let index = 0; let match = protectedToken.exec(text);
  while (index < text.length) {
    if (match && index === match.index) {
      spans.push(...plainSpans(text.slice(start, index)));
      if (match[1]) { spans.push({ kind: 'code', text: match[0].slice(match[1].length, -match[1].length), url: '' }); }
      else {
        for (const span of plainSpans(match[0])) {
          if (span.kind === 'link') { spans.push(span); }
          else {
            spans.push(...markdownSpans(span.text).map((part: MarkdownSpan): MarkdownSpan => {
              return { text: part.text, kind: part.kind === 'math' ? 'math' : span.kind, url: part.url };
            }));
          }
        }
      }
      index += match[0].length; start = index; match = protectedToken.exec(text); continue;
    }
    const paren = text.slice(index, index + 2) === '\\(';
    const dollar = text[index] === '$' && text[index + 1] !== '$' && text[index - 1] !== '$';
    if ((!paren && !dollar) || escaped(text, index) || (dollar && /\s/.test(text[index + 1] || ' '))) { index++; continue; }
    const size = paren ? 2 : 1; const close = paren ? '\\)' : '$'; let end = index + size;
    while (end < text.length && text[end] !== '\n') {
      // An unmatched currency marker must not consume a later code span or link.
      if (dollar && match && end === match.index && (match[1] || /^!?\[/.test(match[0]))) { end = text.length; break; }
      if (text.slice(end, end + size) === close && !escaped(text, end)) {
        if (paren || (!/\s/.test(text[end - 1]) && !/[\d$]/.test(text[end + 1] || ''))) { break; }
        end = text.length; break;
      }
      end++;
    }
    if (end === text.length || text[end] === '\n') { index += size; continue; }
    spans.push(...plainSpans(text.slice(start, index)));
    spans.push({ kind: 'math', text: text.slice(index + size, end), url: '' });
    index = end + size; start = index;
    protectedToken.lastIndex = index; match = protectedToken.exec(text);
  }
  spans.push(...plainSpans(text.slice(start)));
  return spans;
}
function escaped(text: string, index: number): boolean {
  let slashes = 0;
  while (index > 0 && text[--index] === '\\') { slashes++; }
  return slashes % 2 === 1;
}
function plainSpans(text: string): MarkdownSpan[] {
  const spans: MarkdownSpan[] = []; const pattern = new RegExp(SPAN_PATTERN.source, 'g');
  let start = 0; let match = pattern.exec(text);
  while (match) {
    if (match.index > start) { spans.push({ text: text.slice(start, match.index), kind: 'text', url: '' }); }
    // Capturing groups are undefined when they do not take part in the match.
    const groups: (string | undefined)[] = match;
    const link = groups[1] !== undefined; const bare = groups[8] !== undefined;
    const url = link ? groups[2] || '' : bare ? groups[8] || '' : '';
    // An inline image without alt text keeps its URL as the visible link label.
    const label = link ? (groups[1] || url) : groups[3] || groups[4] || groups[5] || groups[6] || groups[7] || groups[8] || '';
    spans.push({ text: label, kind: link || bare ? 'link' : groups[3] !== undefined || groups[4] !== undefined ? 'bold' :
      groups[5] !== undefined ? 'code' : groups[7] !== undefined ? 'strike' : 'italic', url: url });
    start = match.index + match[0].length; match = pattern.exec(text);
  }
  if (start < text.length) { spans.push({ text: text.slice(start), kind: 'text', url: '' }); }
  return spans;
}
