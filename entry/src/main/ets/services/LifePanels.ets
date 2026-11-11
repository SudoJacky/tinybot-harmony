import { PanelInputs, resolvePanelInputs, reconcilePanelInputs } from '../model/PanelContract';
import { ToolFailure } from '../model/ToolFailure';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { WorkspaceStore } from '../model/WorkspaceStore';
import { Diagnostics } from '../model/Diagnostics';
import { PanelSpec, PanelRecord, PanelEntry, PanelRun, panelId, panelPath, panelPointer, panelValue, panelItems, parsePanelSpec, parsePanelRecord, validatePanelData, panelDue } from '../model/LifePanel';
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
import { MailService } from './MailService';
import { MailBody, MailReadRequest } from '../model/Mail';
import { imapNumber } from '../model/ImapWire';
import { ProviderBalanceSource } from './ProviderBalanceSource';
import { threadWorkspacePath } from '../model/Workspace';
import { PanelSource, panelQueryAddress } from '../model/PanelSource';
import { withWorkspaceLifecycle } from './WorkspaceRetention';
import { PanelTaskFailure } from './PanelTaskFailure';
import { PanelListQuery, PanelListPage, PanelSummary } from '../model/LifePanel';
import { validatePanelViewState } from '../model/LifePanel';
import { WebUiStorage, WebUiSnapshot } from '../model/WebUi';
export interface PanelPublishOptions { replaceData?: boolean; expectedRevision?: number; publicationKey?: string; sourceVerified?: boolean; }
interface PanelCursor { version: number; after: string; workspaceId: string; archived: boolean; }

