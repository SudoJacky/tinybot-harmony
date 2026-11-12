import { ToolFailure } from '../model/ToolFailure';
import { t } from '../model/I18n';
import { Cancellation, RunCancelledError } from './Cancellation';
import { InputForm, formResult } from '../model/RichArtifacts';
import { TaskApproval } from '../model/NearbyTask';

interface ApprovalWaiter { enter: () => void; }

@Observed
export class ToolApproval {
  private owner?: ToolApproval;
  private scope: string;
  private sequence: number = 0;
  private current?: TaskApproval;
  private observers: Set<() => void> = new Set();
  constructor(owner?: ToolApproval, scope: string = '') { this.owner = owner; this.scope = scope; }
  scoped(threadId: string): ToolApproval { return new ToolApproval(this.owner || this, threadId); }
  subscribe(observer: () => void): () => void { this.observers.add(observer); return () => { this.observers.delete(observer); }; }
  snapshot(threadId: string): TaskApproval | undefined {
    return this.current?.threadId === threadId ? JSON.parse(JSON.stringify(this.current)) as TaskApproval : undefined;
  }
  private changed(): void { for (const observer of this.observers) { observer(); } }
  resolveRemote(threadId: string, id: string, allowed?: boolean, values?: string[]): void {
    if (!this.current || this.current.id !== id || this.current.threadId !== threadId) {
      throw new Error(t('这项请求已在其他设备处理，请刷新任务状态。'));
    }
    if (this.form) {
      if (allowed === false) { this.cancelForm(); }
      else {
        if (!Array.isArray(values) || values.some((value) => typeof value !== 'string')) { throw new Error('Invalid form response'); }
        const result = formResult(this.form, values);
        this.formAnswer!(result);
      }
    } else {
      if (typeof allowed !== 'boolean') { throw new Error('Invalid approval response'); }
      this.respond(allowed);
    }
  }
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
  async ask(form: InputForm, cancellation: Cancellation, threadId: string = ''): Promise<string> {
    if (this.owner) { return this.owner.ask(form, cancellation, this.scope); }
    cancellation.check();
    if (this.occupied) { await this.acquire(cancellation); } else { this.occupied = true; }
    try {
      cancellation.check();
      const result = await new Promise<string>((resolve) => {
        let remove = (): void => {};
        this.form = form; this.formError = '';
        this.current = { id: Date.now() + '-' + ++this.sequence, threadId: threadId, title: form.title, details: '', form: form };
        this.formAnswer = (value: string) => { remove(); this.formAnswer = undefined; this.form = undefined; this.current = undefined; this.changed(); resolve(value); };
        remove = cancellation.onCancel(() => this.cancelForm());
        this.changed();
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
  async request(title: string, details: string, cancellation: Cancellation, threadId: string = ''): Promise<void> {
    if (this.owner) { return this.owner.request(title, details, cancellation, this.scope); }
    cancellation.check();
    if (this.occupied) { await this.acquire(cancellation); } else { this.occupied = true; }
    try {
      cancellation.check();
      const allowed = await new Promise<boolean>((resolve) => {
        let remove = (): void => {};
        this.title = title; this.details = details;
        this.current = { id: Date.now() + '-' + ++this.sequence, threadId: threadId, title: title, details: details };
        this.answer = (value: boolean) => { remove(); this.answer = undefined; this.title = ''; this.details = ''; this.current = undefined; this.changed(); resolve(value); };
        remove = cancellation.onCancel(() => this.respond(false));
        this.changed();
      });
      cancellation.check(); if (!allowed) { throw new ToolFailure('USER_DENIED', t('用户拒绝此次工具调用。'), 'respect_user_decision'); }
    } finally { this.release(); }
  }
  respond(allowed: boolean): void { if (this.answer) { this.answer(allowed); } }
}
