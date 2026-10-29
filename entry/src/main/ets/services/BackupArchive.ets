import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { t } from '../model/I18n';
import { Diagnostics } from '../model/Diagnostics';

// v3: 8-byte magic, uint32 LE index length, UTF-8 index, raw blobs, SHA-256.
// Only the index is materialized. Binary I/O and hashing use 256 KiB chunks.
const MAGIC = 'TINYBOT3';
const CHUNK = 256 * 1024;
interface ArchiveIndex { metadata: string; sizes: number[]; }
export interface OpenBackupArchive { metadata: string; files: string[]; sizes: number[]; directory: string; }

async function readExactly(fd: number, length: number): Promise<Uint8Array> {
  const result = new Uint8Array(length);
  let position = 0;
  while (position < length) {
    const buffer = new ArrayBuffer(Math.min(CHUNK, length - position));
    const count = await fs.read(fd, buffer);
    if (count <= 0) { throw new Error(t('备份不完整或已损坏。')); }
    result.set(new Uint8Array(buffer, 0, count), position); position += count;
  }
  return result;
}

async function writeAll(fd: number, bytes: Uint8Array, position: number): Promise<number> {
  let offset = 0;
  while (offset < bytes.length) {
    const count = await fs.write(fd, bytes.buffer.slice(bytes.byteOffset + offset, bytes.byteOffset + Math.min(offset + CHUNK, bytes.length)), { offset: position + offset });
    if (count <= 0) { throw new Error(t('文件写入未完成。')); }
    offset += count;
  }
  return position + offset;
}

export async function cleanupBackupArchive(directory: string): Promise<void> {
  try { await fs.rmdir(directory); }
  catch (error) { Diagnostics.log('warn', 'backup', 'cleanup_failed', undefined, error as Error); }
}

export async function writeBackupArchive(path: string, metadata: string, sources: string[]): Promise<void> {
  const sizes: number[] = [];
  for (const source of sources) {
    const stat = await fs.lstat(source);
    if (!stat.isFile() || stat.isSymbolicLink() || !Number.isSafeInteger(stat.size) || stat.size < 0) { throw new Error(t('备份文件无效。')); }
    sizes.push(stat.size);
  }
  const index: ArchiveIndex = { metadata: metadata, sizes: sizes };
  const bytes = new util.TextEncoder().encodeInto(JSON.stringify(index));
  const header = new Uint8Array(12);
  header.set(new util.TextEncoder().encodeInto(MAGIC));
  new DataView(header.buffer).setUint32(8, bytes.length, true);
  const output = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC | fs.OpenMode.NOFOLLOW);
  let complete = false;
  try {
    const hash = cryptoFramework.createMd('SHA256');
    let position = await writeAll(output.fd, header, 0);
    await hash.update({ data: header });
    position = await writeAll(output.fd, bytes, position); await hash.update({ data: bytes });
    for (let index = 0; index < sources.length; index++) {
      const input = await fs.open(sources[index], fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
      try {
        const stat = await fs.stat(input.fd);
        if (!stat.isFile() || stat.size !== sizes[index]) { throw new Error(t('备份期间文件发生变化，请重试。')); }
        let remaining = sizes[index];
        while (remaining > 0) {
          const chunk = await readExactly(input.fd, Math.min(CHUNK, remaining));
          position = await writeAll(output.fd, chunk, position); await hash.update({ data: chunk });
          remaining -= chunk.length;
        }
        if (await fs.read(input.fd, new ArrayBuffer(1)) !== 0 || Number((await fs.stat(input.fd)).mtime) !== Number(stat.mtime)) {
          throw new Error(t('备份期间文件发生变化，请重试。'));
        }
      } finally { await fs.close(input); }
    }
    position = await writeAll(output.fd, (await hash.digest()).data, position);
    await fs.fsync(output.fd);
    Diagnostics.log('info', 'backup', 'archive_written', { count: sources.length, bytes: position });
    complete = true;
  } catch (error) {
    Diagnostics.log('error', 'backup', 'archive_write_failed', undefined, error as Error);
    throw error as Error;
  } finally {
    try { await fs.close(output); } finally { if (!complete) { await fs.unlink(path); } }
  }
}

// Unknown magic is handled only by the v1/v2 JSON reader, never as v3.
// Extraction paths are generated locally; the archive cannot name a disk path.
export async function openBackupArchive(path: string, cacheDir: string,
  beforeExtract?: (metadata: string) => Promise<void>): Promise<OpenBackupArchive | undefined> {
  const input = await fs.open(path, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
  let directory = ''; let complete = false;
  try {
    const stat = await fs.stat(input.fd);
    if (!stat.isFile()) { throw new Error(t('备份文件无效。')); }
    if (stat.size < 12) { return undefined; }
    const header = await readExactly(input.fd, 12);
    if (!header.slice(0, 8).every((value, index) => value === MAGIC.charCodeAt(index))) { return undefined; }
    const length = new DataView(header.buffer).getUint32(8, true);
    if (length === 0 || length + 44 > stat.size) { throw new Error(t('备份不完整或已损坏。')); }
    const bytes = await readExactly(input.fd, length);
    const index = JSON.parse(new util.TextDecoder('utf-8', { fatal: true }).decodeToString(bytes)) as ArchiveIndex;
    if (!index || typeof index.metadata !== 'string' || !Array.isArray(index.sizes)) {
      throw new Error(t('备份格式无效。'));
    }
    let total = length + 44;
    for (const size of index.sizes) {
      if (!Number.isSafeInteger(size) || size < 0) { throw new Error(t('备份文件无效。')); }
      total += size;
      if (!Number.isSafeInteger(total) || total > stat.size) { throw new Error(t('备份不完整或已损坏。')); }
    }
    if (total !== stat.size) { throw new Error(t('备份不完整或已损坏。')); }
    if (beforeExtract) { await beforeExtract(index.metadata); }
    directory = cacheDir + '/restore-' + util.generateRandomUUID();
    await fs.mkdir(directory);
    const files: string[] = [];
    const hash = cryptoFramework.createMd('SHA256');
    await hash.update({ data: header }); await hash.update({ data: bytes });
    for (let item = 0; item < index.sizes.length; item++) {
      const target = directory + '/' + item;
      const output = await fs.open(target, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.NOFOLLOW);
      try {
        let remaining = index.sizes[item]; let position = 0;
        while (remaining > 0) {
          const chunk = await readExactly(input.fd, Math.min(CHUNK, remaining));
          position = await writeAll(output.fd, chunk, position); await hash.update({ data: chunk });
          remaining -= chunk.length;
        }
      } finally { await fs.close(output); }
      files.push(target);
    }
    const expected = await readExactly(input.fd, 32);
    const actual = (await hash.digest()).data;
    if (!expected.every((value, index) => value === actual[index]) || await fs.read(input.fd, new ArrayBuffer(1)) !== 0) {
      throw new Error(t('备份不完整或已损坏。'));
    }
    Diagnostics.log('info', 'backup', 'archive_verified', { count: files.length, bytes: total });
    complete = true;
    return { metadata: index.metadata, files: files, sizes: index.sizes, directory: directory };
  } finally {
    try { await fs.close(input); } finally { if (directory && !complete) { await cleanupBackupArchive(directory); } }
  }
}
