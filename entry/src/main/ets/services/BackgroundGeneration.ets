import { common, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { Diagnostics } from '../model/Diagnostics';
import { t } from '../model/I18n';
import { SessionService } from './SessionService';
import { Cancellation, RunCancelledError } from './Cancellation';
import { EndNetworkTransfer, NetworkTransfers } from './NetworkTransfers';

interface GenerationTask {
  id: number; context: common.UIAbilityContext; cancelled: boolean; releaseError?: Error;
}

// NotificationTemplate only documents percentage progress. An unknown-length SSE request
// cannot truthfully update that percentage. End its background window before the documented
// ten-minute first-progress limit, without fake progress, renewal or automatic request replay.
const BACKGROUND_TRANSFER_WINDOW_MS: number = 9 * 60 * 1000;

export class BackgroundGeneration {
  private session?: SessionService;
  private context?: common.UIAbilityContext;
  private unsubscribe?: () => void;
  private unobserveTransfers?: () => void;
  private foreground: boolean = false;
  private active: boolean = false;
  private sequence: number = 0;
  private transfers: Map<number, Cancellation> = new Map<number, Cancellation>();
  private task?: GenerationTask;
  private turnTaskIds: Set<number> = new Set<number>();
  private pending: Promise<void> = Promise.resolve();
  private starting: boolean = false;
  private pendingCancels: Map<number, number> = new Map<number, number>();
  private pendingSuspends: Map<number, number> = new Map<number, number>();
  private observing: boolean = false;
  private blockedReason: string = '';
  private stopping: boolean = false;
  private deadline?: number;

  private cancelled = (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
    if (this.task?.id !== info.id) {
      if (this.turnTaskIds.has(info.id)) { this.onCancelled(info.reason); return; }
      if (this.starting) { this.pendingCancels.set(info.id, info.reason); }
      return;
    }
    this.task.cancelled = true;
    this.onCancelled(info.reason);
  };
  private suspended = (info: backgroundTaskManager.ContinuousTaskSuspendInfo): void => {
    if (!info.suspendState) { return; }
    if (this.task?.id !== info.continuousTaskId) {
      if (this.turnTaskIds.has(info.continuousTaskId)) {
        Diagnostics.log('warn', 'background', 'suspended', { code: info.suspendReason });
        this.block(t('后台执行已被系统或用户中止，本轮已停止。请回到应用后重试。'));
        this.reconcileLifecycle(); return;
      }
      if (this.starting) { this.pendingSuspends.set(info.continuousTaskId, info.suspendReason); }
      return;
    }
    Diagnostics.log('warn', 'background', 'suspended', { code: info.suspendReason });
    this.block(t('后台执行已被系统或用户中止，本轮已停止。请回到应用后重试。'));
    this.reconcileLifecycle();
  };

  attach(session: SessionService, context: common.UIAbilityContext): void {
    this.dispose(); this.session = session; this.context = context;
    this.unsubscribe = session.subscribe((event) => this.update(session.hasActiveRuns));
    this.unobserveTransfers = NetworkTransfers.observe((cancellation) => this.beginTransfer(cancellation));
    this.update(session.hasActiveRuns);
  }

  setForeground(foreground: boolean): void {
    if (this.foreground === foreground) { return; }
    this.foreground = foreground;
    // Retrying cleanup is safe; foregrounding never clears a cancellation/admission block.
    if (foreground && this.task) { this.task.releaseError = undefined; }
    this.reconcileLifecycle();
  }

  // Called by user generation/compaction preparation, never by provider retries or lifecycle callbacks.
  async beginTurn(): Promise<void> {
    if (this.foreground) {
      if (this.task) { this.task.releaseError = undefined; }
      await this.reconcile();
      this.turnTaskIds.clear();
      this.blockedReason = '';
    }
    if (this.blockedReason) { throw new RunCancelledError(this.blockedReason); }
  }

  dispose(): void {
    this.unsubscribe?.(); this.unsubscribe = undefined;
    this.unobserveTransfers?.(); this.unobserveTransfers = undefined;
    this.session = undefined; this.context = undefined; this.active = false;
    for (const cancellation of Array.from(this.transfers.values())) { cancellation.cancel(); }
    this.transfers.clear(); this.clearDeadline();
    this.reconcileLifecycle();
  }

  private update(active: boolean): void {
    if (active === this.active) { return; }
    this.active = active;
    // Session activity only authorizes request scopes. It never creates a background task.
    if (!active) {
      for (const cancellation of Array.from(this.transfers.values())) { cancellation.cancel(); }
      this.reconcileLifecycle();
    }
  }

  private async beginTransfer(cancellation: Cancellation): Promise<EndNetworkTransfer> {
    if (!this.active) { return async (): Promise<void> => {}; }
    if (this.blockedReason) { throw new RunCancelledError(this.blockedReason); }
    const id = ++this.sequence;
    this.transfers.set(id, cancellation);
    try {
      await this.reconcile(); cancellation.check();
      if (this.blockedReason) { throw new RunCancelledError(this.blockedReason); }
    } catch (error) {
      this.transfers.delete(id);
      this.block(this.blockedReason || t('未能启动后台任务，本轮已停止。请保持应用在前台后重试。'));
      this.reconcileLifecycle();
      throw new RunCancelledError(this.blockedReason);
    }
    let ended = false;
    return async (): Promise<void> => {
      if (ended) { return; } ended = true;
      this.transfers.delete(id);
      await this.reconcile();
    };
  }

  private get wanted(): boolean {
    return !!this.session && !this.foreground && this.active && this.transfers.size > 0 && !this.blockedReason;
  }

  private reconcile(): Promise<void> {
    const operation = this.pending.then(() => this.syncTask());
    // Preserve the rejection for the caller and the failed task for later cleanup.
    // A drained queue is not evidence that a failed native stop succeeded.
    this.pending = operation.catch((error: Error) => Diagnostics.log('error', 'background', 'transition_failed', undefined, error));
    return operation;
  }

  private reconcileLifecycle(): void {
    this.reconcile().catch(() => {
      this.block(this.blockedReason || t('未能启动后台任务，本轮已停止。请保持应用在前台后重试。'));
    });
  }

  private async syncTask(): Promise<void> {
    if (this.task?.cancelled) { this.task = undefined; this.clearDeadline(); }
    if (this.task?.releaseError) { throw this.task.releaseError; }
    if (this.task && !this.wanted) { await this.releaseTask(this.task); }
    if (this.wanted && !this.task) { await this.acquire(); }
    if (!this.session && !this.task && this.observing) {
      backgroundTaskManager.off('continuousTaskCancel', this.cancelled);
      backgroundTaskManager.off('continuousTaskSuspend', this.suspended);
      this.observing = false;
    }
  }

  private async acquire(): Promise<void> {
    const context = this.context;
    if (!context) { throw new Error('Background generation has no ability context'); }
    if (!this.observing) {
      backgroundTaskManager.on('continuousTaskCancel', this.cancelled);
      try { backgroundTaskManager.on('continuousTaskSuspend', this.suspended); }
      catch (error) { backgroundTaskManager.off('continuousTaskCancel', this.cancelled); throw error as Error; }
      this.observing = true;
    }
    const agent = await wantAgent.getWantAgent({
      wants: [{ bundleName: context.abilityInfo.bundleName, abilityName: context.abilityInfo.name }],
      actionType: wantAgent.OperationType.START_ABILITY, requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    });
    if (!this.wanted) { return; }
    this.starting = true;
    try {
      const result = await backgroundTaskManager.startBackgroundRunning(context, ['dataTransfer'], agent);
      if (result.continuousTaskId === undefined) { throw new Error('Background task returned no continuousTaskId'); }
      const task: GenerationTask = { id: result.continuousTaskId, context: context, cancelled: false };
      this.task = task;
      this.turnTaskIds.add(task.id);
      const cancelled = this.pendingCancels.get(task.id);
      const suspended = this.pendingSuspends.get(task.id);
      if (cancelled !== undefined) { task.cancelled = true; this.onCancelled(cancelled); }
      else if (suspended !== undefined) {
        Diagnostics.log('warn', 'background', 'suspended', { code: suspended });
        this.block(t('后台执行已被系统或用户中止，本轮已停止。请回到应用后重试。'));
      }
      Diagnostics.log('info', 'background', 'acquired', { count: this.transfers.size });
      if (task.cancelled) { this.task = undefined; }
      else if (!this.wanted) { await this.releaseTask(task); }
      else {
        this.deadline = setTimeout(() => {
          this.deadline = undefined;
          Diagnostics.log('warn', 'background', 'window_expired', { elapsedMs: BACKGROUND_TRANSFER_WINDOW_MS });
          this.block(t('后台流式传输已达到本次运行时限，本轮已停止。请回到应用后重试。'));
          this.reconcileLifecycle();
        }, BACKGROUND_TRANSFER_WINDOW_MS);
      }
    } finally { this.starting = false; this.pendingCancels.clear(); this.pendingSuspends.clear(); }
  }

  private onCancelled(code: number): void {
    this.clearDeadline();
    Diagnostics.log('warn', 'background', 'cancelled', { code: code });
    this.block(t('后台执行已被系统或用户中止，本轮已停止。请回到应用后重试。'));
    this.reconcileLifecycle();
  }

  private async releaseTask(task: GenerationTask): Promise<void> {
    this.clearDeadline();
    try {
      // Keep task identity throughout this await so cancellation during release is observed.
      await backgroundTaskManager.stopBackgroundRunning(task.context);
      if (this.task === task) { this.task = undefined; }
      Diagnostics.log('info', 'background', 'released');
    } catch (error) {
      if (task.cancelled) { if (this.task === task) { this.task = undefined; } return; }
      task.releaseError = error as Error;
      Diagnostics.log('error', 'background', 'release_failed', undefined, error as Error);
      this.block(t('后台任务释放失败，本轮已停止。请回到应用后重试。'));
      throw error as Error;
    }
  }

  private clearDeadline(): void {
    if (this.deadline !== undefined) { clearTimeout(this.deadline); this.deadline = undefined; }
  }

  private block(reason: string): void {
    if (!this.blockedReason) { this.blockedReason = reason; }
    const session = this.session;
    if (session && this.active && !this.stopping) {
      this.stopping = true;
      session.stopAll(this.blockedReason).then(() => session.waitForIdle())
        .catch((error: Error) => Diagnostics.log('error', 'background', 'stop_failed', undefined, error))
        .finally(() => { this.stopping = false; });
    }
    // Title generation and child requests may have their own signals, outside runtime.abort().
    for (const cancellation of Array.from(this.transfers.values())) { cancellation.cancel(); }
  }
}

export const backgroundGeneration = new BackgroundGeneration();
