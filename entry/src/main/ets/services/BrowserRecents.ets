import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { validateWebAddress } from './WebTools';

export interface BrowserVisit { url: string; title: string; }

const RECENT_KEY: string = 'browser.recent';
const MAX_RECENT: number = 8;

// Device-local history for pages the user has visited in the embedded browser.
export class BrowserRecents {
  private store: preferences.Preferences;
  constructor(context: common.UIAbilityContext) {
    this.store = preferences.getPreferencesSync(context, { name: 'tinybot-ui' });
  }
  read(): BrowserVisit[] {
    const items = JSON.parse(this.store.getSync(RECENT_KEY, '[]') as string) as BrowserVisit[];
    if (!Array.isArray(items)) { throw new Error('Invalid browser history'); }
    return items.slice(0, MAX_RECENT).map((item): BrowserVisit => {
      return { url: validateWebAddress(item.url), title: item.title.slice(0, 160) };
    });
  }
  record(items: BrowserVisit[], url: string, title: string): BrowserVisit[] {
    const value = validateWebAddress(url);
    const visit: BrowserVisit = { url: value, title: title.slice(0, 160) };
    if (items[0]?.url === value && items[0]?.title === visit.title) { return items; }
    const next = [visit, ...items.filter((item) => item.url !== value)]
      .slice(0, MAX_RECENT);
    this.write(next);
    return next;
  }
  write(items: BrowserVisit[]): void {
    const previous = this.store.getSync(RECENT_KEY, '[]');
    try {
      this.store.putSync(RECENT_KEY, JSON.stringify(items));
      this.store.flushSync();
    } catch (error) {
      this.store.putSync(RECENT_KEY, previous);
      throw error as Error;
    }
  }
}
