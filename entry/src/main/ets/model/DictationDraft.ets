import { t } from './I18n';
import { MAX_INPUT_TEXT } from './PendingInput';

// A dictation owns only its own draft updates. External edits always win.
export class DictationDraft {
  private original: string;
  private latest: string;

  constructor(draft: string) { this.original = draft; this.latest = draft; }

  update(current: string, transcript: string): string {
    if (current !== this.latest) { throw new Error(t('草稿已修改，语音输入已停止。')); }
    const text = transcript.trim();
    const next = this.original + (text && this.original && !/\s$/.test(this.original) ? '\n' : '') + text;
    if (next.length > MAX_INPUT_TEXT) { throw new Error(t('草稿超过 24000 字符，语音输入已停止。可复制本次识别的完整文字。')); }
    this.latest = next;
    return next;
  }

  cancel(current: string): string { return current === this.latest ? this.original : current; }
}
