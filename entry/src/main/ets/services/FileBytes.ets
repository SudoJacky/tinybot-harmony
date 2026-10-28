import { fileIo as fs } from '@kit.CoreFileKit';
import { t } from '../model/I18n';

export async function readBounded(fd: number, maximum: number): Promise<ArrayBuffer> {
  const stat = await fs.stat(fd);
  if (!stat.isFile() || stat.size > maximum) { throw new Error(t('文件超出读取上限。')); }
  const bytes = new Uint8Array(maximum + 1); let length = 0;
  while (length < bytes.length) {
    const buffer = new ArrayBuffer(bytes.length - length); const count = await fs.read(fd, buffer);
    if (count === 0) { break; } bytes.set(new Uint8Array(buffer, 0, count), length); length += count;
  }
  if (length > maximum) { throw new Error(t('文件超出读取上限。')); }
  return bytes.buffer.slice(0, length);
}

export async function writeBytes(path: string, bytes: ArrayBuffer): Promise<void> {
  const file = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  try {
    let offset = 0;
    while (offset < bytes.byteLength) {
      const count = await fs.write(file.fd, bytes.slice(offset), { offset: offset });
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
