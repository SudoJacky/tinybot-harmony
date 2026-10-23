import { common, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { Diagnostics } from '../model/Diagnostics';
import { t } from '../model/I18n';
import { SessionService } from './SessionService';
import { SessionPhase } from './SessionContracts';

interface GenerationTask { id: number; context: common.UIAbilityContext; }

// The lease belongs to the whole turn, including tools, compaction and retries.
// Phones require the KEEP_BACKGROUND_RUNNING_SYSTEM ACL for taskKeeping.
export class BackgroundGeneration {
  private session?: SessionService;
  private context?: common.UIAbilityContext;
  private unsubscribe?: () => void;
  private foreground: boolean = false;
  private active: boolean = false;
  private generation: number = 0;
  private task?: GenerationTask;
  private acquiring?: Promise<void>;
  private cancelObserved: boolean = false;
  private suspendObserved: boolean = false;
  private stopping: boolean = false;
  private cancelled = (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
    if (this.task?.id !== info.id) { return; }
    this.task = undefined;
    Diagnostics.log('warn', 'background', 'cancelled', { code: info.reason });
    this.interrupt(t('后台执行已被系统或用户中止，本轮已停止。请回到应用后重试。'));
  };
  private suspended = (info: backgroundTaskManager.ContinuousTaskSuspendInfo): void => {
    if (this.task?.id !== info.continuousTaskId || !info.suspendState) { return; }
    Diagnostics.log('warn', 'background', 'suspended', { code: info.suspendReason });
    this.interrupt(t('后台执行已被系统或用户中止，本轮已停止。请回到应用后重试。'));
  };

  attach(session: SessionService, context: common.UIAbilityContext): void {
    this.dispose(); this.session = session; this.context = context;
    this.unsubscribe = session.subscribe((event) => this.update(event.state.phase));
    this.update(session.state.phase);
  }

  setForeground(foreground: boolean): void {
    this.foreground = foreground;
    if (!foreground && this.active && !this.task && !this.acquiring) {
      this.interrupt(t('未获得长时后台执行权限，本轮已停止。请保持应用在前台后重试。'));
    }
  }

  async waitForReady(): Promise<void> {
    await this.acquiring;
    if (!this.foreground && !this.task) {
      throw new Error(t('未获得长时后台执行权限，本轮已停止。请保持应用在前台后重试。'));
    }
  }

  dispose(): void {
    this.generation++;
    this.unsubscribe?.(); this.unsubscribe = undefined;
    this.session = undefined; this.context = undefined; this.active = false; this.stopping = false;
    this.release();
    if (this.cancelObserved) {
      this.cancelObserved = false;
      try { backgroundTaskManager.off('continuousTaskCancel', this.cancelled); }
      catch (error) { Diagnostics.log('error', 'background', 'observe_failed', undefined, error as Error); }
    }
    if (this.suspendObserved) {
      this.suspendObserved = false;
      try { backgroundTaskManager.off('continuousTaskSuspend', this.suspended); }
      catch (error) { Diagnostics.log('error', 'background', 'observe_failed', undefined, error as Error); }
    }
  }

  private update(phase: SessionPhase): void {
    const active = phase === 'running' || phase === 'compacting';
    if (active === this.active) { return; }
    this.active = active;
    const generation = ++this.generation;
    if (!active) { this.release(); return; }
    const context = this.context;
    if (!context) { throw new Error('Background generation has no ability context'); }
    const acquiring = this.acquire(context, generation).catch((error: Error) => {
      if (generation !== this.generation) { return; }
      Diagnostics.log('error', 'background', 'acquire_failed', undefined, error);
      if (!this.foreground) { this.interrupt(t('未获得长时后台执行权限，本轮已停止。请保持应用在前台后重试。')); }
    }).finally(() => { if (this.acquiring === acquiring) { this.acquiring = undefined; } });
    this.acquiring = acquiring;
  }

  private async acquire(context: common.UIAbilityContext, generation: number): Promise<void> {
    if (!this.cancelObserved) {
      backgroundTaskManager.on('continuousTaskCancel', this.cancelled);
      this.cancelObserved = true;
    }
    if (!this.suspendObserved) {
      backgroundTaskManager.on('continuousTaskSuspend', this.suspended);
      this.suspendObserved = true;
    }
    const request = new backgroundTaskManager.ContinuousTaskRequest();
    request.backgroundTaskModes = [backgroundTaskManager.BackgroundTaskMode.MODE_TASK_KEEPING];
    request.backgroundTaskSubmodes = [backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_NORMAL_NOTIFICATION];
    if (!request.isModeSupported()) { throw new Error('taskKeeping requires the KEEP_BACKGROUND_RUNNING_SYSTEM ACL on phones'); }
    request.wantAgent = await wantAgent.getWantAgent({
      wants: [{ bundleName: context.abilityInfo.bundleName, abilityName: context.abilityInfo.name }],
      actionType: wantAgent.OperationType.START_ABILITY, requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    });
    if (generation !== this.generation) { return; }
    const result = await backgroundTaskManager.startBackgroundRunning(context, request);
    if (result.continuousTaskId === undefined) { throw new Error('Background task returned no continuousTaskId'); }
    const task: GenerationTask = { id: result.continuousTaskId, context: context };
    if (generation !== this.generation) { await this.stopTask(task); return; }
    this.task = task;
    Diagnostics.log('info', 'background', 'acquired');
  }

  private interrupt(reason: string): void {
    const session = this.session;
    if (!session || this.stopping) { return; }
    this.stopping = true;
    Promise.resolve().then(async () => {
      if (this.session !== session || !this.active) { return; }
      await session.stop(reason); await session.waitForIdle();
    }).catch((error: Error) => Diagnostics.log('error', 'background', 'stop_failed', undefined, error))
      .finally(() => { if (this.session === session) { this.stopping = false; } });
  }

  private release(): void {
    const task = this.task; this.task = undefined;
    if (task) { this.stopTask(task).catch((error: Error) => Diagnostics.log('error', 'background', 'release_failed', undefined, error)); }
  }

  private async stopTask(task: GenerationTask): Promise<void> {
    await backgroundTaskManager.stopBackgroundRunning(task.context, task.id);
    Diagnostics.log('info', 'background', 'released');
  }
}

export const backgroundGeneration = new BackgroundGeneration();
