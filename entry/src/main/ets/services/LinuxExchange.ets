import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { ToolFailure } from '../model/ToolFailure';
import { Cancellation } from './Cancellation';

const HALF: number = 2 * 1024 * 1024;
const HEADER: number = 8;
const COPY_CHUNK: number = 1024 * 1024;
export const LINUX_TREE_OFFSET: number = 2 * HALF;

async function createDisk(path: string, bytes: number): Promise<void> {
  const file = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  try { await fs.truncate(file.fd, bytes); }
  finally { await fs.close(file); }
}

export async function createLinuxDisks(dir: string, bytes: number): Promise<void> {
  await createDisk(dir + '/exchange', bytes);
  await createDisk(dir + '/workspace', bytes);
}

export async function resetLinuxDisk(fd: number): Promise<void> {
  const bytes = (await fs.stat(fd)).size;
  await fs.truncate(fd, 0);
  await fs.truncate(fd, bytes);
}

export async function writeLinuxBytes(fd: number, bytes: ArrayBuffer, offset: number): Promise<void> {
  let written = 0;
  while (written < bytes.byteLength) {
    const count = await fs.write(fd, bytes.slice(written), { offset: offset + written });
    if (count <= 0) { throw new Error('Incomplete Linux request'); }
    written += count;
  }
}

async function readAt(fd: number, size: number, offset: number): Promise<ArrayBuffer> {
  const bytes = new Uint8Array(size);
  let read = 0;
  while (read < size) {
    const chunk = new ArrayBuffer(size - read);
    const count = await fs.read(fd, chunk, { offset: offset + read });
    if (count <= 0) { throw new Error('Incomplete Linux receipt'); }
    bytes.set(new Uint8Array(chunk, 0, count), read);
    read += count;
  }
  return bytes.buffer as ArrayBuffer;
}

export async function copyLinuxBytes(source: number, destination: number, sourceOffset: number, destinationOffset: number,
  length: number, signal: Cancellation): Promise<void> {
  let copied = 0;
  while (copied < length) {
    signal.check();
    const size = Math.min(COPY_CHUNK, length - copied);
    const bytes = await readAt(source, size, sourceOffset + copied);
    await writeLinuxBytes(destination, bytes, destinationOffset + copied);
    copied += size;
  }
}

export async function writeLinuxRequest(fd: number, json: string): Promise<void> {
  const packet = new util.TextEncoder().encodeInto(json);
  if (packet.byteLength > HALF - HEADER) {
    throw new ToolFailure('LIMIT_EXCEEDED', 'Request exceeds exchange disk.', 'reduce_input');
  }
  const header = new ArrayBuffer(HEADER);
  const frame = new DataView(header);
  frame.setUint32(0, 0x54424a33);
  frame.setUint32(4, packet.byteLength, true);
  await writeLinuxBytes(fd, new ArrayBuffer(HEADER), HALF);
  await writeLinuxBytes(fd, header, 0);
  await writeLinuxBytes(fd, packet.buffer as ArrayBuffer, HEADER);
  await fs.fsync(fd);
}

export async function readLinuxResponse(fd: number, diagnostics: string = ''): Promise<string> {
  const header = new DataView(await readAt(fd, HEADER, HALF));
  const length = header.getUint32(4, true);
  if (header.getUint32(0) !== 0x54425233 || length < 2 || length > HALF - HEADER) {
    throw new ToolFailure('EXECUTION_FAILED', 'Linux guest exited without a valid v3 receipt. ' + diagnostics, 'inspect_result_before_retry');
  }
  const bytes = await readAt(fd, length, HALF + HEADER);
  return util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(new Uint8Array(bytes));
}
