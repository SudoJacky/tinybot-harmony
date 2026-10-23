import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { http } from '@kit.NetworkKit';
import { Announcement, parseAnnouncement } from '../model/Announcement';
import { Diagnostics } from '../model/Diagnostics';
import { t } from '../model/I18n';
import { hostedPrivacy } from './HostedPrivacy';

// Public feed selects one active announcement; an explicitly empty endpoint disables fetching.
export const ANNOUNCEMENT_URL: string = 'https://sudotinybot.cn/api/announcement';
const SEEN_KEY: string = 'seenAnnouncementIds';

@Observed
export class Announcements {
  current: Announcement | null = null;
  loading: boolean = false;
  error: string = '';
  private endpoint: string;
  private startup?: Promise<void>;
  private store?: preferences.Preferences;
  private seen: string[] = [];
  private offered: boolean = false;

  constructor(endpoint: string = ANNOUNCEMENT_URL) { this.endpoint = endpoint; }
  get configured(): boolean { return this.endpoint.length > 0; }

  // Singleton lifetime is the app process: foreground changes and page remounts share this attempt.
  checkOnStartup(context: common.Context): Promise<void> {
    if (!hostedPrivacy.allowed) { return Promise.resolve(); }
    if (!this.startup) { this.startup = this.load(context); }
    return this.startup;
  }

  private async load(context: common.Context): Promise<void> {
    if (!this.configured) { Diagnostics.log('info', 'announcements', 'disabled'); return; }
    this.loading = true;
    const started = Date.now();
    let status = 0;
    try {
      if (!/^https:\/\/[^/\s]+(?:\/[^\s]*)?$/.test(this.endpoint)) { throw new Error('Announcement endpoint must use HTTPS'); }
      this.store = preferences.getPreferencesSync(context, { name: 'tinybot-ui' });
      const stored = this.store.getSync(SEEN_KEY, []) as string[];
      if (!Array.isArray(stored) || stored.some((id: string) => typeof id !== 'string')) {
        throw new Error('Invalid announcement storage');
      }
      this.seen = stored.slice();
      const request = http.createHttp();
      Diagnostics.log('info', 'announcements', 'fetch_started');
      try {
        const response = await request.request(this.endpoint, {
          method: http.RequestMethod.GET, header: { 'Accept': 'application/json' }, usingCache: false,
          connectTimeout: 5000, readTimeout: 5000, maxRedirects: 0, maxLimit: 256 * 1024,
          expectDataType: http.HttpDataType.STRING
        });
        status = response.responseCode;
        if (status !== 200) { throw new Error('Announcement HTTP ' + status); }
        if (typeof response.result !== 'string') { throw new Error('Invalid announcement JSON response'); }
        const current = parseAnnouncement(response.result);
        if (hostedPrivacy.allowed) { this.current = current; }
        Diagnostics.log('info', 'announcements', 'fetch_completed', { http: status, elapsedMs: Date.now() - started, count: current ? 1 : 0 });
      } finally { request.destroy(); }
    } catch (error) {
      this.error = t('公告加载失败，将在下次启动时重试。');
      Diagnostics.log('error', 'announcements', 'fetch_failed', { http: status, elapsedMs: Date.now() - started }, error as Error);
    } finally { this.loading = false; }
  }

  pending(): Announcement | null {
    return !this.offered && this.current && !this.seen.includes(this.current.id) ? this.current : null;
  }

  didOffer(): void { this.offered = true; Diagnostics.log('info', 'announcements', 'presented'); }

  acknowledge(id: string): void {
    if (!this.store || !this.current || this.current.id !== id) { throw new Error('Announcement is not ready'); }
    if (this.seen.includes(id)) { return; }
    const next = this.seen.concat(id);
    try {
      this.store.putSync(SEEN_KEY, next);
      this.store.flushSync();
    } catch (error) {
      this.store.putSync(SEEN_KEY, this.seen);
      Diagnostics.log('error', 'announcements', 'save_failed', undefined, error as Error);
      throw new Error(t('无法保存公告已读记录，下次启动可能再次提示。'));
    }
    this.seen = next;
    Diagnostics.log('info', 'announcements', 'acknowledged');
  }
}

export const announcements: Announcements = new Announcements();
