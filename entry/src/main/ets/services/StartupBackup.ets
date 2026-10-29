import { bundleManager, common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo as fs } from '@kit.CoreFileKit';
import { AppData } from '../model/Conversation';
import { isOnboardingCandidate } from '../model/Onboarding';
import { CloudBackup, CloudBackupItem } from './CloudBackup';

// Installation-local marker. Capture BEFORE ConversationStore creates an empty manifest.
// Missing marker alone never means new install: old builds did not write this marker.
export class StartupBackup {
  private store: preferences.Preferences;
  private context: common.UIAbilityContext;
  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.store = preferences.getPreferencesSync(context, { name: 'tinybot-ui' });
    const state = this.store.getSync('startupBackupState', '');
    if (state === 'done') { return; }
    const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    if (state === 'pending') {
      if (info.installTime !== info.updateTime) { this.finish(); }
      return;
    }
    const fresh = info.installTime > 0 && info.installTime === info.updateTime &&
      !fs.accessSync(context.filesDir + '/sessions-v2/index.json') && !fs.accessSync(context.filesDir + '/tinybot-v1.json') &&
      this.store.getSync('onboardingComplete', false) !== true;
    this.save(fresh ? 'pending' : 'done');
  }
  untouched(data: AppData): boolean {
    return this.store.getSync('onboardingComplete', false) !== true && isOnboardingCandidate(data) &&
      !(data.config.userDocument || '').trim() && !(data.productivity?.servers || []).length &&
      !(data.productivity?.memories || []).length;
  }
  async find(data: AppData): Promise<CloudBackupItem | undefined> {
    if (this.store.getSync('startupBackupState', '') !== 'pending') { return undefined; }
    if (!this.untouched(data)) { this.finish(); return undefined; }
    // Pull remote metadata before listing; a new device may not have a cached directory yet.
    const synced = await CloudBackup.sync();
    const items = await CloudBackup.list(this.context);
    const latest = items.find((item) => item.name === 'tinybot-latest.tinybot') || items[0];
    if (!latest && synced) { this.finish(); }
    return latest;
  }
  finish(): void { this.save('done'); }
  private save(value: string): void {
    const previous = this.store.getSync('startupBackupState', '');
    try { this.store.putSync('startupBackupState', value); this.store.flushSync(); }
    catch (error) { this.store.putSync('startupBackupState', previous); throw error as Error; }
  }
}
