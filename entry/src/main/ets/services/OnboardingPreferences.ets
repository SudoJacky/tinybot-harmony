import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { AppData } from '../model/Conversation';
import { isOnboardingCandidate } from '../model/Onboarding';

// Installation-local UI history, independent of conversations and exported backups.
export class OnboardingPreferences {
  private store: preferences.Preferences;
  constructor(context: common.Context) {
    this.store = preferences.getPreferencesSync(context, { name: 'tinybot-ui' });
  }
  shouldShow(data: AppData): boolean {
    return this.store.getSync('onboardingComplete', false) !== true && isOnboardingCandidate(data);
  }
  complete(): void {
    const previous = this.store.getSync('onboardingComplete', false);
    try { this.store.putSync('onboardingComplete', true); this.store.flushSync(); }
    catch (error) { this.store.putSync('onboardingComplete', previous); throw error as Error; }
  }
}
