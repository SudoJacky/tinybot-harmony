import { bundleManager, common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { Cancellation } from './Cancellation';
import { writeBytes } from './FileBytes';
import { copyLinuxBytes } from './LinuxExchange';

const NAMES: string[] = ['kernel', 'root-v5-shell.qcow2'];
const CACHE: string = '/tinybot-linux-assets-v5-shell';

export function linuxImageSize(context: common.Context): number {
  let size = 0;
  for (const name of NAMES) {
    const resource = 'linux/' + name;
    const raw = context.resourceManager.getRawFdSync(resource);
    try { size += raw.length; }
    finally { context.resourceManager.closeRawFdSync(resource); }
  }
  return size;
}

function signature(install: number, file: fs.Stat): string {
  return [install, file.ino, file.size, file.mtime].join('/');
}

async function stage(context: common.Context, name: string, path: string, install: number, signal: Cancellation): Promise<number> {
  const stamp = path + '.stamp';
  if (await fs.access(path) && await fs.access(stamp)) {
    const stat = await fs.stat(path);
    if (stat.isFile() && stat.size > 0 && await fs.readText(stamp) === signature(install, stat)) { return 0; }
  }
  const resource = 'linux/' + name;
  const raw = context.resourceManager.getRawFdSync(resource);
  // ResourceManager closes raw resources by name. Own a descriptor while copying
  // so a simultaneous size query in Settings can open and close the same name.
  let source: fs.File;
  try { source = fs.dup(raw.fd); }
  finally { context.resourceManager.closeRawFdSync(resource); }
  const temp = path + '.part';
  try {
    if (raw.length <= 0) { throw new Error('Empty Linux image: ' + name); }
    const target = await fs.open(temp, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      await copyLinuxBytes(source.fd, target.fd, raw.offset, 0, raw.length, signal);
      await fs.fsync(target.fd);
    } finally { await fs.close(target); }
    await fs.rename(temp, path);
    const bytes = new util.TextEncoder().encodeInto(signature(install, await fs.stat(path)));
    await writeBytes(stamp, bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer);
    return raw.length;
  } finally {
    try { await fs.close(source); }
    finally { if (await fs.access(temp)) { await fs.unlink(temp); } }
  }
}

export async function prepareLinuxImages(context: common.Context, signal: Cancellation): Promise<number> {
  const install = (await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)).updateTime;
  const dir = context.cacheDir + CACHE;
  if (!await fs.access(dir)) { await fs.mkdir(dir); }
  let copied = 0;
  for (const name of NAMES) {
    signal.check();
    copied += await stage(context, name, dir + '/' + name, install, signal);
  }
  return copied;
}
