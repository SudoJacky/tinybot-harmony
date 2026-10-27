import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

const KEY: string = 'reviewInvitation';
const TASK_THRESHOLD: number = 5;
const ASK_INTERVAL: number = 7 * 24 * 60 * 60 * 1000;

interface ReviewHistory {
  completedTasks: number;
  lastAskedAt: number;
  stopped: boolean;
}

// Installation-local history: restored/imported conversations never count as new successes.
export class ReviewPreferences {
  private store: preferences.Preferences;
  constructor(context: common.Context) {
    this.store = preferences.getPreferencesSync(context, { name: 'tinybot-ui' });
  }
  private read(): ReviewHistory {
    const raw = this.store.getSync(KEY, '');
    if (raw === '') { return { completedTasks: 0, lastAskedAt: 0, stopped: false }; }
    if (typeof raw !== 'string') { throw new Error('Invalid review invitation storage'); }
    const value = JSON.parse(raw) as ReviewHistory;
    if (!value || !Number.isInteger(value.completedTasks) || value.completedTasks < 0 ||
      !Number.isFinite(value.lastAskedAt) || value.lastAskedAt < 0 || typeof value.stopped !== 'boolean') {
      throw new Error('Invalid review invitation history');
    }
    return value;
  }
  private save(value: ReviewHistory): void {
    const previous = this.store.getSync(KEY, '');
    try { this.store.putSync(KEY, JSON.stringify(value)); this.store.flushSync(); }
    catch (error) { this.store.putSync(KEY, previous); throw error as Error; }
  }
  recordTask(): void {
    const value = this.read();
    if (value.stopped || value.completedTasks >= TASK_THRESHOLD) { return; }
    value.completedTasks++; this.save(value);
  }
  shouldAsk(now: number): boolean {
    const value = this.read();
    return !value.stopped && value.completedTasks >= TASK_THRESHOLD &&
      (value.lastAskedAt === 0 || now - value.lastAskedAt >= ASK_INTERVAL);
  }
  didAsk(now: number): void {
    const value = this.read(); value.lastAskedAt = now; this.save(value);
  }
  stopInvitations(): void {
    const value = this.read();
    if (!value.stopped) { value.stopped = true; this.save(value); }
  }
}
