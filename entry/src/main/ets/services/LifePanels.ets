import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { WorkspaceStore } from '../model/WorkspaceStore';
import { Diagnostics } from '../model/Diagnostics';
import { PanelSpec, PanelRecord, PanelEntry, PanelRun, panelId, panelPath, panelPointer, panelValue, panelItems, parsePanelSpec, parsePanelRecord, validatePanelData } from '../model/LifePanel';
import { WorkspaceFiles, WorkspaceWrite, WorkspaceWriteGuard } from './WorkspaceFiles';
import { NativeWorkspaceFiles } from './NativeWorkspaceFiles';
import { workspaceRelativePath } from './WorkspaceTools';
import { NativeWebTransport } from './NativeWebTransport';
import { PanelApiTransport } from './PanelApiTransport';
import { PanelCredentials } from './PanelCredentials';
import { PanelDataTransform } from './PanelDataTransform';
import { NativeCodeExecutor } from './NativeCodeExecutor';
import { CodeExecutor } from './CodeExecutionTools';
import { Cancellation } from './Cancellation';
import { withFileMutation } from './FileMutationQueue';
import { PanelAgentRefresh, PanelAgentRunner } from './PanelAgentRefresh';
import { PanelChanges } from './PanelChanges';

export interface PanelSourceReader { read(spec: PanelSpec, cancellation: Cancellation, id?: string, data?: Object): Promise<Object>; }
export class NativePanelSourceReader implements PanelSourceReader {
  private files: WorkspaceFiles;
  private namespace: string;
  private transform: PanelDataTransform;
  constructor(files: WorkspaceFiles, namespace: string = '', executor: CodeExecutor = new NativeCodeExecutor()) {
    this.files = files; this.namespace = namespace; this.transform = new PanelDataTransform(executor);
  }
  async read(spec: PanelSpec, cancellation: Cancellation, id: string = '', data?: Object): Promise<Object> {
    const source = spec.source;
    if (!source) { throw new Error('This panel has no refreshable source'); }
    if (source.type === 'agent') { return PanelAgentRefresh.run(this.namespace, id, spec, data || spec.data, cancellation); }
    const content = source.type === 'api' ? await new PanelApiTransport(new PanelCredentials(this.namespace)).read(id, source, cancellation) :
      source.type === 'json-url' ? (await new NativeWebTransport().get(source.url!, cancellation, 256 * 1024)).body :
      (await this.files.read(workspaceRelativePath(source.path!, false), cancellation)).content;
    cancellation.check();
    if (content.length > 256 * 1024) { throw new Error('Panel source exceeds 256 KiB'); }
    let parsed: Object;
    try { parsed = JSON.parse(content) as Object; } catch (_) { throw new Error('Panel source did not return valid JSON'); }
    return this.transform.run(panelPointer(parsed, source.pointer || ''), source.transform, cancellation, id);
  }
}
// NativeWorkspaceFiles owns path checks, no-follow access, atomic writes and compare-and-swap.
class PanelFiles extends NativeWorkspaceFiles {
  write(path: string, content: string, cancellation: Cancellation, guard?: WorkspaceWriteGuard): Promise<WorkspaceWrite> {
    return this.writeLifePanel(path, content, cancellation, guard);
  }
}
const refreshing: Map<string, Promise<PanelRecord>> = new Map<string, Promise<PanelRecord>>();
const refreshSignals: Map<string, Cancellation> = new Map<string, Cancellation>();
export class PanelRepository {
  private files: WorkspaceFiles;
  private key: string;
  private reader: PanelSourceReader;
  constructor(files: WorkspaceFiles, key: string, reader: PanelSourceReader) { this.files = files; this.key = key; this.reader = reader; }
  isRefreshing(id: string): boolean { return refreshing.has(this.key + ':' + panelId(id)); }
  async get(id: string): Promise<PanelRecord> { return parsePanelRecord((await this.files.read(panelPath(id), new Cancellation())).content, id); }
  async publish(id: string, definition: PanelSpec, sourcePath: string, threadId: string, update: boolean, cancellation: Cancellation): Promise<PanelRecord> {
    parsePanelSpec(JSON.stringify(definition));
    if (definition.source?.type === 'workspace-json') {
      const path = workspaceRelativePath(definition.source.path!, false);
      if (path.startsWith('life-panels/')) { throw new Error('Panel source must be outside managed panel storage'); }
    }
    return withFileMutation(this.key + ':' + panelId(id), async (): Promise<PanelRecord> => {
      cancellation.check();
      const path = panelPath(id), previous = update ? await this.files.read(path, cancellation) : undefined;
      const old = previous ? parsePanelRecord(previous.content, id) : undefined, now = Date.now();
      // A new definition explicitly supplies its initial snapshot. User edits are never copied into source data.
      const record: PanelRecord = { version: 1, id: id, definition: definition, configRevision: (old?.configRevision || 0) + 1,
        sourcePath: sourcePath, sourceThreadId: threadId, data: definition.data, user: old?.user || {},
        createdAt: old?.createdAt || now, updatedAt: now, refreshedAt: 0, attemptedAt: 0, error: '', archived: false,
        paused: old?.paused || false, runs: old?.runs || [] };
      validatePanelData(definition, record.data, record.user);
      await this.files.write(path, JSON.stringify(record), cancellation, { version: previous?.version || null });
      PanelChanges.emit();
      Diagnostics.log('info', 'life-panel', 'published', { previewId: id, revision: record.configRevision, nodes: definition.nodes.length });
      return record;
    });
  }
  private async mutate(id: string, action: (record: PanelRecord) => void, cancellation: Cancellation = new Cancellation()): Promise<PanelRecord> {
    return withFileMutation(this.key + ':' + panelId(id), async (): Promise<PanelRecord> => {
      cancellation.check();
      const path = panelPath(id), file = await this.files.read(path, cancellation), record = parsePanelRecord(file.content, id);
      action(record); validatePanelData(record.definition, record.data, record.user);
      await this.files.write(path, JSON.stringify(record), cancellation, { version: file.version }); PanelChanges.emit(); return record;
    });
  }
  async toggle(id: string, revision: number, nodeId: string, itemId: string, done: boolean): Promise<PanelRecord> {
    return this.mutate(id, (record: PanelRecord) => {
      const node = record.definition.nodes.find((node) => node.id === nodeId && node.kind === 'Checklist');
      if (record.archived || record.configRevision !== revision || !node || !panelItems(panelValue(node.items!, record.data, record.user)).some((item) => item.id === itemId)) { throw new Error('Panel changed; reopen before editing'); }
      record.user[nodeId + ':' + itemId] = done;
    });
  }
  async archive(id: string, archived: boolean): Promise<PanelRecord> {
    if (archived) { refreshSignals.get(this.key + ':' + panelId(id))?.cancel(); }
    return this.mutate(id, (record: PanelRecord) => { record.archived = archived; record.configRevision++; record.updatedAt = Date.now(); });
  }
  async pause(id: string, paused: boolean): Promise<PanelRecord> {
    if (paused) { refreshSignals.get(this.key + ':' + panelId(id))?.cancel(); }
    return this.mutate(id, (record: PanelRecord) => { record.paused = paused; record.configRevision++; });
  }
  async resize(id: string, size: string): Promise<PanelRecord> {
    if (!['S', 'M', 'L'].includes(size)) { throw new Error('Invalid card size'); }
    return this.mutate(id, (record: PanelRecord) => { record.definition.size = size; record.configRevision++; record.updatedAt = Date.now(); });
  }
  // All repository instances share one request per persistent ID. No duplicate manual/expiry fetches.
  refresh(id: string, cancellation: Cancellation): Promise<PanelRecord> {
    const key = this.key + ':' + panelId(id), existing = refreshing.get(key);
    if (existing) { return existing; }
    const signal = new Cancellation(), remove = cancellation.onCancel(() => signal.cancel()); refreshSignals.set(key, signal);
    const pending = this.fetch(id, signal).finally(() => { remove(); refreshing.delete(key); refreshSignals.delete(key); }); refreshing.set(key, pending); return pending;
  }
  private async fetch(id: string, cancellation: Cancellation): Promise<PanelRecord> {
    const before = await this.get(id), revision = before.configRevision, started = Date.now();
    cancellation.check();
    if (before.archived || !before.definition.source) { throw new Error('Panel has no active refresh source'); }
    const runId = util.generateRandomUUID();
    await this.mutate(id, (record: PanelRecord) => {
      if (record.configRevision !== revision || record.archived) { throw new Error('Panel changed before refresh started'); }
      const history = record.runs || [];
      history.filter((run) => run.status === 'running').forEach((run) => { run.status = 'interrupted'; run.finishedAt = started; });
      const run: PanelRun = { id: runId, startedAt: started, finishedAt: 0, status: 'running', error: '' };
      record.runs = [run].concat(history).slice(0, 10);
      record.attemptedAt = started;
    }, cancellation);
    Diagnostics.log('info', 'life-panel', 'refresh_started', { previewId: id, revision: revision });
    try {
      const data = await this.reader.read(before.definition, cancellation, id, before.data); cancellation.check();
      validatePanelData(before.definition, data, before.user);
      const record = await this.mutate(id, (current: PanelRecord) => {
        if (current.configRevision !== revision || current.archived) { throw new Error('Panel definition changed during refresh'); }
        current.data = data; current.refreshedAt = Date.now(); current.attemptedAt = started; current.error = '';
        const run = current.runs?.find((run) => run.id === runId); if (run) { run.status = 'complete'; run.finishedAt = Date.now(); }
      }, cancellation);
      Diagnostics.log('info', 'life-panel', 'refresh_complete', { previewId: id, elapsedMs: Date.now() - started }); return record;
    } catch (error) {
      Diagnostics.log(cancellation.cancelled ? 'info' : 'error', 'life-panel', cancellation.cancelled ? 'refresh_cancelled' : 'refresh_failed',
        { previewId: id, revision: revision, elapsedMs: Date.now() - started }, error as Error);
      await this.mutate(id, (current: PanelRecord) => {
        const run = current.runs?.find((run) => run.id === runId);
        if (run) { run.status = cancellation.cancelled ? 'cancelled' : 'failed'; run.finishedAt = Date.now(); run.error = cancellation.cancelled ? '' : (error as Error).message.slice(0, 1000); }
        if (!cancellation.cancelled && current.configRevision === revision && !current.archived) { current.error = (error as Error).message.slice(0, 1000); current.attemptedAt = started; }
      });
      throw error as Error;
    }
  }
}
export class LifePanels {
  private workspaces: WorkspaceStore;
  constructor(filesDir: string) { this.workspaces = new WorkspaceStore(filesDir); }
  createId(): string { return 'panel-' + util.generateRandomUUID(); }
  repository(workspaceId: string): PanelRepository {
    const root = this.workspaces.pathFor(workspaceId), files = new PanelFiles(root);
    return new PanelRepository(files, root, new NativePanelSourceReader(new NativeWorkspaceFiles(root), root));
  }
  credentials(workspaceId: string): PanelCredentials { return new PanelCredentials(this.workspaces.pathFor(workspaceId)); }
  installAgent(runner: PanelAgentRunner): void { PanelAgentRefresh.install(this.workspaces.rootDir, runner); }
  async list(workspaceId?: string): Promise<PanelEntry[]> {
    const entries: PanelEntry[] = [];
    if (!await fs.access(this.workspaces.rootDir)) { return entries; }
    for (const id of workspaceId ? [workspaceId] : await fs.listFile(this.workspaces.rootDir)) {
      await this.workspaces.requireWorkspace(id);
      const directory = this.workspaces.pathFor(id) + '/life-panels';
      if (!await fs.access(directory)) { continue; }
      const stat = await fs.lstat(directory);
      if (!stat.isDirectory() || stat.isSymbolicLink()) { throw new Error('Invalid Life Panel directory'); }
      for (const name of await fs.listFile(directory)) {
        const manifest = directory + '/' + panelId(name) + '/panel.json';
        // Empty directories can remain after an interrupted first publication.
        if (!await fs.access(manifest)) { continue; }
        try { entries.push({ workspaceId: id, panel: await this.repository(id).get(name) }); }
        catch (error) { Diagnostics.log('error', 'life-panel', 'manifest_failed', { sessionId: id, previewId: name }, error as Error); throw error as Error; }
      }
    }
    return entries.sort((a: PanelEntry, b: PanelEntry) => b.panel.createdAt - a.panel.createdAt);
  }
}
