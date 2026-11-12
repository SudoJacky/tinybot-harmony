import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { Diagnostics } from '../model/Diagnostics';
import { ConversationStore } from '../model/ConversationStore';
import { ConversationCapture } from '../model/ConversationCapture';
import { emptyData } from '../model/Conversation';
import { t } from '../model/I18n';
import { WorkspaceStore } from '../model/WorkspaceStore';
import { parseLifeBoard } from '../model/LifeBoard';
import { parsePanelRecord } from '../model/LifePanel';
import { ArkDataRecords, DATABASE_KEY_UNAVAILABLE, LOCAL_DATABASE } from './ArkDataRecords';
import { conversationRecords } from './ArkDataConversationStore';
import { legacyWorkspaceRecords, registerWorkspaceDatabase } from './ArkDataWorkspace';
import { readLegacyUsage, USAGE_SCOPE, usageRecordId } from './UsageLedger';

const databases = new Map<string, NativeData>();
const RECOVERY_NAME = /^tinybot-recovery-[0-9a-f-]{36}\.db$/;
const DATABASE_PREFS = 'tinybot-local-data';

export interface LegacyRecoverySource { threads: number; savedAt: number; }

export class NativeData {
  private context: common.UIAbilityContext;
  private workspaces: WorkspaceStore;
  private opening?: Promise<ArkDataRecords>;
  private recovering?: Promise<void>;
  private keyUnavailable: boolean = false;

  constructor(context: common.UIAbilityContext, workspaceFilesDir: string) {
    this.context = context; this.workspaces = new WorkspaceStore(workspaceFilesDir);
    databases.set(context.filesDir, this);
    registerWorkspaceDatabase(this.workspaces.rootDir, () => this.open());
  }

  static forFilesDir(path: string): NativeData | undefined { return databases.get(path); }

  get needsRecovery(): boolean { return this.keyUnavailable; }

  private settings(): preferences.Preferences {
    return preferences.getPreferencesSync(this.context, { name: DATABASE_PREFS });
  }

  private selectedDatabase(): string {
    const name = this.settings().getSync('database', '') as string;
    return RECOVERY_NAME.test(name) ? name : LOCAL_DATABASE;
  }

  autoBackupReady(): boolean {
    const name = this.selectedDatabase();
    return name === LOCAL_DATABASE || this.settings().getSync('backupReviewed', '') === name;
  }

  allowAutoBackup(): void {
    const name = this.selectedDatabase();
    if (name === LOCAL_DATABASE) { return; }
    const settings = this.settings();
    settings.putSync('backupReviewed', name); settings.flushSync();
  }

  async legacyRecoverySource(): Promise<LegacyRecoverySource | undefined> {
    const root = this.context.filesDir;
    for (const path of [root + '/sessions-v2/index.json', root + '/tinybot-v1.json']) {
      if (!await fs.access(path)) { continue; }
      const stat = await fs.stat(path);
      const data = await new ConversationStore(root).load(false);
      return { threads: data.threads.length, savedAt: stat.mtime * 1000 };
    }
    return undefined;
  }

  open(): Promise<ArkDataRecords> {
    if (!this.opening) {
      this.opening = this.migrate(this.selectedDatabase()).then((db) => {
        this.keyUnavailable = false;
        return db;
      }).catch((error: Error) => {
        this.keyUnavailable = (error as BusinessError).code === DATABASE_KEY_UNAVAILABLE;
        this.opening = undefined;
        throw error;
      });
    }
    return this.opening;
  }

  recover(useLegacy: boolean): Promise<void> {
    if (!this.recovering) {
      this.recovering = this.rebuild(useLegacy).finally(() => { this.recovering = undefined; });
    }
    return this.recovering;
  }

  private async rebuild(useLegacy: boolean): Promise<void> {
    if (!this.keyUnavailable || (useLegacy && !await this.legacyRecoverySource())) { throw new Error(t('当前没有可用的本机恢复来源。')); }
    const name = 'tinybot-recovery-' + util.generateRandomUUID() + '.db';
    const db = await this.migrate(name, useLegacy);
    const settings = this.settings();
    const previous = settings.getSync('database', '');
    try { settings.putSync('database', name); settings.flushSync(); }
    catch (error) { settings.putSync('database', previous); throw error as Error; }
    this.opening = Promise.resolve(db); this.keyUnavailable = false;
  }

  private async migrate(name: string, useLegacy: boolean = true): Promise<ArkDataRecords> {
    const db = await ArkDataRecords.open(this.context, name);
    let threads = 0, requests = 0, panels = 0, boards = 0;
    const migrated = await db.importLegacy(async (write) => {
      const data = useLegacy ? await new ConversationStore(this.context.filesDir).load(false) : emptyData();
      const records = conversationRecords(new ConversationCapture().capture(data));
      for (const record of records) { await write(record); }
      if (!useLegacy) { return; }
      threads = data.threads.length;
      const usage = await readLegacyUsage(this.context.filesDir);
      for (const record of usage) { await write({ scope: USAGE_SCOPE, id: usageRecordId(requests++), text: JSON.stringify(record) }); }
      if (!await fs.access(this.workspaces.rootDir)) { return; }
      for (const id of await fs.listFile(this.workspaces.rootDir)) {
        const root = this.workspaces.pathFor(id), stat = await fs.lstat(root);
        if (stat.isSymbolicLink()) { throw new Error('Invalid workspace link during ArkData migration'); }
        if (!stat.isDirectory()) { continue; }
        for (const kind of ['life-panels', 'life-boards']) {
          for (const path of await legacyWorkspaceRecords(root, kind)) {
            const text = await fs.readText(root + '/' + path), recordId = path.split('/')[1];
            if (kind === 'life-panels') { parsePanelRecord(text, recordId); panels++; }
            else { parseLifeBoard(text, recordId); boards++; }
            await write({ scope: 'workspace:' + id, id: path, text: text });
          }
        }
      }
    });
    if (migrated) {
      Diagnostics.log('info', 'storage', 'migration_committed', { threads: threads, requests: requests, panels: panels, boards: boards });
    }
    return db;
  }
}
