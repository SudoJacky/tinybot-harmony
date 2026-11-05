// IMAP framing is byte based: strings here contain one code unit per wire byte.
// A literal may contain CRLF, parentheses and fake tagged responses; never split it as lines.
export interface ImapFrame { text: string; literals: string[]; }
export class ImapFramer {
  private buffer: string = '';
  private text: string = '';
  private literals: string[] = [];
  private remaining: number = -1;
  private bytes: number = 0;
  push(chunk: string): ImapFrame[] {
    this.bytes += chunk.length;
    if (this.bytes > 2 * 1024 * 1024) { throw new Error('IMAP response exceeds 2 MiB'); }
    this.buffer += chunk; const result: ImapFrame[] = [];
    while (true) {
      if (this.remaining >= 0) {
        if (this.buffer.length < this.remaining) { break; }
        this.literals.push(this.buffer.slice(0, this.remaining)); this.buffer = this.buffer.slice(this.remaining); this.remaining = -1;
      }
      const end = this.buffer.indexOf('\r\n'); if (end < 0) { break; }
      const line = this.buffer.slice(0, end); this.buffer = this.buffer.slice(end + 2);
      const literal = /\{(\d+)\+?\}$/.exec(line);
      if (literal) {
        const count = Number(literal[1]); if (count > 512 * 1024) { throw new Error('IMAP literal exceeds 512 KiB'); }
        this.text += line.slice(0, literal.index) + '@literal' + this.literals.length; this.remaining = count;
      } else {
        result.push({ text: this.text + line, literals: this.literals }); this.text = ''; this.literals = [];
      }
    }
    return result;
  }
}
export function imapQuote(value: string): string {
  if (/[\u0000-\u001f\u007f]/.test(value)) { throw new Error('IMAP command contains control characters'); }
  return '"' + value.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
}
export function imapNumber(value: number): number {
  if (!Number.isInteger(value) || value < 1 || value > 4294967295) { throw new Error('Invalid IMAP UID or UIDVALIDITY'); } return value;
}
export function imapSearch(frames: ImapFrame[]): number[] {
  const result: number[] = [];
  for (const frame of frames) {
    if (!/^\* SEARCH(?: |$)/i.test(frame.text)) { continue; }
    const text = frame.text.slice(8).trim();
    if (text) { text.split(/ +/).forEach((part: string) => result.push(imapNumber(Number(part)))); }
  }
  return Array.from(new Set(result)).sort((a: number, b: number) => a - b);
}
