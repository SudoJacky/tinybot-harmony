import { abilityAccessCtrl, bundleManager, common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { deviceInfo } from '@kit.BasicServicesKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { AppData, ThreadData } from '../model/Conversation';
import { Diagnostics } from '../model/Diagnostics';
import { t } from '../model/I18n';
import { parseLifeBoard } from '../model/LifeBoard';
import { parsePanelRecord } from '../model/LifePanel';
import { ProjectData } from '../model/Project';
import { PeerSettingsDelta, PeerThreadUpdate, parsePeerProject, parsePeerSettings, parsePeerThread, peerLiveMessage,
  peerProjectText, peerSettingsText, peerThreadText } from '../model/PeerSyncData';
import { RequestUsage } from '../model/Usage';
import { WorkspaceStore } from '../model/WorkspaceStore';
import { ArkDataRecords, StoredRecord } from './ArkDataRecords';
import { isManagedWorkspaceRecord } from './ArkDataWorkspace';
import { NearbyItem, NearbyRecord, NearbySyncStore } from './NearbySyncStore';
import { NearbyFiles } from './NearbyFiles';
import { PanelChanges } from './PanelChanges';
import { SessionService } from './SessionService';
import { USAGE_SCOPE, UsageLedger } from './UsageLedger';

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
  private applyingWorkspace: Set<string> = new Set();

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
      db.onCommitted = (records: StoredRecord[]) => {
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
      this.ready = true;
      AppStorage.setOrCreate('tinybot.nearby.status', t('正在查找附近设备…'));
      this.timer = setInterval(() => { this.tick(); }, INTERVAL_MS);
      this.tick();
    } catch (error) {
      await this.stop(); throw error as Error;
    }
  }
  private async stop(): Promise<void> {
    this.ready = false;
    if (this.timer >= 0) { clearInterval(this.timer); this.timer = -1; }
    if (this.localStore) { this.localStore.onCommitted = undefined; this.localStore = undefined; }
    await this.pending;
    const files = this.files; this.files = undefined;
    const transport = this.transport; this.transport = undefined;
    this.outgoing.clear(); this.published.clear(); this.seen.clear(); this.localThreads.clear();
    this.liveDirty.clear(); this.localLive.clear(); this.sharedTurns.clear(); this.peers = [];
    this.session?.clearPeerProgress();
    this.nextPull = 0; this.nextPush = 0; this.needsPush = true; this.remoteDirty = true;
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
    if (!this.localThreads.has(thread.id) && !thread.messages.length && !thread.draft && !thread.attachments?.length &&
      !thread.projectId && !thread.titleEdited && !thread.archived && !thread.pinned) { return; }
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
    if (item.status !== 'running_or_unknown') { this.queue({ kind: 'usage', id: item.id, text: JSON.stringify(item) }); }
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
      } else if (record.scope.startsWith('workspace:') && isManagedWorkspaceRecord(record.id)) {
        const id = record.scope.slice(10) + '/' + record.id;
        if (!this.applyingWorkspace.has(id)) { this.queue({ kind: 'workspace', id: id, text: record.text }); }
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
      for (const item of batch) { this.writing.add(itemKey(item.kind, item.id)); }
      try { await transport.write(batch); }
      finally { this.writing.clear(); }
      for (const item of batch) {
        const key = itemKey(item.kind, item.id);
        if (this.outgoing.get(key) === item) { this.outgoing.delete(key); }
        this.published.set(key, item.text);
      }
      this.needsPush = true;
    }
    const devices = transport.devices();
    this.files?.tick(devices);
    if (devices.join(',') !== this.peers.join(',')) {
      this.peers = devices; this.nextPull = 0; this.nextPush = 0; this.needsPush = true;
      if (!devices.length) { this.session!.clearPeerProgress(); this.seen.clear(); }
    }
    const now = Date.now();
    if (this.remoteDirty) {
      this.remoteDirty = false;
      try { await this.receive(transport); }
      catch (error) { this.remoteDirty = true; throw error as Error; }
    }
    if (devices.length && this.needsPush && now >= this.nextPush) {
      this.nextPush = now + 2500;
      await transport.exchange(devices, true);
      this.nextPush = now + INTERVAL_MS; this.needsPush = false;
    }
    if (devices.length && now >= this.nextPull) {
      this.nextPull = now + RESCAN_MS; await transport.exchange(devices, false); this.remoteDirty = true;
    }
    AppStorage.setOrCreate('tinybot.nearby.status', devices.length ? t('已发现 {0} 台附近设备', [devices.length]) : t('等待附近设备打开 Tinybot'));
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
        const digest = cryptoFramework.createMd('SHA256');
        await digest.update({ data: new util.TextEncoder().encodeInto(record.origin + ':' + record.id) });
        const bytes = (await digest.digest()).data;
        const id = 'peer-' + Array.from(bytes).map((byte) => byte.toString(16).padStart(2, '0')).join('');
        threads.push({ origin: record.origin, id: record.id, collisionId: id, thread: thread }); applied.push(record);
      } else if (record.kind === 'settings' && record.text !== undefined) {
        const previous = await this.localStore!.read('nearby-settings', record.origin);
        settings.push({ current: parsePeerSettings(record.text), previous: previous === undefined ? undefined : parsePeerSettings(previous) });
        settingRecords.push({ scope: 'nearby-settings', id: record.origin, text: record.text });
        applied.push(record);
      }
    }
    if (projects.length || threads.length || settings.length) {
      await this.session!.receivePeerChanges(projects, threads, settings, this.origin);
    }
    if (settingRecords.length) { await this.localStore!.commit(settingRecords); }
    const usage: RequestUsage[] = [];
    for (const record of records) {
      if (record.kind === 'usage' && record.text !== undefined) { usage.push(usageItem(record.text)); applied.push(record); }
      else if (record.kind === 'file') { this.files?.receive(record); applied.push(record); }
      else if (record.kind === 'workspace') { await this.receiveWorkspace(record); applied.push(record); }
      else if (record.kind === 'live') {
        if (record.text === undefined) { this.session!.clearPeerProgress(record.origin, record.id); applied.push(record); }
        else if (this.session!.receivePeerAnswer(record.origin, record.id, peerLiveMessage(record.text))) { applied.push(record); }
      }
    }
    if (usage.length) { await UsageLedger.restoreBackup(this.context!.filesDir, usage); }
    for (const record of applied) { transport.mark(this.seen, record); }
  }
  private async receiveWorkspace(record: NearbyRecord): Promise<void> {
    const index = record.id.indexOf('/'), id = record.id.slice(0, index), path = record.id.slice(index + 1);
    if (index <= 0 || !isManagedWorkspaceRecord(path) || !this.localStore) { throw new Error('Invalid synchronized workspace record'); }
    const scope = 'workspace:' + id;
    const store = this.localStore;
    const current = await store.read(scope, path);
    if (current === record.text) { return; }
    if (record.text !== undefined) {
      const parts = path.split('/');
      const time = parts[0] === 'life-panels' ? parsePanelRecord(record.text, parts[1]).updatedAt : parseLifeBoard(record.text, parts[1]).updatedAt;
      const existing = !current ? 0 : parts[0] === 'life-panels' ? parsePanelRecord(current, parts[1]).updatedAt : parseLifeBoard(current, parts[1]).updatedAt;
      if (existing > time) { return; }
      await new WorkspaceStore(this.context!.getApplicationContext().filesDir).ensureThread(id);
    }
    this.applyingWorkspace.add(record.id);
    try { await store.commit([{ scope: scope, id: path, text: record.text }]); }
    finally { this.applyingWorkspace.delete(record.id); }
    PanelChanges.emit();
  }
}

export const nearbySync = new NearbySync();
