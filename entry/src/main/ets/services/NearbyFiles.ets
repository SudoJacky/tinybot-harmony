import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { WorkspaceStore } from '../model/WorkspaceStore';
import { ArkDataRecords } from './ArkDataRecords';
import { isManagedWorkspaceRecord } from './ArkDataWorkspace';
import { copyFileBytes } from './FileBytes';
import { NativeWorkspaceFiles } from './NativeWorkspaceFiles';
import { NearbyItem, NearbyRecord } from './NearbySyncStore';
import { workspaceRelativePath } from './WorkspaceTools';

const SCOPE = 'nearby-file-state';
const SHA256 = /^[A-Za-z0-9+/]{43}=$/;
const ATTACHMENT = /^[A-Za-z0-9-]{1,80}\.(jpg|txt)$/;
const SCAN_MS = 12000;
const STAGING_GRACE_SECONDS = 15 * 60;
interface FileVersion { digest: string; base: string; size: number; }
interface LocalVersion extends FileVersion { stamp: string; owned: boolean; }
interface Location { root: string; path: string; attachment: boolean; }
interface FileEntry { id: string; location: Location; size: number; stamp: string; }

function fileStamp(stat: fs.Stat): string {
  return String(stat.mtimeNs ?? stat.mtime) + ':' + String(stat.ctimeNs ?? stat.ctime);
}

export class NearbyFiles {
  private context: common.UIAbilityContext;
  private origin: string;
  private workspaces: WorkspaceStore;
  private attachments: string;
  private database: ArkDataRecords;
  private queue: (item: NearbyItem) => void;
  private report: (error: Error) => void;
  private pending: Map<string, NearbyRecord> = new Map();
  private versions: Map<string, LocalVersion> = new Map();
  private connections: Set<string> = new Set();
  private nextScan: number = 0;
  private nextReceive: number = 0;
  private filesystemRevision: number = -1;
  private firstScan: boolean = true;
  private working?: Promise<void>;
  private closed: boolean = false;
  private watchers: fs.DfsListeners = { onStatus: (id: string, _status: number): void => {
    this.connections.delete(id); this.nextReceive = 0;
  } };

