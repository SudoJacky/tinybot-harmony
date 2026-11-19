import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { withFileMutation } from './FileMutationQueue';

const ACCESS_KEY: string = 'knowledgeBasesEnabled';

export class KnowledgeBaseAccess {
  private store?: preferences.Preferences;
  private allowed: boolean = false;
  private accessRevision: number = 0;

  get enabled(): boolean { return this.allowed; }
  get revision(): number { return this.accessRevision; }

  initialize(context: common.Context): void {
    if (this.store) { return; }
    const store = preferences.getPreferencesSync(context, { name: 'tinybot-knowledge-bases' });
    const value = store.getSync(ACCESS_KEY, false);
    if (typeof value !== 'boolean') { throw new Error('Invalid saved knowledge base setting.'); }
    this.allowed = value;
    this.store = store;
  }

  async setEnabled(enabled: boolean): Promise<void> {
    await withFileMutation(ACCESS_KEY, async () => {
      const store = this.store;
      if (!store) { throw new Error('Knowledge base settings storage is unavailable.'); }
      if (enabled === this.allowed) { return; }
      store.putSync(ACCESS_KEY, enabled);
      try { await store.flush(); }
      catch (error) {
        store.putSync(ACCESS_KEY, this.allowed);
        throw error as Error;
      }
      this.allowed = enabled;
      this.accessRevision++;
    });
  }
}

export const knowledgeBaseAccess: KnowledgeBaseAccess = new KnowledgeBaseAccess();
