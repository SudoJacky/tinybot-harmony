import { util } from '@kit.ArkTS';
import { zlib } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { t } from '../model/I18n';

export interface ZipEntry {
  name: string; flags: number; method: number; crc: number; packed: number; size: number; offset: number;
}
const MAX_DIRECTORY_SIZE: number = 8 * 1024 * 1024;
function invalidZip(): Error { return new Error(t('ZIP 文件损坏或使用了不支持的压缩格式。')); }

export class ZipArchive {
  private fd: number;
  private directoryOffset: number;
  private entriesByName: Map<string, ZipEntry>;
  private static decoder: util.TextDecoder = new util.TextDecoder('utf-8', { fatal: true });

  private constructor(fd: number, directoryOffset: number, entries: Map<string, ZipEntry>) {
    this.fd = fd; this.directoryOffset = directoryOffset; this.entriesByName = entries;
  }

  private static async readAt(fd: number, position: number, length: number): Promise<ArrayBuffer> {
    const buffer = new ArrayBuffer(length);
    let read = 0;
    while (read < length) {
      const part = new ArrayBuffer(length - read);
      const count = await fs.read(fd, part, { offset: position + read, length: length - read });
      if (count <= 0) { throw invalidZip(); }
      new Uint8Array(buffer).set(new Uint8Array(part, 0, count), read);
      read += count;
    }
    return buffer;
  }

  static async readDirectory(fd: number): Promise<ZipArchive> {
    const stat = await fs.stat(fd);
    if (!stat.isFile() || stat.size < 22 || stat.size >= 0xffffffff) { throw invalidZip(); }
    const tailSize = Math.min(stat.size, 65557);
    const tail = new DataView(await ZipArchive.readAt(fd, stat.size - tailSize, tailSize));
    let end = tailSize - 22;
    while (end >= 0 && (tail.getUint32(end, true) !== 0x06054b50 ||
      end + 22 + tail.getUint16(end + 20, true) !== tailSize)) { end--; }
    if (end < 0 || tail.getUint16(end + 4, true) !== 0 || tail.getUint16(end + 6, true) !== 0) { throw invalidZip(); }
    const count = tail.getUint16(end + 10, true);
    const size = tail.getUint32(end + 12, true);
    const offset = tail.getUint32(end + 16, true);
    if (count !== tail.getUint16(end + 8, true) || count > 20000 || size > MAX_DIRECTORY_SIZE ||
      offset + size !== stat.size - tailSize + end) { throw invalidZip(); }
    const directory = await ZipArchive.readAt(fd, offset, size);
    const view = new DataView(directory);
    const entries = new Map<string, ZipEntry>();
    let cursor = 0;
    for (let i = 0; i < count; i++) {
      if (cursor + 46 > size || view.getUint32(cursor, true) !== 0x02014b50 || view.getUint16(cursor + 34, true) !== 0) { throw invalidZip(); }
      const nameLength = view.getUint16(cursor + 28, true);
      const next = cursor + 46 + nameLength + view.getUint16(cursor + 30, true) + view.getUint16(cursor + 32, true);
      if (!nameLength || next > size) { throw invalidZip(); }
      const name = ZipArchive.decoder.decodeToString(new Uint8Array(directory, cursor + 46, nameLength));
      if (entries.has(name)) { throw invalidZip(); }
      entries.set(name, { name: name, flags: view.getUint16(cursor + 8, true), method: view.getUint16(cursor + 10, true),
        crc: view.getUint32(cursor + 16, true), packed: view.getUint32(cursor + 20, true),
        size: view.getUint32(cursor + 24, true), offset: view.getUint32(cursor + 42, true) });
      cursor = next;
    }
    if (cursor !== size) { throw invalidZip(); }
    return new ZipArchive(fd, offset, entries);
  }

  entries(): ZipEntry[] { return Array.from(this.entriesByName.values()); }
  entry(name: string): ZipEntry | undefined { return this.entriesByName.get(name); }

  async read(entry: ZipEntry, limit: number): Promise<ArrayBuffer> {
    if (entry.size > limit || entry.packed > limit + 65536) { throw new Error(t('文件超出读取上限。')); }
    if ((entry.flags & 1) || entry.offset + 30 > this.directoryOffset ||
      (entry.method !== 0 && entry.method !== 8)) { throw invalidZip(); }
    const header = new DataView(await ZipArchive.readAt(this.fd, entry.offset, 30));
    const nameLength = header.getUint16(26, true);
    const start = entry.offset + 30 + nameLength + header.getUint16(28, true);
    if (header.getUint32(0, true) !== 0x04034b50 || header.getUint16(6, true) !== entry.flags ||
      header.getUint16(8, true) !== entry.method || start + entry.packed > this.directoryOffset) { throw invalidZip(); }
    const name = await ZipArchive.readAt(this.fd, entry.offset + 30, nameLength);
    if (ZipArchive.decoder.decodeToString(new Uint8Array(name)) !== entry.name) { throw invalidZip(); }
    let data = await ZipArchive.readAt(this.fd, start, entry.packed);
    if (entry.method === 8) {
      const zip = zlib.createZipSync();
      const output = new ArrayBuffer(entry.size + 1);
      const stream: zlib.ZStream = { nextIn: data, availableIn: data.byteLength, nextOut: output, availableOut: output.byteLength };
      await zip.inflateInit2(stream, -15);
      try {
        const status = await zip.inflate(stream, zlib.CompressFlushMode.FINISH);
        const result = await zip.getZStream();
        if (status !== zlib.ReturnStatus.STREAM_END || result.totalOut !== entry.size || result.totalIn !== entry.packed) { throw invalidZip(); }
        data = output.slice(0, entry.size);
      } finally { await zip.inflateEnd(stream); }
    }
    if (data.byteLength !== entry.size || ((await zlib.createChecksumSync().crc32(0, data)) >>> 0) !== entry.crc) { throw invalidZip(); }
    return data;
  }
}
