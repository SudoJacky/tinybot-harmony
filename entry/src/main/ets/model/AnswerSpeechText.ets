import { markdownBlocks, markdownSpans } from './Markdown';

// Read prose, link labels and table cells, without speaking code, images or generated UI payloads.
export function answerSpeechText(source: string): string {
  return markdownBlocks(source).filter((block) => block.kind !== 'code' && block.kind !== 'rule' && block.kind !== 'image')
    .map((block) => block.kind === 'table' ? block.rows.map((row) => row.join('，')).join('\n') : block.text)
    .map((text) => markdownSpans(text.replace(/!\[[^\]]*\]\([^)]*\)/g, '')).map((span) => span.text).join(''))
    .join('\n').trim();
}

// CoreSpeech limits each request to 10,000 characters. Prefer sentence boundaries and retain all text.
export function answerSpeechChunks(text: string): string[] {
  const chunks: string[] = [];
  let rest = text.trim();
  while (rest.length > 9000) {
    const prefix = rest.slice(0, 9000);
    let end = Math.max(prefix.lastIndexOf('\n'), prefix.lastIndexOf('。'), prefix.lastIndexOf('！'),
      prefix.lastIndexOf('？'), prefix.lastIndexOf('. '), prefix.lastIndexOf(' ')) + 1;
    if (end < 4500) { end = 9000; }
    const last = rest.charCodeAt(end - 1);
    if (last >= 0xD800 && last <= 0xDBFF) { end--; }
    chunks.push(rest.slice(0, end)); rest = rest.slice(end);
  }
  if (rest.length > 0) { chunks.push(rest); }
  return chunks;
}
