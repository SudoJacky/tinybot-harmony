import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

export interface DesktopPanelSelection {
  threadId: string;
  tab: string;
  messageId?: string;
  previewId?: string;
}

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

  panelSelection(): DesktopPanelSelection | undefined {
    const data = this.store.getSync('pc.panelSelection', '');
    return typeof data === 'string' && data !== '' ? JSON.parse(data) as DesktopPanelSelection : undefined;
  }

  savePanelSelection(value?: DesktopPanelSelection): void {
    this.save('pc.panelSelection', value ? JSON.stringify(value) : '');
  }

  private save(key: string, value: number | boolean | string): void {
    const previous = this.store.getSync(key, typeof value === 'string' ? '' : typeof value === 'boolean' ? false : 0);
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
