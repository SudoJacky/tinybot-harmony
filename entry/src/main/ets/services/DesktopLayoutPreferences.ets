import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

export class DesktopLayoutPreferences {
  private store: preferences.Preferences;

  constructor(context: common.Context) {
    this.store = preferences.getPreferencesSync(context, { name: 'tinybot-ui' });
  }

  historyCollapsed(): boolean { return this.store.getSync('pc.historyCollapsed', false) === true; }

  paneWidth(detail: boolean): number {
    const width = Number(this.store.getSync(detail ? 'pc.detailWidth' : 'pc.historyWidth', 0));
    return Number.isFinite(width) && width > 0 ? width : 0;
  }

  saveCollapsed(value: boolean): void { this.save('pc.historyCollapsed', value); }

  saveWidth(detail: boolean, value: number): void { this.save(detail ? 'pc.detailWidth' : 'pc.historyWidth', value); }

  private save(key: string, value: number | boolean): void {
    const previous = this.store.getSync(key, typeof value === 'boolean' ? false : 0);
    if (previous === value) { return; }
    try {
      this.store.putSync(key, value);
      this.store.flushSync();
    } catch (error) {
      this.store.putSync(key, previous);
      throw error as Error;
    }
  }
}
