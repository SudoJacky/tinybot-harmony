import { abilityAccessCtrl, bundleManager, common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { deviceInfo } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { AppData, ThreadData } from '../model/Conversation';
import { Diagnostics } from '../model/Diagnostics';
import { LogFields } from '../model/DiagnosticLog';
import { t } from '../model/I18n';
import { ProjectData } from '../model/Project';
import { PeerSettingsDelta, PeerThreadUpdate, parsePeerProject, parsePeerSettings, parsePeerThread, peerLiveMessage,
  peerProjectText, peerSettingsText, peerThreadText } from '../model/PeerSyncData';
import { RequestUsage } from '../model/Usage';
import { WorkspaceStore } from '../model/WorkspaceStore';
import { ArkDataRecords, RecordSource, StoredRecord } from './ArkDataRecords';
import { ArkDataWorkspace, isManagedWorkspaceRecord, WORKSPACE_DELETIONS, workspaceDeletion } from './ArkDataWorkspace';
import { NearbyItem, NearbyRecord, NearbySyncStore } from './NearbySyncStore';
import { NearbyFiles } from './NearbyFiles';
import { NearbyAttachments } from './NearbyAttachments';
import { ConversationDevice, nearbyConversations, peerConversationCollisionId } from './NearbyConversations';
import { PanelChanges } from './PanelChanges';
import { SessionService } from './SessionService';
import { PeerUsageUpdate, USAGE_SCOPE, UsageLedger } from './UsageLedger';

const INTERVAL_MS = 750;
const RESCAN_MS = 12000;
const VERSION = 23;
const PREFS = 'tinybot-nearby';
const PERMISSION = 'ohos.permission.DISTRIBUTED_DATASYNC';

interface AppIndex { metadata: string; }

function usageItem(text: string): RequestUsage {
  const item = JSON.parse(text) as RequestUsage;
  if (!item || typeof item.id !== 'string' || !item.id || !Number.isFinite(item.startedAt) ||
    !Number.isFinite(item.durationMs) || typeof item.model !== 'string' || typeof item.provider !== 'string' ||
    typeof item.status !== 'string') { throw new Error('Invalid synchronized usage'); }
  return item;
}

function itemKey(kind: string, id: string): string { return JSON.stringify([kind, id]); }
function isOrigin(id: string): boolean { return /^[0-9a-f-]{36}$/.test(id); }

class NearbySync {
  private context?: common.UIAbilityContext;
  private session?: SessionService;
  private database?: () => Promise<ArkDataRecords>;
  private config?: preferences.Preferences;
  private transport?: NearbySyncStore;
  private localStore?: ArkDataRecords;
  private files?: NearbyFiles;
  private allowed: boolean = false;
  private enabled: boolean = false;
  private ready: boolean = false;
  private origin: string = '';
  private timer: number = -1;
  private lifecycle: Promise<void> = Promise.resolve();
  private pending?: Promise<void>;
  private exchange?: Promise<void>;
  private lastExchangePush: boolean = false;
  private exchangeFailed: boolean = false;
  private nextPull: number = 0;
  private nextPush: number = 0;
  private peers: string[] = [];
  private needsPush: boolean = true;
  private remoteDirty: boolean = true;
  private outgoing: Map<string, NearbyItem> = new Map();
  private writing: Set<string> = new Set();
  private published: Map<string, string | undefined> = new Map();
  private seen: Map<string, number> = new Map();
  private localThreads: Set<string> = new Set();
  private liveDirty: Set<string> = new Set();
  private localLive: Set<string> = new Set();
  private sharedTurns: Map<string, string> = new Map();
  private workspaceConflict: boolean = false;

  bind(context: common.UIAbilityContext, session: SessionService, database: () => Promise<ArkDataRecords>): void {
    if (this.session) { return; }
    this.context = context; this.session = session; this.database = database;
    session.subscribe((event) => {
      if (!this.ready || !this.transport) { return; }
      if (event.threadId && ['message', 'text', 'reasoning', 'tool', 'thread'].includes(event.kind)) {
        this.liveDirty.add(event.threadId);
      }
    });
  }
  private storage(): preferences.Preferences {
    if (!this.config) { this.config = preferences.getPreferencesSync(this.context!, { name: PREFS }); }
    return this.config;
  }
  pauseForRecovery(): void {
    if (!this.context || deviceInfo.sdkApiVersion < VERSION) { return; }
    const config = this.storage();
    config.putSync('enabled', false); config.flushSync();
  }
  setAllowed(allowed: boolean): void {
    if (this.allowed === allowed) { return; }
    this.allowed = allowed;
    if (!allowed) { nearbyConversations.stop(); }
    this.change(async () => {
      if (!allowed) { await this.stop(); return; }
      if (deviceInfo.sdkApiVersion < VERSION) { return; }
      this.enabled = this.storage().getSync('enabled', false) === true;
      AppStorage.setOrCreate('tinybot.nearby.enabled', this.enabled);
      if (this.enabled && !this.transport) { await this.start(); }
    }).catch((error: Error) => this.report(error));
  }
  setEnabled(enabled: boolean, context: common.UIAbilityContext): Promise<void> {
    return this.change(async () => {
      if (!this.allowed || !this.context || deviceInfo.sdkApiVersion < VERSION) {
        throw new Error(t('附近设备同步需要支持分布式数据库的设备。'));
      }
      if (enabled) {
        const manager = abilityAccessCtrl.createAtManager();
        const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
        if (manager.checkAccessTokenSync(info.appInfo.accessTokenId, PERMISSION) !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
          const result = await manager.requestPermissionsFromUser(context, [PERMISSION]);
          if (result.authResults[0] !== 0) { throw new Error(t('请允许连接附近设备后再开启同步。')); }
        }
        if (!this.allowed) { return; }
        if (!this.transport) { await this.start(); }
      }
      const config = this.storage();
      config.putSync('enabled', enabled); config.flushSync();
      this.enabled = enabled; AppStorage.setOrCreate('tinybot.nearby.enabled', enabled);
      if (!enabled) { await this.stop(); }
    }).catch((error: Error) => { this.report(error); throw error; });
  }
  private change(action: () => Promise<void>): Promise<void> {
    const result = this.lifecycle.then(action);
    this.lifecycle = result.catch(() => {});
    return result;
  }
  private report(error: Error): void {
    AppStorage.setOrCreate('tinybot.nearby.status', t('附近设备同步失败：{0}', [error.message]));
    Diagnostics.log('warn', 'sync', 'nearby_failed', undefined, error);
  }
  private async start(): Promise<void> {
    const config = this.storage();
    this.origin = config.getSync('origin', '') as string;
    if (!isOrigin(this.origin)) {
      this.origin = util.generateRandomUUID();
      config.putSync('origin', this.origin); config.flushSync();
    }
    const transport = await NearbySyncStore.open(this.context!, this.origin, () => { this.remoteDirty = true; });
    this.transport = transport;
    try {
      const db = await this.database!();
      this.localStore = db;
      this.files = new NearbyFiles(this.context!, this.origin, db, (item: NearbyItem) => this.queue(item), (error: Error) => this.report(error));
      await this.files.open();
      db.onCommitted = (records: StoredRecord[], source: RecordSource) => {
        if (source === 'peer') { return; }
        try { this.capture(records); } catch (error) { this.report(error as Error); }
      };
      const snapshot = this.session!.snapshot();
      this.settings(snapshot);
      for (const thread of snapshot.threads) { this.thread(thread); }
      const old = await transport.localItems();
      for (const item of old) {
        if (item.kind === 'thread' && !this.localThreads.has(item.id)) { this.queue({ kind: 'thread', id: item.id }); }
        if (item.kind === 'live') { this.queue({ kind: 'live', id: item.id }); }
      }
      const usage = await UsageLedger.backup(this.context!.filesDir);
      for (const item of usage) { this.usage(item); }
      const workspaces = new WorkspaceStore(this.context!.getApplicationContext().filesDir);
      if (await fs.access(workspaces.rootDir)) {
        for (const id of await fs.listFile(workspaces.rootDir)) {
          if (!(await fs.lstat(workspaces.pathFor(id))).isDirectory()) { continue; }
          for (const path of await db.ids('workspace:' + id)) {
            const text = await db.read('workspace:' + id, path);
            if (text !== undefined) { this.queue({ kind: 'workspace', id: id + '/' + path, text: text }); }
          }
        }
      }
      for (const id of await db.ids(WORKSPACE_DELETIONS)) {
        const text = await db.read(WORKSPACE_DELETIONS, id);
        if (text === undefined || !workspaceDeletion(text)) { throw new Error('Workspace deletion is missing its base revision'); }
        this.queue({ kind: 'workspace', id: id, text: text });
      }
      this.ready = true;
      nearbyConversations.start(this.context!, this.session!, this.origin, () => transport.localNetworkId(), () =>
        transport.availableDevices().map((item): ConversationDevice => ({ id: item.networkId!, name: item.deviceName })), db,
        new NearbyAttachments(this.context!, (id: string) => this.files!.connect(id)));
      AppStorage.setOrCreate('tinybot.nearby.status', t('正在查找附近设备…'));
      this.timer = setInterval(() => { this.tick(); }, INTERVAL_MS);
      this.tick();
    } catch (error) {
      await this.stop(); throw error as Error;
    }
  }
  private async stop(): Promise<void> {
    this.ready = false;
    nearbyConversations.stop();
    if (this.timer >= 0) { clearInterval(this.timer); this.timer = -1; }
    if (this.localStore) { this.localStore.onCommitted = undefined; this.localStore = undefined; }
    await this.pending;
    await this.exchange;
    const files = this.files; this.files = undefined;
    const transport = this.transport; this.transport = undefined;
    this.outgoing.clear(); this.published.clear(); this.seen.clear(); this.localThreads.clear();
    this.liveDirty.clear(); this.localLive.clear(); this.sharedTurns.clear(); this.peers = [];
    this.session?.clearPeerProgress();
    this.nextPull = 0; this.nextPush = 0; this.needsPush = true; this.remoteDirty = true;
    this.lastExchangePush = false; this.exchangeFailed = false;
    this.workspaceConflict = false;
    AppStorage.setOrCreate('tinybot.nearby.status', '');
    try { if (files) { await files.close(); } }
    finally { if (transport) { await transport.close(); } }
  }
  private queue(item: NearbyItem): void {
    const key = itemKey(item.kind, item.id);
    if (!this.writing.has(key) && this.published.has(key) && this.published.get(key) === item.text) {
      this.outgoing.delete(key); return;
    }
    this.outgoing.set(key, item);
  }
  private thread(thread: ThreadData): void {
    if (thread.peerOwner) {
      if (this.localThreads.delete(thread.id)) {
        this.queue({ kind: 'thread', id: thread.id }); this.queue({ kind: 'live', id: thread.id });
      }
      return;
    }
    if (!thread.messages.length && !thread.projectId && !thread.titleEdited && !thread.archived && !thread.pinned) {
      if (this.localThreads.delete(thread.id)) { this.queue({ kind: 'thread', id: thread.id }); }
      return;
    }
    this.localThreads.add(thread.id);
    this.liveDirty.add(thread.id);
    const answer = thread.messages[thread.messages.length - 1];
    if (answer?.status === 'generating') {
      if (this.sharedTurns.get(thread.id) === answer.id) { return; }
      this.sharedTurns.set(thread.id, answer.id);
    } else { this.sharedTurns.delete(thread.id); }
    this.queue({ kind: 'thread', id: thread.id, text: peerThreadText(thread) });
  }
  private usage(item: RequestUsage): void {
    if (!UsageLedger.isPeer(item.id) && item.status !== 'running_or_unknown') { this.queue({ kind: 'usage', id: item.id, text: JSON.stringify(item) }); }
  }
  private settings(data: AppData): void {
    for (const project of data.projects || []) { this.queue({ kind: 'project', id: project.id, text: peerProjectText(project) }); }
    this.queue({ kind: 'settings', id: 'public', text: peerSettingsText(data) });
  }
  private capture(records: StoredRecord[]): void {
    for (const record of records) {
      if (record.scope === 'thread') {
        if (record.text !== undefined) { this.thread(JSON.parse(record.text) as ThreadData); }
        else if (this.localThreads.delete(record.id)) {
          this.queue({ kind: 'thread', id: record.id }); this.queue({ kind: 'live', id: record.id });
        }
      } else if (record.scope === 'app' && record.id === 'index' && record.text) {
        const index = JSON.parse(record.text) as AppIndex;
        this.settings(JSON.parse(index.metadata) as AppData);
      } else if (record.scope === USAGE_SCOPE && record.text) {
        this.usage(usageItem(record.text));
      } else if (record.scope === WORKSPACE_DELETIONS && record.text !== undefined) {
        this.queue({ kind: 'workspace', id: record.id, text: record.text });
      } else if (record.scope.startsWith('workspace:') && isManagedWorkspaceRecord(record.id) && record.text !== undefined) {
        const id = record.scope.slice(10) + '/' + record.id;
        this.queue({ kind: 'workspace', id: id, text: record.text });
      }
    }
  }
  private tick(): void {
    if (!this.ready || !this.transport || this.pending) { return; }
    this.pending = this.drain(this.transport).catch((error: Error) => this.report(error)).finally(() => { this.pending = undefined; });
  }
  private async drain(transport: NearbySyncStore): Promise<void> {
    for (const id of this.liveDirty) {
      if (!this.localThreads.has(id)) { continue; }
      const answer = this.session!.liveAnswer(id);
      if (answer) { this.localLive.add(id); this.queue({ kind: 'live', id: id, text: JSON.stringify(answer) }); }
      else if (this.localLive.delete(id)) { this.queue({ kind: 'live', id: id }); }
    }
    this.liveDirty.clear();
    const waiting = Array.from(this.outgoing.values());
    const priority = waiting.filter((item) => item.kind === 'live' || item.kind === 'thread' && this.localLive.has(item.id));
    const prioritized = new Set<NearbyItem>(priority);
    const batch: NearbyItem[] = [];
    let size = 0;
    for (const item of priority.concat(waiting.filter((record) => !prioritized.has(record)))) {
      if (batch.length >= 50 || size >= 1024 * 1024) { break; }
      batch.push(item); size += item.text?.length || 0;
    }
    if (batch.length) {
      const tracing = Diagnostics.acceptsLog('info'), started = tracing ? Diagnostics.now() : 0;
      const exchangeActive = this.exchange ? 1 : 0;
      for (const item of batch) { this.writing.add(itemKey(item.kind, item.id)); }
      try { await transport.write(batch); }
      finally { this.writing.clear(); }
      for (const item of batch) {
        const key = itemKey(item.kind, item.id);
        if (this.outgoing.get(key) === item) { this.outgoing.delete(key); }
        this.published.set(key, item.text);
      }
      this.needsPush = true;
      if (tracing) { Diagnostics.log('info', 'sync', 'nearby_flush', {
        count: batch.length, active: exchangeActive, durationMs: Diagnostics.now() - started
      }); }
    }
    const devices = transport.devices();
    this.files?.tick(devices);
    if (devices.join(',') !== this.peers.join(',')) {
      this.peers = devices; this.nextPull = 0; this.nextPush = 0; this.needsPush = true;
      this.exchangeFailed = false;
      nearbyConversations.refreshDevices();
      if (!devices.length) { this.session!.clearPeerProgress(); this.seen.clear(); }
    }
    const now = Date.now();
    if (this.remoteDirty) {
      this.remoteDirty = false;
      try { await this.receive(transport); }
      catch (error) { this.remoteDirty = true; throw error as Error; }
    }
    this.scheduleExchange(transport, devices, now);
    if (!this.exchangeFailed && !this.workspaceConflict) {
      AppStorage.setOrCreate('tinybot.nearby.status', devices.length ?
        t('已发现 {0} 台附近设备', [devices.length]) : t('等待附近设备打开 Tinybot'));
    }
  }
  private scheduleExchange(transport: NearbySyncStore, devices: string[], now: number): void {
    if (!this.ready || this.exchange || !devices.length) { return; }
    const pushDue = this.needsPush && now >= this.nextPush;
    const pullDue = now >= this.nextPull;
    if (!pushDue && !pullDue) { return; }
    const push = pushDue && (!pullDue || !this.lastExchangePush);
    this.lastExchangePush = push;
    if (push) { this.needsPush = false; this.nextPush = now + INTERVAL_MS; }
    else { this.nextPull = now + RESCAN_MS; }
    const tracing = Diagnostics.acceptsLog('info'), started = tracing ? Diagnostics.now() : 0;
    this.exchange = transport.exchange(devices, push).then(() => {
      this.exchangeFailed = false;
      if (!push) { this.remoteDirty = true; }
      if (tracing) {
        const fields: LogFields = { count: devices.length, durationMs: Diagnostics.now() - started };
        if (push) { Diagnostics.log('info', 'sync', 'nearby_push', fields); }
        else { Diagnostics.log('info', 'sync', 'nearby_pull', fields); }
      }
    }).catch((error: Error) => {
      this.exchangeFailed = true;
      if (push) { this.needsPush = true; this.nextPush = Date.now() + 2500; }
      this.report(error);
    }).finally(() => { this.exchange = undefined; this.tick(); });
  }
  private async receive(transport: NearbySyncStore): Promise<void> {
    const projects: ProjectData[] = [], threads: PeerThreadUpdate[] = [], settings: PeerSettingsDelta[] = [];
    const settingRecords: StoredRecord[] = [];
    const records = await transport.remoteItems(this.seen);
    const applied: NearbyRecord[] = [];
    for (const record of records) {
      if (record.kind === 'project' && record.text !== undefined) {
        projects.push(parsePeerProject(record.text, record.id)); applied.push(record);
      }
    }
    for (const record of records) {
      if (!isOrigin(record.origin)) { throw new Error('Invalid nearby device identifier'); }
      if (record.kind === 'thread') {
        const thread = record.text === undefined ? undefined : parsePeerThread(record.text, record.id);
        if (thread?.projectId && !this.session!.hasProject(thread.projectId) && !projects.some((item) => item.id === thread.projectId)) { continue; }
        const id = await peerConversationCollisionId(record.origin, record.id);
        threads.push({ origin: record.origin, id: record.id, collisionId: id, thread: thread }); applied.push(record);
      } else if (record.kind === 'settings' && record.text !== undefined) {
        const previous = await this.localStore!.read('nearby-settings', record.origin);
        settings.push({ origin: record.origin, current: parsePeerSettings(record.text), previous: previous === undefined ? undefined : parsePeerSettings(previous) });
        settingRecords.push({ scope: 'nearby-settings', id: record.origin, text: record.text });
        applied.push(record);
      }
    }
    if (projects.length || threads.length || settings.length) {
      await this.session!.receivePeerChanges(projects, threads, settings, this.origin);
    }
    if (settingRecords.length) { await this.localStore!.commit(settingRecords); }
    const usage: PeerUsageUpdate[] = [];
    for (const record of records) {
      if (record.kind === 'usage' && record.text !== undefined) {
        const item = usageItem(record.text);
        if (item.id !== record.id) { throw new Error('Synchronized usage does not match its identifier'); }
        usage.push({ origin: record.origin, revision: record.revision, item: item }); applied.push(record);
      }
      else if (record.kind === 'file') { this.files?.receive(record); applied.push(record); }
      else if (record.kind === 'workspace') { await this.receiveWorkspace(record); applied.push(record); }
      else if (record.kind === 'live') {
        if (record.text === undefined) { this.session!.clearPeerProgress(record.origin, record.id); applied.push(record); }
        else if (this.session!.receivePeerAnswer(record.origin, record.id, peerLiveMessage(record.text))) { applied.push(record); }
      }
    }
    if (usage.length) { await UsageLedger.receivePeer(this.context!.filesDir, usage); }
    for (const record of applied) { transport.mark(this.seen, record); }
  }
  private async receiveWorkspace(record: NearbyRecord): Promise<void> {
    const index = record.id.indexOf('/'), id = record.id.slice(0, index), path = record.id.slice(index + 1);
    if (index <= 0 || !isManagedWorkspaceRecord(path) || !this.localStore) { throw new Error('Invalid synchronized workspace record'); }
    const workspaces = new WorkspaceStore(this.context!.getApplicationContext().filesDir);
    const workspace = ArkDataWorkspace.forRoot(workspaces.pathFor(id));
    if (!workspace) { throw new Error('Workspace database is not registered'); }
    if (record.text === undefined) {
      // Old transports have no base to verify. Surface the unapplied deletion
      // without repeatedly blocking unrelated records in the same sync batch.
      this.workspaceConflict = true;
      AppStorage.setOrCreate('tinybot.nearby.status', t('收到旧版删除记录，无法核实删除前版本，已保留本机内容。请核对相关看板和卡片。'));
      Diagnostics.log('warn', 'sync', 'workspace_delete_unversioned', { sessionId: id });
      return;
    }
    if (!workspaceDeletion(record.text)) { await workspaces.ensureThread(id); }
    if (await workspace.receive(path, record.text)) {
      this.workspaceConflict = true;
      AppStorage.setOrCreate('tinybot.nearby.status', t('看板或卡片的删除与编辑发生冲突，已保留编辑内容。'));
      Diagnostics.log('warn', 'sync', 'workspace_delete_conflict', { sessionId: id });
    }
    PanelChanges.emit();
  }
}

export const nearbySync = new NearbySync();