export interface PanelSourceReader { read(spec: PanelSpec, cancellation: Cancellation, id?: string, data?: Object, inputs?: PanelInputs): Promise<Object>; validate?(spec: PanelSpec, cancellation: Cancellation): Promise<void>; }
export class NativePanelSourceReader implements PanelSourceReader {
  private files: WorkspaceFiles;
  private namespace: string;
  private transform: PanelDataTransform;
  constructor(files: WorkspaceFiles, namespace: string = '', executor: CodeExecutor = new NativeCodeExecutor()) {
    this.files = files; this.namespace = namespace; this.transform = new PanelDataTransform(executor);
  }
  private async local(source: PanelSource, cancellation: Cancellation): Promise<string> {
    let files = this.files;
    if (source.workspaceId !== undefined) {
      if (!this.namespace) { throw new Error('Explicit source workspace requires a native workspace context'); }
      const root = this.namespace.slice(0, this.namespace.lastIndexOf('/')), target = threadWorkspacePath(root, source.workspaceId);
      for (const directory of [root, target]) {
        const stat = await fs.lstat(directory);
        if (!stat.isDirectory() || stat.isSymbolicLink()) { throw new Error('Invalid source workspace'); }
      }
      files = new NativeWorkspaceFiles(target);
    }
    const path = workspaceRelativePath(source.path!, false);
    if (/^(life-panels|life-boards|mini-apps)\//.test(path)) { throw new Error('Local card sources must be outside managed artifact storage'); }
    return (await files.read(path, cancellation)).content;
  }
  async validate(spec: PanelSpec, cancellation: Cancellation): Promise<void> {
    if (spec.source?.type !== 'workspace-json') { return; }
    const content = await this.local(spec.source, cancellation);
    if (content.length > 256 * 1024) { throw new Error('Panel source exceeds 256 KiB'); }
    try { JSON.parse(content); } catch (_) { throw new Error('Panel source did not return valid JSON'); }
  }
  async read(spec: PanelSpec, cancellation: Cancellation, id: string = '', data?: Object, inputs?: PanelInputs): Promise<Object> {
    const source = spec.source;
    if (!source) { throw new Error('This panel has no refreshable source'); }
    if (source.type === 'provider-balance') { return ProviderBalanceSource.read(source.providerIds!, inputs || {}, cancellation); }
    if (source.type === 'agent') { return PanelAgentRefresh.run(this.namespace, id, spec, data || spec.data, cancellation, inputs); }
    if (source.type === 'mail') {
      const snapshot = await new MailService().query(source.mail!, cancellation); cancellation.check();
      return this.transform.run(panelPointer(snapshot, source.pointer || ''), source.transform, cancellation, id);
    }
    const content = source.type === 'api' ? await new PanelApiTransport(new PanelCredentials(this.namespace)).read(id, source, cancellation, inputs) :
      source.type === 'json-url' ? (await new NativeWebTransport().get(panelQueryAddress(source, inputs), cancellation, 256 * 1024)).body :
      await this.local(source, cancellation);
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
const refreshTriggers: Map<string, string> = new Map<string, string>();
export class PanelRepository {
  private files: WorkspaceFiles;
  private key: string;
  private reader: PanelSourceReader;
  constructor(files: WorkspaceFiles, key: string, reader: PanelSourceReader) { this.files = files; this.key = key; this.reader = reader; }
  isRefreshing(id: string): boolean { return refreshing.has(this.key + ':' + panelId(id)); }
  async get(id: string): Promise<PanelRecord> { return parsePanelRecord((await this.files.read(panelPath(id), new Cancellation())).content, id); }
  async readMail(id: string, configRevision: number, request: MailReadRequest, cancellation: Cancellation): Promise<MailBody> {
    cancellation.check(); imapNumber(request.uidValidity); imapNumber(request.uid);
    const before = await this.get(id), source = before.definition.source;
    if (before.archived || before.configRevision !== configRevision || source?.type !== 'mail' || !source.mail) {
      throw new Error('Card has no active mail source or has changed; reopen it before reading mail');
    }
    const body = await new MailService().read(source.mail.accountId, source.mail.folder, request.uidValidity, request.uid, cancellation);
    cancellation.check();
    const current = await this.get(id); cancellation.check();
    if (current.archived || current.configRevision !== configRevision) { throw new Error('Card changed while reading mail; reopen it'); }
    return body;
  }
  async lookup(id: string): Promise<PanelRecord | undefined> {
    const cancellation = new Cancellation(); panelId(id);
    let offset = 0, hasDirectory = false;
    do {
      const page = await this.files.list('', cancellation, offset);
      hasDirectory = page.entries.some((entry) => entry.name === 'life-panels');
      if (hasDirectory || !page.truncated) { break; } offset = page.nextOffset!;
    } while (true);
    if (!hasDirectory) { return undefined; }
    offset = 0;
    do {
      const page = await this.files.list('life-panels', cancellation, offset);
      if (page.entries.some((entry) => entry.name === id)) { return this.get(id); }
      if (!page.truncated) { return undefined; } offset = page.nextOffset!;
    } while (true);
  }

  binding(id: string, configRevision: number): WebUiStorage { return new PanelStorage(this, id, configRevision); }
  async saveViewState(id: string, configRevision: number, value: Object | null, revision: string): Promise<WebUiSnapshot> {
    const snapshot: WebUiSnapshot = { value: value, revision: util.generateRandomUUID() };
    validatePanelViewState(snapshot);
    const record = await this.mutate(id, (record: PanelRecord) => {
      if (record.archived || !record.definition.view || record.configRevision !== configRevision) { throw new Error('Card changed; reopen before editing'); }
      if ((record.viewState?.revision || 'initial') !== revision) { throw new Error('Card state changed; reload before saving'); }
      record.viewState = snapshot;
    });
    return record.viewState!;
  }
  async probe(spec: PanelSpec, id: string, data: Object, inputs: PanelInputs, cancellation: Cancellation): Promise<Object> {
    await this.reader.validate?.(spec, cancellation);
    const result = spec.source ? await this.reader.read(spec, cancellation, id, data, resolvePanelInputs(spec.inputs, inputs)) : data;
    validatePanelData(spec, result, {}); return result;
  }
  async recordRuntimeError(id: string, revision: number, message: string): Promise<void> {
    await this.mutate(id, (record: PanelRecord): boolean => {
      if (record.configRevision !== revision || record.runtimeError === message.slice(0, 4000)) { return false; }
      record.runtimeError = message.slice(0, 4000); return true;
    });
  }
  async publish(id: string, definition: PanelSpec, sourcePath: string, threadId: string, update: boolean, cancellation: Cancellation, options: PanelPublishOptions = {}): Promise<PanelRecord> {
    parsePanelSpec(JSON.stringify(definition));
    if (definition.source?.type === 'workspace-json') {
      const path = workspaceRelativePath(definition.source.path!, false);
      if (path.startsWith('life-panels/')) { throw new Error('Panel source must be outside managed panel storage'); }
    }
    return withWorkspaceLifecycle(this.key, () => withFileMutation(this.key + ':' + panelId(id), async (): Promise<PanelRecord> => {
      cancellation.check();
      await this.reader.validate?.(definition, cancellation);
      const path = panelPath(id), previous = update ? await this.files.read(path, cancellation) : undefined;
      const old = previous ? parsePanelRecord(previous.content, id) : undefined, now = Date.now();
      if (options.expectedRevision !== undefined && old?.configRevision !== options.expectedRevision) { throw new ToolFailure('PANEL_REVISION_CONFLICT', 'Card changed during editing; read current definition and validate again', 'read_current_card'); }
      const preserve = !!old && !options.replaceData;
      const sameSource = !!old && JSON.stringify(old.definition.source) === JSON.stringify(definition.source);
      // View edits preserve live data. Replacing source data must be explicit and validated.
      const record: PanelRecord = { version: 1, id: id, definition: definition, configRevision: (old?.configRevision || 0) + 1,
        layout: old?.layout || { size: old?.definition.size || definition.size },
        sourcePath: sourcePath, sourceThreadId: threadId, data: preserve ? old!.data : definition.data, user: old?.user || {},
        createdAt: old?.createdAt || now, updatedAt: now, refreshedAt: preserve ? sameSource ? old!.refreshedAt : 0 : options.sourceVerified ? now : 0, attemptedAt: preserve && sameSource ? old!.attemptedAt : 0, error: preserve && sameSource ? old!.error : '', archived: false,
        paused: old?.paused || false, runs: old?.runs || [], viewState: old?.viewState, inputs: reconcilePanelInputs(definition.inputs, old?.inputs || {}), runtimeError: '', publicationKey: options.publicationKey || old?.publicationKey };
      validatePanelData(definition, record.data, record.user);
      await this.files.write(path, JSON.stringify(record), cancellation, { version: previous?.version || null });
      PanelChanges.emit();
      Diagnostics.log('info', 'life-panel', 'published', { previewId: id, revision: record.configRevision, nodes: definition.nodes.length });
      return record;
    }));
  }
  private async mutate(id: string, action: (record: PanelRecord) => void | boolean, cancellation: Cancellation = new Cancellation()): Promise<PanelRecord> {
    return withFileMutation(this.key + ':' + panelId(id), async (): Promise<PanelRecord> => {
      cancellation.check();
      const path = panelPath(id), file = await this.files.read(path, cancellation), record = parsePanelRecord(file.content, id);
      if (action(record) === false) { return record; } validatePanelData(record.definition, record.data, record.user);
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
    const key = this.key + ':' + panelId(id);
    if (paused && refreshTriggers.get(key) === 'automatic') { refreshSignals.get(key)?.cancel(); }
    return this.mutate(id, (record: PanelRecord) => { record.paused = paused; });
  }
  async resize(id: string, size: string): Promise<PanelRecord> {
    if (!['S', 'M', 'L'].includes(size)) { throw new Error('Invalid card size'); }
    // Layout never invalidates content-bound storage, edits or in-flight refreshes.
    return this.mutate(id, (record: PanelRecord) => { record.layout = { size: size }; record.updatedAt = Date.now(); });
  }
  // All repository instances share one request per persistent ID. No duplicate manual/expiry fetches.
  refresh(id: string, cancellation: Cancellation, trigger: string = 'manual', inputs?: PanelInputs): Promise<PanelRecord> {
    if (!['manual', 'automatic'].includes(trigger)) { throw new Error('Invalid panel refresh trigger'); }
    const key = this.key + ':' + panelId(id), existing = refreshing.get(key);
    if (existing) { return inputs ? Promise.reject(new ToolFailure('PANEL_BUSY', 'Wait for the current refresh before changing inputs', 'wait_then_retry')) : existing; }
    const signal = new Cancellation(), remove = cancellation.onCancel(() => signal.cancel()); refreshSignals.set(key, signal); refreshTriggers.set(key, trigger);
    const pending = this.fetch(id, signal, trigger, inputs).finally(() => { remove(); refreshing.delete(key); refreshSignals.delete(key); refreshTriggers.delete(key); }); refreshing.set(key, pending); return pending;
  }
  private async fetch(id: string, cancellation: Cancellation, trigger: string, inputs?: PanelInputs): Promise<PanelRecord> {
    const started = Date.now(); let revision = 0, admitted = false;
    cancellation.check();
    const runId = util.generateRandomUUID();
    const before = await this.mutate(id, (record: PanelRecord): boolean => {
      if (trigger === 'automatic' && !panelDue(record, started)) { return false; }
      if (record.archived || !record.definition.source) { throw new Error('Panel has no active refresh source'); }
      const requested: PanelInputs = {};
      for (const name of Object.keys(record.inputs || ({} as PanelInputs))) { requested[name] = record.inputs![name]; }
      for (const name of Object.keys(inputs || ({} as PanelInputs))) { requested[name] = inputs![name]; }
      record.inputs = resolvePanelInputs(record.definition.inputs, requested);
      revision = record.configRevision; admitted = true;
      const history = record.runs || [];
      history.filter((run) => run.status === 'running').forEach((run) => { run.status = 'interrupted'; run.finishedAt = started; });
      const run: PanelRun = { id: runId, startedAt: started, finishedAt: 0, status: 'running', error: '', trigger: trigger };
      record.runs = [run].concat(history).slice(0, 10);
      record.attemptedAt = started;
      return true;
    }, cancellation);
    if (!admitted) { Diagnostics.log('debug', 'life-panel', 'refresh_skipped', { previewId: id }); return before; }
    Diagnostics.log('info', 'life-panel', 'refresh_started', { previewId: id, revision: revision });
    try {
      const data = await this.reader.read(before.definition, cancellation, id, before.data, before.inputs); cancellation.check();
      try { validatePanelData(before.definition, data, before.user); }
      catch (error) { if (before.definition.source?.type === 'agent' && !(error instanceof ToolFailure)) { throw new PanelTaskFailure('validation', 'DATA_INVALID'); } throw error as Error; }
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
        if (run && !cancellation.cancelled && error instanceof PanelTaskFailure) { run.failure = error.info; }
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
  async page(query: PanelListQuery): Promise<PanelListPage> {
    if (Object.keys(query).some((key: string) => !['workspaceId', 'archived', 'limit', 'cursor'].includes(key)) ||
      query.workspaceId !== undefined && typeof query.workspaceId !== 'string' || query.archived !== undefined && typeof query.archived !== 'boolean' ||
      query.limit !== undefined && (!Number.isInteger(query.limit) || query.limit < 1 || query.limit > 20) ||
      query.cursor !== undefined && (typeof query.cursor !== 'string' || query.cursor.length > 1024)) { throw new Error('Invalid Life Panel list query'); }
    const archived = query.archived === true, limit = query.limit || 10; let after = '';
    if (query.workspaceId !== undefined) { this.workspaces.pathFor(query.workspaceId); }
    if (query.cursor) {
      const cursor = JSON.parse(decodeURIComponent(query.cursor)) as PanelCursor;
      if (cursor.version !== 1 || typeof cursor.after !== 'string' || cursor.workspaceId !== (query.workspaceId || '') || cursor.archived !== archived) { throw new Error('Cursor does not match this card list query'); }
      after = cursor.after;
    }
    const refs: string[] = [];
    if (await fs.access(this.workspaces.rootDir)) {
      for (const workspaceId of query.workspaceId ? [query.workspaceId] : await fs.listFile(this.workspaces.rootDir)) {
        await this.workspaces.requireWorkspace(workspaceId);
        const directory = this.workspaces.pathFor(workspaceId) + '/life-panels'; if (!await fs.access(directory)) { continue; }
        const stat = await fs.lstat(directory); if (!stat.isDirectory() || stat.isSymbolicLink()) { throw new Error('Invalid Life Panel directory'); }
        for (const id of await fs.listFile(directory)) { panelId(id); if (await fs.access(directory + '/' + id + '/panel.json')) { refs.push(workspaceId + '/' + id); } }
      }
    }
    const remaining = refs.sort().filter((key: string) => key > after), items: PanelSummary[] = [];
    let scanned = 0;
    while (scanned < remaining.length && scanned < 50 && items.length < limit) {
      const key = remaining[scanned++], split = key.indexOf('/'), workspaceId = key.slice(0, split), id = key.slice(split + 1);
      const repository = this.repository(workspaceId), record = await repository.get(id); if (record.archived !== archived) { continue; }
      const status = record.runs?.[0]?.status || 'idle';
      items.push({ workspaceId: workspaceId, panelId: id, title: record.definition.title, size: record.layout?.size || record.definition.size, sourceType: record.definition.source?.type || 'static',
        sourceWorkspaceId: record.definition.source?.type === 'workspace-json' ? record.definition.source.workspaceId || workspaceId : undefined,
        archived: record.archived, paused: record.paused === true, updatedAt: record.updatedAt, refreshedAt: record.refreshedAt,
        taskStatus: status === 'running' && !repository.isRefreshing(id) ? 'interrupted' : status, error: record.error.slice(0, 300) });
    }
    const cursor: PanelCursor = { version: 1, after: remaining[scanned - 1] || after, workspaceId: query.workspaceId || '', archived: archived };
    return { items: items, nextCursor: scanned < remaining.length ? encodeURIComponent(JSON.stringify(cursor)) : undefined };
  }
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

class PanelStorage implements WebUiStorage {
  private repository: PanelRepository;
  private id: string;
  private configRevision: number;
  constructor(repository: PanelRepository, id: string, configRevision: number) {
    this.repository = repository; this.id = id; this.configRevision = configRevision;
  }
  async load(): Promise<WebUiSnapshot> {
    const record = await this.repository.get(this.id);
    const initial: WebUiSnapshot = { value: null, revision: 'initial' };
    return record.viewState || initial;
  }
  save(value: Object | null, revision: string): Promise<WebUiSnapshot> {
    return this.repository.saveViewState(this.id, this.configRevision, value, revision);
  }
}
