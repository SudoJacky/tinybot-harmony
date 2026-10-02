import { t } from '../model/I18n';
import { Cancellation } from './Cancellation';
import { InputForm, formResult } from '../model/RichArtifacts';

@Observed
export class ToolApproval {
  title: string = '';
  details: string = '';
  private answer?: (allowed: boolean) => void;
  form?: InputForm;
  formError: string = '';
  private formAnswer?: (value: string) => void;
  async ask(form: InputForm, cancellation: Cancellation): Promise<string> {
    cancellation.check();
    if (this.formAnswer || this.answer) { throw new Error(t("已有待处理提问。")); }
    const result = await new Promise<string>((resolve) => {
      let remove = (): void => {};
      this.form = form; this.formError = '';
      this.formAnswer = (value: string) => { remove(); this.formAnswer = undefined; this.form = undefined; resolve(value); };
      remove = cancellation.onCancel(() => this.cancelForm());
    });
    cancellation.check(); return result;
  }
  submit(values: string[]): void {
    if (!this.form || !this.formAnswer) { return; }
    try { const result = formResult(this.form, values); this.formAnswer(result); }
    catch (error) { this.formError = (error as Error).message; }
  }
  cancelForm(): void { if (this.formAnswer) { this.formAnswer('{"status":"cancelled"}'); } }
  async request(title: string, details: string, cancellation: Cancellation): Promise<void> {
    cancellation.check();
    if (this.answer) { throw new Error(t("已有一个工具等待确认。")); }
    const allowed = await new Promise<boolean>((resolve) => {
      let remove = (): void => {};
      this.title = title; this.details = details;
      this.answer = (value: boolean) => { remove(); this.answer = undefined; this.title = ''; this.details = ''; resolve(value); };
      remove = cancellation.onCancel(() => this.respond(false));
    });
    cancellation.check(); if (!allowed) { throw new Error(t("用户拒绝此次远程工具调用。")); }
  }
  respond(allowed: boolean): void { if (this.answer) { this.answer(allowed); } }
}
