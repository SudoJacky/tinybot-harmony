import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { ONBOARDING_STEP_KEY, FirstUseStatus } from '../model/Onboarding';

// Installation-local UI history, independent of conversations and exported backups.
export class OnboardingPreferences {
  private store: preferences.Preferences;
  constructor(context: common.Context) {
    this.store = preferences.getPreferencesSync(context, { name: 'tinybot-ui' });
  }
  resumeStep(status: FirstUseStatus): number {
    if (this.completed()) { return 0; }
    const step = this.checkpoint();
    return step || (status.onboarding ? 1 : 0);
  }
  begin(): void {
    if (!this.completed() && this.checkpoint() === 0) { this.write(ONBOARDING_STEP_KEY, 1, 0); }
  }
  reach(step: number): void {
    const previous = this.checkpoint();
    if (!this.completed() && previous > 0 && step > previous) { this.write(ONBOARDING_STEP_KEY, step, previous); }
  }
  complete(): void {
    if (!this.completed()) { this.write('onboardingComplete', true, false); }
  }
  private completed(): boolean { return this.store.getSync('onboardingComplete', false) === true; }
  private checkpoint(): number {
    const step = this.store.getSync(ONBOARDING_STEP_KEY, 0);
    return typeof step === 'number' && Number.isInteger(step) && step >= 1 && step <= 4 ? step : 0;
  }
  private write(key: string, value: boolean | number, previous: boolean | number): void {
    try { this.store.putSync(key, value); this.store.flushSync(); }
    catch (error) { this.store.putSync(key, previous); throw error as Error; }
  }
}
