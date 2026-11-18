import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { AppData } from '../model/Conversation';
import { WorkspaceStore } from '../model/WorkspaceStore';
import { threadAttachments } from '../model/ThreadAttachments';
import { parseLifeBoard } from '../model/LifeBoard';
import { parsePanelRecord } from '../model/LifePanel';
import { NativeWorkspaceFiles } from './NativeWorkspaceFiles';
import { ArkDataWorkspace, isManagedWorkspaceRecord } from './ArkDataWorkspace';
import { ArkDataRecords, StoredRecord } from './ArkDataRecords';
import { workspaceRelativePath } from './WorkspaceTools';
import { copyFileBytes } from './FileBytes';
import { Cancellation } from './Cancellation';
import { contentVersion } from './TextDigest';
import { Diagnostics } from '../model/Diagnostics';

export interface DeviceAsset { workspace: string; path: string; digest: string; size: number; text?: string; base?: string; }
interface StagedFile { stamp: string; digest: string; }
const DIGEST = /^[A-Za-z0-9+/]{43}=$/;
const ORIGIN = /^[0-9a-f-]{36}$/;

function sharedName(origin: string, digest: string): string {
  if (!ORIGIN.test(origin) || !DIGEST.test(digest)) { throw new Error('Invalid device asset identity'); }
  return 'tinybot-transfer-' + origin + '-' + digest.slice(0, 43).replace(/\+/g, '-').replace(/\//g, '_');
}
function assetKey(owner: string, path: string): string { return JSON.stringify([owner, path]); }

export class DeviceAssets {
  private context: common.UIAbilityContext;
  private workspaces: WorkspaceStore;
  private attachmentRoot: string;
  constructor(context: common.UIAbilityContext) {
    this.context = context;
    const root = context.getApplicationContext().filesDir;
    this.workspaces = new WorkspaceStore(root); this.attachmentRoot = root + '/attachments';
  }

  private async stage(owner: string, path: string, origin: string, database: ArkDataRecords): Promise<DeviceAsset> {
    const root = owner ? this.workspaces.pathFor(owner) : this.attachmentRoot;
    const files = new NativeWorkspaceFiles(root);
    const source = await files.checkedPath(path), before = await fs.lstat(source);
    const stamp = String(before.mtimeNs) + ':' + String(before.ctimeNs) + ':' + before.size;
    const id = assetKey(owner, path), scope = 'device-staged';
    const saved = await database.read(scope, id);
    const previous = saved ? JSON.parse(saved) as StagedFile : undefined;
    const digest = before.mtimeNs !== undefined && before.ctimeNs !== undefined && previous?.stamp === stamp ?
      previous.digest : await files.binaryVersion(path);
    const name = sharedName(origin, digest), directory = this.context.distributedFilesDir;
    if (!await fs.access(directory + '/' + name)) {
      const temp = name + '-' + util.generateRandomUUID() + '.tmp';
      try {
        await copyFileBytes(source, directory + '/' + temp);
        if (await new NativeWorkspaceFiles(directory).binaryVersion(temp) !== digest) { throw new Error('Device asset changed during publication'); }
        await fs.rename(directory + '/' + temp, directory + '/' + name);
      } finally { if (await fs.access(directory + '/' + temp)) { await fs.unlink(directory + '/' + temp); } }
    }
    const after = await fs.lstat(source);
    if (before.mtimeNs !== after.mtimeNs || before.ctimeNs !== after.ctimeNs || before.size !== after.size || Number(before.mtime) !== Number(after.mtime)) {
      throw new Error('Device asset changed during publication');
    }
    if (previous?.stamp !== stamp || previous.digest !== digest) {
      const staged: StagedFile = { stamp: stamp, digest: digest };
      await database.commit([{ scope: scope, id: id, text: JSON.stringify(staged) }]);
    }
    return { workspace: owner, path: path, digest: digest, size: after.size };
  }

  async capture(data: AppData, origin: string, database: ArkDataRecords): Promise<DeviceAsset[]> {
    const assets = new Map<string, DeviceAsset>();
    for (const thread of data.threads) {
      for (const item of threadAttachments(thread)) {
        const owner = item.workspaceId || '', key = assetKey(owner, item.path);
        if (!assets.has(key)) { assets.set(key, await this.stage(owner, item.path, origin, database)); }
        if (assets.get(key)!.size !== item.size) { throw new Error('Device attachment size mismatch'); }
      }
    }
    if (!await fs.access(this.workspaces.rootDir)) { return Array.from(assets.values()); }
    for (const owner of await fs.listFile(this.workspaces.rootDir)) {
      await this.workspaces.requireWorkspace(owner);
      const root = this.workspaces.pathFor(owner);
      const managed = ArkDataWorkspace.forRoot(root);
      if (!managed) { throw new Error('Workspace database is unavailable'); }
      for (const path of await managed.paths()) {
        const text = await managed.read(path);
        if (text === undefined || !isManagedWorkspaceRecord(path)) { throw new Error('Invalid device workspace record'); }
        assets.set(assetKey(owner, path), { workspace: owner, path: path, digest: await contentVersion(text), size: 0, text: text });
      }
      const directories = [''];
      for (let index = 0; index < directories.length; index++) {
        const parent = directories[index];
        for (const name of await fs.listFile(root + (parent ? '/' + parent : ''))) {
          if (name.startsWith('.tinybot-') || (!parent && name === 'shared')) { continue; }
          const path = workspaceRelativePath(parent ? parent + '/' + name : name, false);
          const key = assetKey(owner, path);
          if (assets.has(key) || isManagedWorkspaceRecord(path)) { continue; }
          const stat = await fs.lstat(root + '/' + path);
          if (stat.isSymbolicLink()) { throw new Error('Device transfer cannot follow symbolic links'); }
          if (stat.isDirectory()) { directories.push(path); } else if (stat.isFile()) { assets.set(key, await this.stage(owner, path, origin, database)); }
        }
      }
    }
    return Array.from(assets.values());
  }

  verify(assets: DeviceAsset[], data: AppData): void {
    const indexed = new Map<string, DeviceAsset>();
    for (const asset of assets) {
      const path = workspaceRelativePath(asset.path, false);
      if (asset.workspace) { this.workspaces.pathFor(asset.workspace); }
      const key = assetKey(asset.workspace, path);
      if (typeof asset.workspace !== 'string' || path.split('/')[0] === 'shared' || !DIGEST.test(asset.digest) ||
        !Number.isSafeInteger(asset.size) || asset.size < 0 || indexed.has(key) ||
        isManagedWorkspaceRecord(path) !== (typeof asset.text === 'string') ||
        (!asset.workspace && !/^(?:[A-Za-z0-9-]{1,80}\.(?:jpg|txt)|attachments\/[A-Za-z0-9-]{1,80}\/[^/]+)$/.test(path))) {
        throw new Error('Invalid device asset manifest');
      }
      indexed.set(key, asset);
    }
    for (const thread of data.threads) {
      for (const item of threadAttachments(thread)) {
        const file = indexed.get(assetKey(item.workspaceId || '', item.path));
        if (!file || file.size !== item.size) { throw new Error('Device transfer is missing a referenced attachment'); }
      }
    }
  }

  async apply(assets: DeviceAsset[], roots: Map<string, string>, device: string, origin: string, db: ArkDataRecords): Promise<number> {
    let connected = false, count = 0;
    const baseline = 'device-files:' + device;
    const updates: StoredRecord[] = [];
    try {
      for (const asset of assets) {
        const owner = roots.get(asset.workspace) || asset.workspace;
        if (owner) { await this.workspaces.ensureThread(owner); }
        else if (!await fs.access(this.attachmentRoot)) { await fs.mkdir(this.attachmentRoot); }
        const root = owner ? this.workspaces.pathFor(owner) : this.attachmentRoot;
        const files = new NativeWorkspaceFiles(root), id = assetKey(owner, asset.path);
        const previous = await db.read(baseline, id);
        if (asset.text !== undefined) {
          if (await contentVersion(asset.text) !== asset.digest) { throw new Error('Device workspace record checksum mismatch'); }
          const store = ArkDataWorkspace.forRoot(root);
          if (!store) { throw new Error('Workspace database is unavailable'); }
          const current = await store.read(asset.path);
          const panel = asset.path.startsWith('life-panels/');
          const recordId = asset.path.split('/')[1];
          let text: string;
          if (panel) {
            const value = parsePanelRecord(asset.text, recordId), source = value.definition.source;
            if (source?.type === 'workspace-json' && source.workspaceId) { source.workspaceId = roots.get(source.workspaceId) || source.workspaceId; }
            text = JSON.stringify(value);
          } else {
            const value = parseLifeBoard(asset.text, recordId);
            for (const ref of value.items) { ref.workspaceId = roots.get(ref.workspaceId) || ref.workspaceId; }
            text = JSON.stringify(value);
          }
          const version = await contentVersion(text);
          if (current !== text) {
            const before = current === undefined ? null : await contentVersion(current);
            if (before !== null && before !== previous && before !== asset.base) {
              const path = 'sync-conflicts/' + recordId + '-' + version.replace(/[^A-Za-z0-9]/g, '').slice(0, 20) +
                (panel ? '-panel.json' : '-board.json');
              if (await fs.access(root + '/' + path)) {
                if (await files.binaryVersion(path) !== version) { throw new Error('Device conflict copy has changed: ' + path); }
              } else { await files.write(path, text, new Cancellation(), { version: null }); count++; }
              continue;
            }
            if (panel) { await files.writeLifePanel(asset.path, text, new Cancellation(), { version: before }); }
            else { await files.writeLifeBoard(asset.path, text, new Cancellation(), { version: before }); }
            count++;
          }
          if (version !== previous) { updates.push({ scope: baseline, id: id, text: version }); }
        } else {
          const changed = await files.receiveDeviceFile(asset.path, asset.digest, [previous || '', asset.base || ''], !owner || asset.path.startsWith('attachments/'), async () => {
            if (owner && owner !== asset.workspace) {
              const sourceRoot = this.workspaces.pathFor(asset.workspace);
              const local = new NativeWorkspaceFiles(sourceRoot);
              if (await fs.access(sourceRoot + '/' + asset.path) && await local.binaryVersion(asset.path) === asset.digest) {
                return fs.open(await local.checkedPath(asset.path), fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
              }
            }
            if (!connected) {
              await fs.connectDfs(device, { onStatus: (_id: string, status: number): void => {
                Diagnostics.log('warn', 'sync', 'dfs_status', { code: status });
              } });
              connected = true;
            }
            return fs.open(this.context.distributedFilesDir + '/' + sharedName(origin, asset.digest), fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
          });
          if (changed.written) { count++; }
          if (changed.matches && previous !== asset.digest) { updates.push({ scope: baseline, id: id, text: asset.digest }); }
        }
      }
      await db.commit(updates);
      return count;
    } finally { if (connected) { await fs.disconnectDfs(device); } }
  }

  async prune(origin: string, assets: DeviceAsset[]): Promise<void> {
    const keep = new Set(assets.filter(item => item.text === undefined).map(item => sharedName(origin, item.digest)));
    const directory = this.context.distributedFilesDir;
    for (const name of await fs.listFile(directory)) {
      if (name.startsWith('tinybot-transfer-' + origin + '-') && !keep.has(name)) { await fs.unlink(directory + '/' + name); }
    }
  }
}
