import { ToolFailure } from '../model/ToolFailure';
import { t } from '../model/I18n';
import { Cancellation, RunCancelledError } from './Cancellation';
import { InputForm, formResult } from '../model/RichArtifacts';

interface ApprovalWaiter { enter: () => void; }

@Observed
export class ToolApproval {
  private occupied: boolean = false;
  private waiting: ApprovalWaiter[] = [];
  title: string = '';
  details: string = '';
  private answer?: (allowed: boolean) => void;
  form?: InputForm;
  formError: string = '';
  private formAnswer?: (value: string) => void;
  private acquire(cancellation: Cancellation): Promise<void> {
    cancellation.check();
    if (!this.occupied) { this.occupied = true; return Promise.resolve(); }
    return new Promise<void>((resolve, reject) => {
      let remove = (): void => {};
      const waiter: ApprovalWaiter = { enter: () => { remove(); resolve(); } };
      this.waiting.push(waiter);
      remove = cancellation.onCancel(() => {
        this.waiting = this.waiting.filter((item) => item !== waiter);
        reject(new RunCancelledError());
      });
    });
  }
  private release(): void {
    const next = this.waiting.shift();
    if (next) { next.enter(); } else { this.occupied = false; }
  }
  async ask(form: InputForm, cancellation: Cancellation): Promise<string> {
    cancellation.check();
    if (this.occupied) { await this.acquire(cancellation); } else { this.occupied = true; }
    try {
      cancellation.check();
      const result = await new Promise<string>((resolve) => {
        let remove = (): void => {};
        this.form = form; this.formError = '';
        this.formAnswer = (value: string) => { remove(); this.formAnswer = undefined; this.form = undefined; resolve(value); };
        remove = cancellation.onCancel(() => this.cancelForm());
      });
      cancellation.check(); return result;
    } finally { this.release(); }
  }
  submit(values: string[]): void {
    if (!this.form || !this.formAnswer) { return; }
    try { const result = formResult(this.form, values); this.formAnswer(result); }
    catch (error) { this.formError = (error as Error).message; }
  }
  cancelForm(): void { if (this.formAnswer) { this.formAnswer('{"status":"cancelled"}'); } }
  async request(title: string, details: string, cancellation: Cancellation): Promise<void> {
    cancellation.check();
    if (this.occupied) { await this.acquire(cancellation); } else { this.occupied = true; }
    try {
      cancellation.check();
      const allowed = await new Promise<boolean>((resolve) => {
        let remove = (): void => {};
        this.title = title; this.details = details;
        this.answer = (value: boolean) => { remove(); this.answer = undefined; this.title = ''; this.details = ''; resolve(value); };
        remove = cancellation.onCancel(() => this.respond(false));
      });
      cancellation.check(); if (!allowed) { throw new ToolFailure('USER_DENIED', t("用户拒绝此次远程工具调用。"), 'respect_user_decision'); }
    } finally { this.release(); }
  }
  respond(allowed: boolean): void { if (this.answer) { this.answer(allowed); } }
}
