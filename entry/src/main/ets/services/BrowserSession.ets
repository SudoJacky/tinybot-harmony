import { LogFields } from '../model/DiagnosticLog';
import { BrowserPolicy } from '../model/Skills';
import { ToolCall } from '../model/Agent';
import { ToolFailure, ToolResultError } from '../model/ToolFailure';
import { ExecutionGate } from './AgentLoop';
import { Cancellation, RunCancelledError } from './Cancellation';

export interface BrowserElement { id: number; role: string; label: string; type: string; value?: string; }
export interface BrowserPage {
  snapshotId: string; url: string; title: string; text: string; elements: BrowserElement[];
  truncated: boolean; embeddedFrames: number; trust: string;
}
export interface BrowserAction { action: string; snapshotId?: string; elementId?: number; text?: string; deltaY?: number; }
export interface BrowserDriver {
  open(url: string): Promise<void>;
  snapshot(id: string): Promise<BrowserPage>;
  act(action: BrowserAction): Promise<void>;
  userBack(): boolean;
  close(): void;
}
export interface BrowserReceipt { operation: string; completed: boolean; userIntervened: boolean; page?: BrowserPage; browserClosed?: boolean; }

// Owns permission, control and the runtime wait point. Viewing never transfers control.
@Observed
export class BrowserSession implements ExecutionGate {
  policy: BrowserPolicy = 'unset';
  open: boolean = false;
  owner: string = 'none';
  url: string = '';
  title: string = '';
  canGoBack: boolean = false;
  canGoForward: boolean = false;
  editingAddress: boolean = false;
  error: string = '';
  handoffReason: string = '';
  permissionReason: string = '';
  permissionUrl: string = '';
  permissionPending: boolean = false;
  permissionSaving: boolean = false;
  private driver?: BrowserDriver;
  private savePolicy?: (policy: BrowserPolicy) => Promise<void>;
  private log: (event: string, fields?: LogFields, error?: Error | string) => void = () => {};
  private lease?: Cancellation;
  private threadId: string = '';
  private removeCancellation: () => void = () => {};
  private permissionAnswer?: (allowed: boolean) => void;
  private waiters: Set<() => void> = new Set<() => void>();
  private epoch: number = 0;
  private sequence: number = 0;
  private operating: boolean = false;
  private issuedOperation?: Promise<void>;

