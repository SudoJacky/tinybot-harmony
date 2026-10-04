import { MarkdownSpan } from './Markdown';

export const STREAM_REVEAL_MS: number = 220;
interface RevealRange { start: number; end: number; born: number; }
interface RevealText { text: string; ranges: RevealRange[]; }
export interface RevealSpan { text: string; kind: string; url: string; opacity: number; }

// Track arrival times independently of Markdown styling. Closing ** or a link must
// not fade the already readable prefix again. Only recent suffix ranges are kept.
export class StreamReveal {
  private entries: Map<string, RevealText> = new Map<string, RevealText>();

  update(key: string, text: string, now: number, animate: boolean): void {
    const previous = this.entries.get(key);
    // Markdown delimiter closure can rewrite the rendered text. Settle such
    // rewrites immediately rather than replaying an animation over readable text.
    if (previous && !text.startsWith(previous.text)) {
      this.entries.set(key, { text: text, ranges: [] });
      return;
    }
    let prefix = 0;
    if (previous) {
      while (prefix < previous.text.length && prefix < text.length && previous.text[prefix] === text[prefix]) { prefix++; }
      // Do not cut a UTF-16 surrogate pair when replacing a suffix.
      if (prefix > 0 && /[\uD800-\uDBFF]/.test(text[prefix - 1])) { prefix--; }
    }
    const ranges: RevealRange[] = [];
    if (animate) {
      for (const range of previous?.ranges || []) {
        if (range.start < prefix && now - range.born < STREAM_REVEAL_MS) {
          ranges.push({ start: range.start, end: Math.min(prefix, range.end), born: range.born });
        }
      }
      if (text.length > prefix) { ranges.push({ start: prefix, end: text.length, born: now }); }
    }
    this.entries.set(key, { text: text, ranges: ranges });
  }

  retain(keys: string[]): void {
    this.entries.forEach((_value: RevealText, key: string) => { if (!keys.includes(key)) { this.entries.delete(key); } });
  }

  active(now: number): boolean {
    let active = false;
    this.entries.forEach((entry: RevealText) => {
      entry.ranges = entry.ranges.filter((range: RevealRange) => now - range.born < STREAM_REVEAL_MS);
      if (entry.ranges.length) { active = true; }
    });
    return active;
  }

  spans(key: string, spans: MarkdownSpan[], now: number): RevealSpan[] {
    const ranges = this.entries.get(key)?.ranges || [];
    const result: RevealSpan[] = [];
    let offset = 0;
    for (const span of spans) {
      const end = offset + span.text.length;
      let cursor = offset;
      while (cursor < end) {
        const range = ranges.find((item: RevealRange) => item.start <= cursor && item.end > cursor);
        const next = ranges.find((item: RevealRange) => item.start > cursor);
        const stop = Math.min(end, range ? range.end : next ? next.start : end);
        const progress = range ? Math.min(1, Math.max(0, (now - range.born) / STREAM_REVEAL_MS)) : 1;
        result.push({ text: span.text.slice(cursor - offset, stop - offset), kind: span.kind, url: span.url,
          opacity: 1 - 0.8 * Math.pow(1 - progress, 2) });
        cursor = stop;
      }
      offset = end;
    }
    return result;
  }
}
