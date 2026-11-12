import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { NearbyAsset } from '../model/NearbyInput';
import { Attachment, validateAttachments } from '../model/Productivity';
import { WorkspaceStore } from '../model/WorkspaceStore';
import { Diagnostics } from '../model/Diagnostics';
import { NativeWorkspaceFiles } from './NativeWorkspaceFiles';
import { copyFileBytes } from './FileBytes';

const DIGEST = /^[A-Za-z0-9+/]{43}=$/;

// Reuse NearbyFiles' content-addressed DFS staging area. Never read a sender-selected
// absolute path or overwrite a file with different bytes on the execution device.
export class NearbyAttachments {
  private context: common.UIAbilityContext;
  private connect: (deviceId: string) => Promise<void>;
  constructor(context: common.UIAbilityContext, connect: (deviceId: string) => Promise<void>) { this.context = context; this.connect = connect; }

  private name(origin: string, digest: string): string {
    if (!/^[0-9a-f-]{36}$/.test(origin) || !DIGEST.test(digest)) { throw new Error('Invalid nearby attachment identity'); }
    return 'tinybot-nearby-' + origin + '-' + digest.replace(/\+/g, '-').replace(/\//g, '_').slice(0, 43);
  }

  async stage(origin: string, items: Attachment[]): Promise<NearbyAsset[]> {
    validateAttachments(items);
    const result: NearbyAsset[] = [];
    const filesDir = this.context.getApplicationContext().filesDir;
    const shared = new NativeWorkspaceFiles(this.context.distributedFilesDir);
    for (const item of items) {
      const root = item.original && item.workspaceId ? new WorkspaceStore(filesDir).pathFor(item.workspaceId) : filesDir + '/attachments';
      const files = new NativeWorkspaceFiles(root);
      const source = await files.checkedPath(item.path), digest = await files.binaryVersion(item.path);
      const name = this.name(origin, digest), target = this.context.distributedFilesDir + '/' + name;
      if (!await fs.access(target)) {
        const temp = name + '-' + util.generateRandomUUID() + '.tmp';
        try {
          await copyFileBytes(source, this.context.distributedFilesDir + '/' + temp);
          if (await shared.binaryVersion(temp) !== digest) { throw new Error('Attachment changed during transfer preparation'); }
          await fs.rename(this.context.distributedFilesDir + '/' + temp, target);
        } finally { if (await fs.access(this.context.distributedFilesDir + '/' + temp)) { await fs.unlink(this.context.distributedFilesDir + '/' + temp); } }
      }
      result.push({ attachment: item, digest: digest });
    }
    return result;
  }

  async receive(deviceId: string, origin: string, assets: NearbyAsset[]): Promise<Attachment[]> {
    if (!Array.isArray(assets)) { throw new Error('Invalid nearby attachments'); }
    validateAttachments(assets.map((asset) => asset.attachment));
    if (!assets.length) { return []; }
    for (const asset of assets) { this.name(origin, asset.digest); }
    await this.connect(deviceId);
      const root = this.context.getApplicationContext().filesDir + '/attachments';
      if (!await fs.access(root)) { await fs.mkdir(root); }
      const files = new NativeWorkspaceFiles(root), result: Attachment[] = [];
      for (const asset of assets) {
        const name = this.name(origin, asset.digest);
        const item = JSON.parse(JSON.stringify(asset.attachment)) as Attachment;
        item.workspaceId = undefined;
        // DFS may make a file available to open(fd) before path-based access/stat.
        const source = await fs.open(this.context.distributedFilesDir + '/' + name, fs.OpenMode.READ_WRITE | fs.OpenMode.NOFOLLOW);
        try {
          if ((await fs.stat(source.fd)).size !== item.size) { throw new Error('Nearby attachment failed size verification'); }
          await files.applyNearbyFile(item.path, source.fd, asset.digest, '', false);
        } finally { await fs.close(source); }
        result.push(item);
      }
      Diagnostics.log('info', 'sync', 'nearby_attachments_received', { count: result.length });
      return result;
  }
}
