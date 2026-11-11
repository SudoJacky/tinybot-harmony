import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ConversationStore } from '../model/ConversationStore';
import { ConversationCapture } from '../model/ConversationCapture';
import { WorkspaceStore } from '../model/WorkspaceStore';
import { parseLifeBoard } from '../model/LifeBoard';
import { parsePanelRecord } from '../model/LifePanel';
import { ArkDataRecords } from './ArkDataRecords';
import { conversationRecords } from './ArkDataConversationStore';
import { legacyWorkspaceRecords, registerWorkspaceDatabase } from './ArkDataWorkspace';
import { readLegacyUsage, USAGE_SCOPE, usageRecordId } from './UsageLedger';

const databases = new Map<string, NativeData>();

export class NativeData {
  private context: common.UIAbilityContext;
  private workspaces: WorkspaceStore;
  private opening?: Promise<ArkDataRecords>;

  constructor(context: common.UIAbilityContext, workspaceFilesDir: string) {
    this.context = context; this.workspaces = new WorkspaceStore(workspaceFilesDir);
    databases.set(context.filesDir, this);
    registerWorkspaceDatabase(this.workspaces.rootDir, () => this.open());
  }

  static forFilesDir(path: string): NativeData | undefined { return databases.get(path); }

  open(): Promise<ArkDataRecords> {
    if (!this.opening) {
      this.opening = this.migrate().catch((error: Error) => {
        this.opening = undefined;
        throw error;
      });
    }
    return this.opening;
  }

  private async migrate(): Promise<ArkDataRecords> {
    const db = await ArkDataRecords.open(this.context);
    let threads = 0, requests = 0, panels = 0, boards = 0;
    const migrated = await db.importLegacy(async (write) => {
      const data = await new ConversationStore(this.context.filesDir).load(false);
      const records = conversationRecords(new ConversationCapture().capture(data));
      for (const record of records) { await write(record); }
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
      hilog.info(0x0000, 'TinybotStorage', 'ArkData migration committed threads=%{public}d usage=%{public}d panels=%{public}d boards=%{public}d',
        threads, requests, panels, boards);
    }
    return db;
  }
}
