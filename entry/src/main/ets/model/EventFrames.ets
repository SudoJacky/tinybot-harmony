// Scan each incoming chunk once. Keep only the unfinished line across callbacks.
export class EventFrames {
  private fragments: string[] = [];
  private lines: string[] = [];
  private receive: (payload: string) => void;
  constructor(receive: (payload: string) => void) { this.receive = receive; }

  push(text: string): void {
    let start = 0;
    let end = text.indexOf('\n');
    while (end >= 0) {
      let line = text.slice(start, end);
      if (this.fragments.length) {
        this.fragments.push(line); line = this.fragments.join(''); this.fragments = [];
      }
      if (line.endsWith('\r')) { line = line.slice(0, -1); }
      if (!line && this.lines.length) {
        const payload = this.lines.length === 1 ? this.lines[0] : this.lines.join('\n');
        this.lines = []; this.receive(payload);
      } else if (line.startsWith('data:')) {
        this.lines.push(line.slice(line.startsWith('data: ') ? 6 : 5));
      }
      start = end + 1;
      end = text.indexOf('\n', start);
    }
    if (start < text.length) { this.fragments.push(text.slice(start)); }
  }

  get incomplete(): boolean { return this.lines.length > 0 || this.fragments.join('').trim().length > 0; }
}
