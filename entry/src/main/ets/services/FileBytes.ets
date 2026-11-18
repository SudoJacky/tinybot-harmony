import { fileIo as fs } from '@kit.CoreFileKit';
import { t } from '../model/I18n';

export async function readBounded(fd: number, maximum: number): Promise<ArrayBuffer> {
  const stat = await fs.stat(fd);
  if (!stat.isFile() || stat.size > maximum) { throw new Error(t('文件超出读取上限。')); }
  const first = new ArrayBuffer(stat.size);
  let length = stat.size > 0 ? await fs.read(fd, first) : 0;
  const parts: Uint8Array[] = [new Uint8Array(first, 0, length)];
  // A short read is not EOF. Probe even after reaching the reported size, since files can grow.
  while (true) {
    const size = length === stat.size ? 1 : Math.min(64 * 1024, maximum - length + 1);
    const buffer = new ArrayBuffer(size);
    const count = await fs.read(fd, buffer);
    if (count === 0) { break; }
    length += count;
    if (length > maximum) { throw new Error(t('文件超出读取上限。')); }
    parts.push(new Uint8Array(count === size ? buffer : buffer.slice(0, count)));
  }
  if (parts.length === 1 && length === first.byteLength) { return first; }
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const part of parts) { bytes.set(part, offset); offset += part.length; }
  return bytes.buffer;
}

export async function writeBytes(path: string, bytes: ArrayBuffer): Promise<void> {
  const file = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  try {
    let offset = 0;
    while (offset < bytes.byteLength) {
      const count = await fs.write(file.fd, offset === 0 ? bytes : bytes.slice(offset), { offset: offset });
      if (count <= 0) { throw new Error(t('文件写入未完成。')); } offset += count;
    }
    await fs.fsync(file.fd);
  } finally { await fs.close(file); }
}

// Native copying preserves binary bytes and avoids loading a whole attachment into JS memory.
export async function copyFileBytes(source: string, destination: string): Promise<number> {
  const input = await fs.open(source, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
  try { return await copyOpenFileBytes(input.fd, destination); }
  finally { await fs.close(input); }
}

// The caller owns the source descriptor, including when it came from a granted URI.
export async function copyOpenFileBytes(fd: number, destination: string): Promise<number> {
  const stat = await fs.stat(fd);
  if (!stat.isFile()) { throw new Error(t('请选择普通文件。')); }
  if (await fs.access(destination)) { throw new Error('The destination already exists: ' + destination); }
  const output = await fs.open(destination, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.NOFOLLOW);
  let complete = false;
  try {
    await fs.copyFile(fd, output.fd);
    if ((await fs.stat(output.fd)).size !== stat.size) { throw new Error(t('文件写入未完成。')); }
    await fs.fsync(output.fd); complete = true; return stat.size;
  } finally {
    try { await fs.close(output); } finally { if (!complete) { await fs.unlink(destination); } }
  }
}