  get paused(): boolean { return this.permissionPending || (!!this.lease && this.owner === 'user'); }
  get hasTask(): boolean { return this.lease !== undefined; }
  configure(savePolicy: (policy: BrowserPolicy) => Promise<void>, log: (event: string, fields?: LogFields, error?: Error | string) => void): void {
    this.savePolicy = savePolicy; this.log = log;
  }
  attach(driver: BrowserDriver): void {
    if (this.driver && this.driver !== driver) { throw new Error('Browser driver is already attached.'); }
    this.driver = driver;
  }
  detach(driver: BrowserDriver): void {
    if (this.driver !== driver) { return; }
    this.close(); this.driver = undefined;
  }
  updatePolicy(policy: BrowserPolicy): void {
    this.policy = policy;
    if (policy === 'disabled') { this.close(); }
    if (policy !== 'unset') { this.answerPermission(policy === 'enabled'); }
  }
  async setEnabled(enabled: boolean): Promise<void> {
    if (!this.savePolicy || this.permissionSaving) { throw new Error('Browser permission save is unavailable or already in progress.'); }
    if (!enabled) { this.takeOver(''); }
    this.permissionSaving = true; this.error = '';
    try {
      const policy: BrowserPolicy = enabled ? 'enabled' : 'disabled';
      await this.savePolicy(policy);
      this.updatePolicy(policy);
      this.log('permission', { policy: policy });
    } catch (error) { this.report((error as Error).message); throw error as Error; }
    finally { this.permissionSaving = false; }
  }
  private answerPermission(allowed: boolean): void {
    const answer = this.permissionAnswer;
    this.permissionAnswer = undefined; this.permissionPending = false;
    this.permissionReason = ''; this.permissionUrl = '';
    answer?.(allowed); this.wake();
  }
  cancelPermission(): void { this.answerPermission(false); }
  async wait(cancellation: Cancellation): Promise<void> {
    cancellation.check();
    while (this.paused) {
      await new Promise<void>((resolve) => {
        let remove = (): void => {};
        const finish = (): void => { this.waiters.delete(finish); remove(); resolve(); };
        this.waiters.add(finish);
        remove = cancellation.onCancel(finish);
        if (!this.paused) { finish(); }
      });
      cancellation.check();
    }
  }
  private wake(): void { for (const finish of Array.from(this.waiters)) { finish(); } }
  takeOver(reason: string = ''): void {
    if (!this.open || this.owner === 'user') { return; }
    this.owner = 'user'; this.epoch++; this.handoffReason = reason;
    this.log('control_user', { generation: this.epoch, enabled: this.hasTask });
  }
  handoff(): void {
    if (!this.open || !this.lease || this.policy !== 'enabled') { return; }
    this.owner = 'agent'; this.handoffReason = ''; this.epoch++;
    this.log('control_agent', { generation: this.epoch }); this.wake();
  }
  release(cancellation: Cancellation): void {
    if (this.lease !== cancellation) { return; }
    this.removeCancellation(); this.removeCancellation = () => {};
    this.lease = undefined; this.threadId = ''; this.epoch++;
    if (this.open) { this.owner = 'user'; }
    this.answerPermission(false); this.handoffReason = ''; this.wake();
    this.log('task_released', { generation: this.epoch });
  }
  close(): void {
    this.epoch++; this.open = false; this.owner = 'none'; this.handoffReason = ''; this.editingAddress = false;
    this.driver?.close(); this.wake(); this.log('closed', { generation: this.epoch });
  }
  openForUser(): void {
    if (this.policy !== 'enabled') {
      throw new ToolFailure('PERMISSION_DENIED', 'Enable the in-app browser before opening it.', 'respect_user_decision');
    }
    this.requireDriver();
    // Reopening the viewer must preserve the page and the agent's control.
    if (this.open) { return; }
    this.url = ''; this.title = ''; this.error = ''; this.handoffReason = ''; this.editingAddress = false;
    this.canGoBack = false; this.canGoForward = false;
    this.open = true; this.owner = 'user'; this.epoch++;
    this.log('opened_by_user', { generation: this.epoch, enabled: this.hasTask });
  }
  async pauseForAnnotation(): Promise<void> {
    this.requireOpen(); this.takeOver();
    const epoch = this.epoch;
    // An already issued click may still navigate. Capture only after that action drains.
    await this.issuedOperation;
    this.requireOpen();
    if (this.owner !== 'user' || epoch !== this.epoch) {
      throw new ToolFailure('STALE_BROWSER_SNAPSHOT', 'Browser control changed before annotation capture.', 'inspect_browser');
    }
    this.log('annotation_started', { generation: epoch });
  }
  report(message: string): void { this.error = message; this.log('failed', undefined, message); }
  pageChanged(url: string, title: string): void { this.url = url === 'about:blank' ? '' : url; this.title = title; }
  userBack(): boolean { return this.requireDriver().userBack(); }
  private requireDriver(): BrowserDriver {
    if (!this.driver) { throw new ToolFailure('BROWSER_UNAVAILABLE', 'Browser view is not attached.', 'inspect_error'); }
    return this.driver;
  }
  private requireOpen(): void {
    if (!this.open || this.policy !== 'enabled') {
      throw new ToolFailure('BROWSER_CLOSED', 'Browser was closed or disabled. Any operation already issued may have completed; do not repeat it automatically.', 'respect_user_decision');
    }
  }
  private requireOwned(cancellation: Cancellation): void {
    this.requireOpen();
    if (this.lease !== cancellation || this.owner !== 'agent') {
      throw new ToolFailure('BROWSER_NOT_OWNED', 'Call browser_open to acquire the browser before using it.', 'acquire_browser');
    }
  }
  async acquire(threadId: string, url: string, reason: string, cancellation: Cancellation): Promise<BrowserReceipt> {
    await this.wait(cancellation);
    if (this.policy === 'disabled') { throw new ToolFailure('PERMISSION_DENIED', 'User disabled the in-app browser. Do not ask again; it can be enabled in Settings.', 'respect_user_decision'); }
    if (this.lease && this.lease !== cancellation) {
      throw new ToolFailure('BROWSER_BUSY', 'Another agent task owns the browser.', 'wait_for_owner');
    }
    if (!this.lease) {
      this.lease = cancellation; this.threadId = threadId;
      this.log('acquired', { threadId: this.threadId });
      this.removeCancellation = cancellation.onCancel(() => this.release(cancellation));
    }
    if (this.open && this.owner === 'user') { await this.wait(cancellation); }
    if (this.policy === 'unset') {
      this.permissionPending = true; this.permissionReason = reason; this.permissionUrl = url;
      this.log('permission_wait');
      const allowed = await new Promise<boolean>((resolve) => { this.permissionAnswer = resolve; });
      cancellation.check();
      if (!allowed) { throw new ToolFailure('USER_DENIED', 'Browser enable request was declined or dismissed.', 'respect_user_decision'); }
    }
    cancellation.check();
    if (this.policy !== 'enabled') { throw new ToolFailure('PERMISSION_DENIED', 'Browser is disabled.', 'respect_user_decision'); }
    this.open = true; this.owner = 'agent'; this.url = url; this.error = ''; this.epoch++;
    return this.perform('open', () => this.requireDriver().open(url), cancellation);
  }
  async snapshot(cancellation: Cancellation): Promise<BrowserPage> {
    while (true) {
      await this.wait(cancellation); this.requireOwned(cancellation);
      const epoch = this.epoch;
      const page = await this.requireDriver().snapshot(String(++this.sequence) + '-' + epoch);
      cancellation.check();
      if (epoch !== this.epoch || this.paused) { continue; }
      this.pageChanged(page.url, page.title); return page;
    }
  }
  async act(action: BrowserAction, cancellation: Cancellation): Promise<BrowserReceipt> {
    await this.wait(cancellation); this.requireOwned(cancellation);
    if (['click', 'type', 'select'].includes(action.action) && !action.snapshotId?.endsWith('-' + this.epoch)) {
      throw new ToolFailure('STALE_BROWSER_SNAPSHOT', 'Browser ownership changed. Read a new snapshot before acting.', 'read_browser_snapshot');
    }
    return this.perform(action.action, () => this.requireDriver().act(action), cancellation);
  }
  private async perform(operation: string, execute: () => Promise<void>, cancellation: Cancellation): Promise<BrowserReceipt> {
    if (this.operating) { throw new ToolFailure('BROWSER_BUSY', 'A browser operation is still in progress.', 'wait_for_owner'); }
    const epoch = this.epoch; this.operating = true;
    this.log('operation', { action: operation, generation: epoch });
    try {
      let failure: Error | undefined;
      try { this.issuedOperation = execute(); await this.issuedOperation; }
      catch (error) { failure = error as Error; }
      finally { this.issuedOperation = undefined; }
      // Never abort an issued action on takeover. Hold both success and failure until handoff.
      if (!cancellation.cancelled) {
        try { await this.wait(cancellation); }
        catch (error) { if (!(error instanceof RunCancelledError && cancellation.cancelled)) { throw error as Error; } }
      }
      if (failure) {
        // A changed observation is returned to the model for a fresh read, not a page-loading error.
        if (failure instanceof ToolFailure && ['STALE_BROWSER_SNAPSHOT', 'STALE_BROWSER_ELEMENT'].includes(failure.code)) {
          this.log('observation_changed', undefined, failure);
        } else { this.report(failure.message); }
        throw failure;
      }
      if (cancellation.cancelled) { return { operation: operation, completed: true, userIntervened: epoch !== this.epoch }; }
      try {
        this.requireOpen();
        const page = await this.snapshot(cancellation);
        return { operation: operation, completed: true, userIntervened: epoch !== this.epoch, page: page };
      } catch (error) {
        // Observation can fail after a successful click. Keep that committed fact in the failure receipt.
        if (cancellation.cancelled) { return { operation: operation, completed: true, userIntervened: epoch !== this.epoch }; }
        const failure = error as Error;
        this.report(failure.message);
        throw new ToolResultError(JSON.stringify({ operation: operation, completed: true, userIntervened: epoch !== this.epoch, error: failure.message }),
          failure instanceof ToolFailure ? failure.code : 'BROWSER_OBSERVATION_FAILED', 'inspect_browser_before_retry');
      }
    } finally { this.operating = false; }
  }
  async requestHandoff(reason: string, cancellation: Cancellation): Promise<BrowserPage> {
    this.requireOwned(cancellation); this.takeOver(reason); await this.wait(cancellation);
    return this.snapshot(cancellation);
  }
  async closeForTask(cancellation: Cancellation): Promise<void> {
    await this.wait(cancellation); this.requireOwned(cancellation); this.close();
  }
  async refreshResult(call: ToolCall, output: string, cancellation: Cancellation): Promise<string> {
    if (!call.function.name.startsWith('browser_') || call.function.name === 'browser_close') { return output; }
    await this.wait(cancellation);
    const receipt = JSON.parse(output) as BrowserReceipt;
    if (!receipt.page || receipt.page.snapshotId.endsWith('-' + this.epoch)) { return output; }
    receipt.userIntervened = true;
    if (!this.open) { receipt.page = undefined; receipt.browserClosed = true; }
    else if (this.lease === cancellation) {
      try { receipt.page = await this.snapshot(cancellation); }
      catch (error) {
        if (cancellation.cancelled) { return output; } // Keep the completed receipt when its later observation is stopped.
        receipt.page = undefined;
        throw new ToolResultError(JSON.stringify({ operation: receipt.operation, completed: receipt.completed, userIntervened: true, error: (error as Error).message }),
          'BROWSER_OBSERVATION_FAILED', 'read_browser_snapshot');
      }
    }
    return JSON.stringify(receipt);
  }
}
