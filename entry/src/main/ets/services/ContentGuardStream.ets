import { Diagnostics } from '../model/Diagnostics';
import { CONTENT_GUARD_REFUSAL } from '../model/ContentGuard';

// Hold the prefix and reasoning while the model may be producing a refusal.
export class ContentGuardStream {
  private text: string = '';
  private reasoning: string = '';
  private open: boolean = false;
  private onText: (text: string) => void;
  private onReasoning?: (text: string) => void;
  private onReasoningStart?: () => void;

  constructor(onText: (text: string) => void, onReasoning?: (text: string) => void, onReasoningStart?: () => void) {
    this.onText = onText;
    this.onReasoning = onReasoning;
    this.onReasoningStart = onReasoningStart;
  }

  pushText(text: string): void {
    if (this.open) { this.onText(text); return; }
    this.text += text;
    const candidate = this.text.trim();
    if (!CONTENT_GUARD_REFUSAL.startsWith(candidate)) { this.release(); }
  }

  pushReasoning(text: string): void {
    if (this.open) { this.onReasoning?.(text); }
    else {
      if (this.onReasoningStart && text.trim()) {
        const started = this.onReasoningStart;
        this.onReasoningStart = undefined;
        started();
      }
      if (this.onReasoning) { this.reasoning += text; }
    }
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
    if (this.reasoning) { this.onReasoning?.(this.reasoning); this.reasoning = ''; }
    if (this.text) { this.onText(this.text); this.text = ''; }
  }
}
