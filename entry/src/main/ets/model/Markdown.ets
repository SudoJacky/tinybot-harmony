export interface MarkdownBlock { kind: string; text: string; level: number; rows: string[][]; }
export interface MarkdownSpan { text: string; kind: string; url: string; }
export function markdownBlocks(source: string): MarkdownBlock[] {
  const lines = source.replace(/\r\n/g, '\n').split('\n'); const blocks: MarkdownBlock[] = [];
  let index = 0;
  while (index < lines.length) {
    const line = lines[index];
    if (!line.trim()) { index++; continue; }
    const fence = line.match(/^\s*(```+|~~~+)(.*)$/);
    if (fence) {
      const content: string[] = []; index++;
      while (index < lines.length && !lines[index].trim().startsWith(fence[1])) { content.push(lines[index++]); }
      if (index < lines.length) { index++; }
      blocks.push({ kind: 'code', text: content.join('\n'), level: 0, rows: [[fence[2].trim()]] }); continue;
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
  return blocks;
}
function tableCells(line: string): string[] { return line.trim().replace(/^\|/, '').replace(/\|$/, '').split('|').map((cell) => cell.trim()); }
// Bare URLs stop before CJK/fullwidth punctuation and trailing sentence punctuation.
const SPAN_PATTERN: RegExp = new RegExp('\\[([^\\]]+)\\]\\((https?://[^\\s)]+)\\)|\\*\\*([^*]+)\\*\\*|__([^_]+)__|`([^`]+)`|\\*([^*]+)\\*|~~([^~]+)~~|' +
  '(https?://[^\\s<>()\\[\\]\\u3000-\\u303f\\uff01-\\uff1f]*[^\\s<>()\\[\\].,;:!?\'"\\u3000-\\u303f\\uff01-\\uff1f])', 'g');
export function markdownSpans(text: string): MarkdownSpan[] {
  const spans: MarkdownSpan[] = []; const pattern = new RegExp(SPAN_PATTERN.source, 'g');
  let start = 0; let match = pattern.exec(text);
  while (match) {
    if (match.index > start) { spans.push({ text: text.slice(start, match.index), kind: 'text', url: '' }); }
    spans.push({ text: match[1] || match[3] || match[4] || match[5] || match[6] || match[7] || match[8],
      kind: match[1] || match[8] ? 'link' : match[3] || match[4] ? 'bold' : match[5] ? 'code' : match[7] ? 'strike' : 'italic',
      url: match[2] || match[8] || '' });
    start = match.index + match[0].length; match = pattern.exec(text);
  }
  if (start < text.length) { spans.push({ text: text.slice(start), kind: 'text', url: '' }); }
  return spans;
}
