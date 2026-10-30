import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { MINI_APP_DIR, MiniAppEntry, MiniAppRecord, MiniAppRevision, VersionedMiniAppRecord, MiniAppSnapshot, MiniAppStorage,
  miniAppId, miniAppPath, parseMiniApp, miniAppDataFile, miniAppInCollection, miniAppPreviousRevision, miniAppIconId, miniAppIconColorId } from '../model/MiniApp';
import { WebUiSpec, parseWebUi } from '../model/WebUi';
import { WorkspaceStore } from '../model/WorkspaceStore';
import { NativeWorkspaceFiles } from './NativeWorkspaceFiles';
import { WorkspaceFiles, WorkspaceWrite, WorkspaceWriteGuard } from './WorkspaceFiles';
import { Cancellation } from './Cancellation';
import { withFileMutation } from './FileMutationQueue';
import { Diagnostics } from '../model/Diagnostics';

interface StoredData { version: number; value: Object | null; }
class MiniAppFiles extends NativeWorkspaceFiles {
  write(path: string, content: string, cancellation: Cancellation, guard?: WorkspaceWriteGuard): Promise<WorkspaceWrite> {
    return this.writeMiniApp(path, content, cancellation, guard);
  }
}
export class MiniAppRepository {
  private files: WorkspaceFiles;
  private lockKey: string;
  constructor(files: WorkspaceFiles, lockKey: string) { this.files = files; this.lockKey = lockKey; }
  async get(id: string): Promise<MiniAppRecord> {
    return parseMiniApp((await this.files.read(miniAppPath(id, 'app.json'), new Cancellation())).content, id);
  }
  async publish(id: string, title: string, description: string, sourcePath: string, sourceThreadId: string,
    page: WebUiSpec, existing: boolean, cancellation: Cancellation): Promise<MiniAppRecord> {
    return withFileMutation(this.lockKey + ':' + miniAppId(id), async (): Promise<MiniAppRecord> => {
      cancellation.check();
      const path = miniAppPath(id, 'app.json');
      const snapshot = existing ? await this.files.read(path, cancellation) : undefined;
      const old = snapshot ? parseMiniApp(snapshot.content, id) : undefined;
      if (old?.archived) { throw new Error('Restore the mini app before publishing an update'); }
      const now = Date.now();
      let app: MiniAppRecord = { version: 1, id: id, title: title, description: description, sourcePath: sourcePath,
        sourceThreadId: sourceThreadId, createdAt: old?.createdAt ?? now, updatedAt: now, lastOpenedAt: old?.lastOpenedAt ?? 0,
        archived: false, page: parseWebUi(JSON.stringify(page)), previousPage: old?.page, icon: old?.icon, iconColor: old?.iconColor };
      if (old?.version === 2) {
        const history = old as VersionedMiniAppRecord;
        const current = history.revisions.find((revision) => revision.id === history.currentRevisionId);
        const number = history.revisions.length + 1;
        const revision: MiniAppRevision = { id: 'v' + number + '-' + util.generateRandomUUID(), number: number,
          title: title, description: description, summary: 'Updated page', sourcePath: sourcePath, sourceThreadId: sourceThreadId,
          createdAt: now, dataSchema: current?.dataSchema ?? 1, page: app.page };
        history.revisions.push(revision);
        this.useRevision(history, revision, now); app = history;
      }
      parseMiniApp(JSON.stringify(app), id);
      if (!old) { await this.files.write(miniAppPath(id, 'data.json'), JSON.stringify({ version: 1, value: null }), cancellation, { version: null }); }
      // Commit only the page/metadata; an update never writes user data.
      await this.files.write(path, JSON.stringify(app), cancellation, { version: snapshot?.version ?? null });
      return app;
    });
  }
  async load(id: string): Promise<MiniAppSnapshot> {
    return withFileMutation(this.lockKey + ':' + miniAppId(id), async (): Promise<MiniAppSnapshot> => {
    const app = await this.get(id);
    if (app.archived || !miniAppInCollection(app)) { throw new Error('This mini app has not been added or has been removed'); }
    return this.readData(id);
    });
  }
  async readData(id: string): Promise<MiniAppSnapshot> {
    const app = await this.get(id);
    const file = await this.files.read(miniAppPath(id, miniAppDataFile(app)), new Cancellation());
    const data = JSON.parse(file.content) as StoredData;
    if (!data || data.version !== 1 || data.value === undefined) { throw new Error('Invalid mini app data: ' + id); }
    return { value: data.value, revision: file.version };
  }
  async save(id: string, value: Object | null, revision: string): Promise<MiniAppSnapshot> {
    return withFileMutation(this.lockKey + ':' + miniAppId(id), async (): Promise<MiniAppSnapshot> => {
      const app = await this.get(id);
      if (app.archived || !miniAppInCollection(app)) { throw new Error('This mini app has not been added or has been removed'); }
      if (typeof revision !== 'string' || !revision) { throw new Error('Load mini app data before saving'); }
      const content = JSON.stringify({ version: 1, value: value });
      const data = JSON.parse(content) as StoredData;
      if (data.value === undefined) { throw new Error('Mini app data must be JSON'); }
      const result = await this.files.write(miniAppPath(id, miniAppDataFile(app)), content, new Cancellation(), { version: revision });
      return { value: data.value, revision: result.version };
    });
  }
  async rename(id: string, title: string): Promise<void> {
    const name = title.trim();
    if (!name || name.length > 160) { throw new Error('Mini app name must contain 1–160 characters'); }
    await withFileMutation(this.lockKey + ':' + miniAppId(id), async (): Promise<void> => {
      const path = miniAppPath(id, 'app.json'), cancellation = new Cancellation();
      const file = await this.files.read(path, cancellation), app = parseMiniApp(file.content, id);
      app.title = name;
      await this.files.write(path, JSON.stringify(app), cancellation, { version: file.version });
    });
  }
  async setIcon(id: string, icon: string, color?: string): Promise<void> {
    miniAppIconId(icon);
    if (color !== undefined) { miniAppIconColorId(color); }
    await withFileMutation(this.lockKey + ':' + miniAppId(id), async (): Promise<void> => {
      const path = miniAppPath(id, 'app.json'), cancellation = new Cancellation();
      const file = await this.files.read(path, cancellation), app = parseMiniApp(file.content, id);
      app.icon = icon;
      if (color !== undefined) { app.iconColor = color; }
      await this.files.write(path, JSON.stringify(app), cancellation, { version: file.version });
    });
  }
  async change(id: string, action: string): Promise<MiniAppRecord> {
    return withFileMutation(this.lockKey + ':' + miniAppId(id), async (): Promise<MiniAppRecord> => {
      const path = miniAppPath(id, 'app.json'), cancellation = new Cancellation();
      const file = await this.files.read(path, cancellation), app = parseMiniApp(file.content, id);
      if (action === 'archive') { app.archived = true; }
      else if (action === 'restore') { app.archived = false; }
      else if (action === 'open') { if (app.archived || !miniAppInCollection(app)) { throw new Error('This mini app has not been added or has been removed'); } app.lastOpenedAt = Date.now(); }
      else if (action === 'rollback') {
        if (app.version === 2) {
          const previous = miniAppPreviousRevision(app);
          if (!previous || app.archived) { throw new Error('No compatible previous mini app version available'); }
          this.useRevision(app as VersionedMiniAppRecord, previous, Date.now());
        } else {
          if (!app.previousPage || app.archived) { throw new Error('No previous mini app version available'); }
          const previous = app.previousPage; app.previousPage = app.page; app.page = previous; app.updatedAt = Date.now();
        }
      } else { throw new Error('Unknown mini app action'); }
      await this.files.write(path, JSON.stringify(app), cancellation, { version: file.version }); return app;
    });
  }
  private useRevision(app: VersionedMiniAppRecord, revision: MiniAppRevision, now: number): void {
    app.currentRevisionId = revision.id; app.page = revision.page; app.title = revision.title; app.description = revision.description;
    app.sourcePath = revision.sourcePath; app.sourceThreadId = revision.sourceThreadId; app.updatedAt = now;
    app.adoptions.push({ revisionId: revision.id, adoptedAt: now, dataFile: app.dataFile });
  }
  binding(id: string): MiniAppStorage { return new MiniAppBinding(this, miniAppId(id)); }
}
class MiniAppBinding implements MiniAppStorage {
  private repository: MiniAppRepository;
  private id: string;
  constructor(repository: MiniAppRepository, id: string) { this.repository = repository; this.id = id; }
  load(): Promise<MiniAppSnapshot> { return this.repository.load(this.id); }
  save(value: Object | null, revision: string): Promise<MiniAppSnapshot> { return this.repository.save(this.id, value, revision); }
}
// Validation reads a detached snapshot. Startup scripts cannot write persistent data.
export class MiniAppValidationStorage implements MiniAppStorage {
  private snapshot: MiniAppSnapshot;
  constructor(snapshot: MiniAppSnapshot) { this.snapshot = snapshot; }
  async load(): Promise<MiniAppSnapshot> { return JSON.parse(JSON.stringify(this.snapshot)) as MiniAppSnapshot; }
  async save(_value: Object | null, _revision: string): Promise<MiniAppSnapshot> { throw new Error('Save only after user interaction, not during startup validation'); }
}
export class MiniApps {
  private workspaces: WorkspaceStore;
  constructor(filesDir: string) { this.workspaces = new WorkspaceStore(filesDir); }
  repository(workspaceId: string): MiniAppRepository {
    const root = this.workspaces.pathFor(workspaceId);
    return new MiniAppRepository(new MiniAppFiles(root), root);
  }
  createId(): string { return 'app-' + util.generateRandomUUID(); }
  async remove(workspaceId: string, id: string): Promise<void> {
    const root = this.workspaces.pathFor(workspaceId);
    await this.workspaces.requireWorkspace(workspaceId);
    await withFileMutation(root + ':' + miniAppId(id), async (): Promise<void> => {
      const repository = this.repository(workspaceId);
      if (!(await repository.get(id)).archived) { throw new Error('Remove the mini app from the collection before deleting its data'); }
      await new NativeWorkspaceFiles(root).checkedPath(miniAppPath(id, 'app.json'));
      await fs.rmdir(root + '/' + MINI_APP_DIR + '/' + id);
    });
  }
  async list(workspaceId?: string): Promise<MiniAppEntry[]> {
    const result: MiniAppEntry[] = [];
    if (!await fs.access(this.workspaces.rootDir)) { return result; }
    const roots = workspaceId ? [workspaceId] : await fs.listFile(this.workspaces.rootDir);
    for (const id of roots) {
      const root = this.workspaces.pathFor(id);
      await this.workspaces.requireWorkspace(id);
      const path = root + '/' + MINI_APP_DIR;
      if (!await fs.access(path)) { continue; }
      const stat = await fs.lstat(path);
      if (!stat.isDirectory() || stat.isSymbolicLink()) { throw new Error('Invalid mini app directory: ' + id); }
      for (const appId of await fs.listFile(path)) {
        const appRoot = path + '/' + miniAppId(appId), appStat = await fs.lstat(appRoot);
        if (!appStat.isDirectory() || appStat.isSymbolicLink()) { throw new Error('Invalid mini app directory: ' + appId); }
        // A failed initial publication can leave data without a committed manifest.
        if (!await fs.access(appRoot + '/app.json')) { continue; }
        try { result.push({ workspaceId: id, app: await this.repository(id).get(appId) }); }
        catch (error) { Diagnostics.log('error', 'mini-app', 'manifest_failed', { sessionId: id, previewId: appId }, error as Error); throw error as Error; }
      }
    }
    return result.sort((a: MiniAppEntry, b: MiniAppEntry) => (b.app.lastOpenedAt || b.app.updatedAt) - (a.app.lastOpenedAt || a.app.updatedAt));
  }
}