  constructor(context: common.UIAbilityContext, origin: string, database: ArkDataRecords,
    queue: (item: NearbyItem) => void, report: (error: Error) => void) {
    this.context = context; this.origin = origin; this.database = database; this.queue = queue; this.report = report;
    const files = context.getApplicationContext().filesDir;
    this.workspaces = new WorkspaceStore(files); this.attachments = files + '/attachments';
  }
  async open(): Promise<void> {
    for (const id of await this.database.ids(SCOPE)) {
      const text = await this.database.read(SCOPE, id);
      if (text !== undefined) { this.versions.set(id, JSON.parse(text) as LocalVersion); }
    }
  }
  receive(record: NearbyRecord): void {
    if (record.text === undefined) { return; }
    this.pending.set(record.origin + ':' + record.id, record);
    this.nextReceive = 0;
  }
  tick(devices: string[]): void {
    if (this.closed || this.working) { return; }
    const now = Date.now(), revision = NativeWorkspaceFiles.contentRevision;
    const scan = now >= this.nextScan || revision !== this.filesystemRevision && now >= this.nextScan - SCAN_MS + 1500;
    const receive = devices.length > 0 && this.pending.size > 0 && now >= this.nextReceive;
    if (!scan && !receive) { return; }
    this.working = this.work(devices, scan, receive).catch((error: Error) => this.report(error)).finally(() => { this.working = undefined; });
  }
  private async work(devices: string[], scan: boolean, receive: boolean): Promise<void> {
    if (receive) {
      this.nextReceive = Date.now() + 2500;
      for (const id of devices) {
        if (!this.connections.has(id)) {
          try { await fs.connectDfs(id, this.watchers); this.connections.add(id); }
          catch (error) { this.report(error as Error); }
        }
      }
      for (const key of Array.from(this.pending.keys()).slice(0, 20)) {
        if (this.closed) { return; }
        const record = this.pending.get(key);
        let applied = false;
        try {
          if (record) { applied = await this.apply(record); }
        } catch (error) { this.report(error as Error); }
        if (record && this.pending.get(key) === record) {
          this.pending.delete(key);
          if (!applied) { this.pending.set(key, record); }
        }
      }
    }
    if (scan && !this.closed) {
      this.nextScan = Date.now() + SCAN_MS;
      this.filesystemRevision = NativeWorkspaceFiles.contentRevision;
      await this.scan();
      if (!this.closed) { await this.pruneStaging(); }
    }
  }
  private async pruneStaging(): Promise<void> {
    const root = this.context.distributedFilesDir;
    const keep = new Set<string>();
    for (const version of this.versions.values()) {
      if (version.owned && version.digest) { keep.add(this.shared(this.origin, version.digest)); }
    }
    const cutoff = Date.now() / 1000 - STAGING_GRACE_SECONDS;
    for (const name of await fs.listFile(root)) {
      if (!name.startsWith(this.prefix(this.origin))) { continue; }
      const path = root + '/' + name;
      if (!keep.has(path) && (await fs.lstat(path)).mtime < cutoff) { await fs.unlink(path); }
    }
  }
  private location(id: string): Location {
    const parts = id.split('/');
    if (parts[0] === 'attachment' && parts.length === 2 && ATTACHMENT.test(parts[1])) {
      return { root: this.attachments, path: parts[1], attachment: true };
    }
    if (parts[0] !== 'workspace' || parts.length < 3) { throw new Error('Invalid synchronized file identifier'); }
    const path = workspaceRelativePath(parts.slice(2).join('/'), false);
    if (path.startsWith('shared/') || path === 'shared' || path.split('/').some((part) => part.startsWith('.tinybot-')) ||
      isManagedWorkspaceRecord(path)) { throw new Error('Invalid synchronized workspace path'); }
    return { root: this.workspaces.pathFor(parts[1]), path: path, attachment: false };
  }
  private prefix(origin: string): string { return 'tinybot-nearby-' + origin + '-'; }
  private shared(origin: string, digest: string): string {
    return this.context.distributedFilesDir + '/' + this.prefix(origin) + digest.replace(/\+/g, '-').replace(/\//g, '_').slice(0, 43);
  }
  private async scan(): Promise<void> {
    const entries = await this.inventory();
    const present = new Set<string>();
    for (const entry of entries) {
      if (this.closed) { return; }
      present.add(entry.id);
      const previous = this.versions.get(entry.id);
      const files = new NativeWorkspaceFiles(entry.location.root);
      if (!this.firstScan && previous?.digest && previous.stamp === entry.stamp && previous.size === entry.size) { continue; }
      const digest = await files.binaryVersion(entry.location.path);
      if (previous?.digest === digest && !previous.owned) { continue; }
      const info: LocalVersion = { digest: digest, base: previous?.digest === digest ? previous.base : previous?.digest || '',
        size: entry.size, stamp: entry.stamp, owned: true };
      const target = this.shared(this.origin, digest);
      if (!await fs.access(target)) {
        const temp = target + '-' + util.generateRandomUUID() + '.tmp';
        try {
          const path = await files.checkedPath(entry.location.path);
          await copyFileBytes(path, temp);
          const temporary = new NativeWorkspaceFiles(this.context.distributedFilesDir);
          if (await temporary.binaryVersion(temp.slice(this.context.distributedFilesDir.length + 1)) !== digest) { continue; }
          await fs.rename(temp, target);
        } finally { if (await fs.access(temp)) { await fs.unlink(temp); } }
      }
      await this.record(entry.id, info);
      this.publish(entry.id, info);
    }
    for (const id of Array.from(this.versions.keys())) {
      if (present.has(id)) { continue; }
      const previous = this.versions.get(id)!;
      if (!previous.digest) { if (this.firstScan && previous.owned) { this.publish(id, previous); } continue; }
      const removed: LocalVersion = { digest: '', base: previous.digest, stamp: '', size: 0, owned: true };
      await this.record(id, removed); this.publish(id, removed);
    }
    this.firstScan = false;
  }
  private async inventory(): Promise<FileEntry[]> {
    const result: FileEntry[] = [];
    if (await fs.access(this.attachments)) {
      for (const name of await fs.listFile(this.attachments)) {
        if (!ATTACHMENT.test(name)) { continue; }
        const stat = await fs.lstat(this.attachments + '/' + name);
        if (stat.isFile() && !stat.isSymbolicLink()) {
          const id = 'attachment/' + name;
          result.push({ id: id, location: this.location(id), stamp: fileStamp(stat), size: stat.size });
        }
      }
    }
    if (!await fs.access(this.workspaces.rootDir)) { return result; }
    for (const owner of await fs.listFile(this.workspaces.rootDir)) {
      const root = this.workspaces.pathFor(owner), stat = await fs.lstat(root);
      if (!stat.isDirectory() || stat.isSymbolicLink()) { continue; }
      const pending: string[] = [''];
      for (let index = 0; index < pending.length; index++) {
        const directory = pending[index];
        for (const name of await fs.listFile(directory ? root + '/' + directory : root)) {
          if (name.startsWith('.tinybot-') || !directory && name === 'shared') { continue; }
          const path = directory ? directory + '/' + name : name;
          if (isManagedWorkspaceRecord(path)) { continue; }
          const info = await fs.lstat(root + '/' + path);
          if (info.isSymbolicLink()) { continue; }
          if (info.isDirectory()) { pending.push(path); }
          else if (info.isFile()) {
            const id = 'workspace/' + owner + '/' + path;
            result.push({ id: id, location: this.location(id), stamp: fileStamp(info), size: info.size });
          }
        }
      }
    }
    return result;
  }
  private publish(id: string, local: LocalVersion): void {
    const info: FileVersion = { digest: local.digest, base: local.base, size: local.size };
    this.queue({ kind: 'file', id: id, text: JSON.stringify(info) });
  }
  private async record(id: string, version: LocalVersion): Promise<void> {
    await this.database.commit([{ scope: SCOPE, id: id, text: JSON.stringify(version) }]);
    this.versions.set(id, version);
  }
  private async apply(record: NearbyRecord): Promise<boolean> {
    const item = JSON.parse(record.text!) as FileVersion, location = this.location(record.id);
    if (!item || typeof item.digest !== 'string' || typeof item.base !== 'string' ||
      (item.digest && !SHA256.test(item.digest)) || (item.base && !SHA256.test(item.base)) ||
      !Number.isSafeInteger(item.size) || item.size < 0) { throw new Error('Invalid synchronized file metadata'); }
    let source: fs.File | undefined;
    if (item.digest) {
      try {
        // Peer files are opened through the DFS connection. A path-based access check can fail even when opening works.
        source = await fs.open(this.shared(record.origin, item.digest), fs.OpenMode.READ_WRITE | fs.OpenMode.NOFOLLOW);
      } catch (error) {
        if ((error as BusinessError).code === 13900002) { return false; }
        throw error as Error;
      }
    }
    try {
      if (source && (await fs.stat(source.fd)).size !== item.size) { return false; }
      return await this.install(record.id, location, item, source?.fd);
    } finally { if (source) { await fs.close(source); } }
  }
  private async install(id: string, location: Location, item: FileVersion, source?: number): Promise<boolean> {
    if (!await fs.access(location.root)) {
      if (source === undefined) { return true; }
      if (location.attachment) { await fs.mkdir(location.root, true); }
      else { await this.workspaces.ensureThread(location.root.slice(location.root.lastIndexOf('/') + 1)); }
    }
    const path = location.root + '/' + location.path;
    if (source === undefined && !await fs.access(path)) { return true; }
    const files = new NativeWorkspaceFiles(location.root);
    const actual = await files.applyNearbyFile(location.path, source, item.digest, item.base, !location.attachment);
    if (actual !== item.digest) { return true; }
    const stat = actual ? await fs.lstat(path) : undefined;
    await this.record(id, { digest: actual, base: item.base, stamp: stat ? fileStamp(stat) : '', size: item.size, owned: false });
    return true;
  }
  async close(): Promise<void> {
    this.closed = true;
    await this.working;
    for (const id of this.connections) {
      try { await fs.disconnectDfs(id); }
      catch (error) { this.report(error as Error); }
    }
    const root = this.context.distributedFilesDir;
    if (!await fs.access(root)) { return; }
    for (const name of await fs.listFile(root)) {
      if (name.startsWith(this.prefix(this.origin))) { await fs.unlink(root + '/' + name); }
    }
  }
}
