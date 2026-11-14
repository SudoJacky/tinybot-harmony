import { Diagnostics } from '../model/Diagnostics';
import { CONTENT_GUARD_REFUSAL } from '../model/ContentGuard';

// Hold the answer prefix while it may still be the fixed refusal.
export class ContentGuardStream {
  private text: string = '';
  private open: boolean = false;
  private onText: (text: string) => void;

  constructor(onText: (text: string) => void) {
    this.onText = onText;
  }

  pushText(text: string): void {
    if (this.open) { this.onText(text); return; }
    this.text += text;
    const candidate = this.text.trim();
    if (!CONTENT_GUARD_REFUSAL.startsWith(candidate)) { this.release(); }
  }

  finish(answer: string): boolean {
    if (answer.trim() === CONTENT_GUARD_REFUSAL) {
      Diagnostics.log('warn', 'moderation', 'guard_stopped');
      return true;
    }
    if (!this.open) { this.release(); }
    return false;
  }

  private release(): void {
    this.open = true;
    if (this.text) { this.onText(this.text); this.text = ''; }
  }
}
