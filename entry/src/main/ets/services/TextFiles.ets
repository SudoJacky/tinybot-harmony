import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { t } from '../model/I18n';
import { Cancellation } from './Cancellation';
import { ToolFailure } from '../model/ToolFailure';

export async function importTextFile(uri: string): Promise<string> {
  const file = await fs.open(uri, fs.OpenMode.READ_ONLY);
  try { return await readUtf8File(file.fd); } finally { await fs.close(file); }
}

// The chunk size bounds each I/O allocation, not the size of an accepted text file.
export async function readUtf8File(fd: number, cancellation: Cancellation = new Cancellation(), maximum?: number): Promise<string> {
  const stat = await fs.stat(fd);
  if (!stat.isFile()) { throw new Error(t('请选择普通文件。')); }
  const overLimit = (): ToolFailure => new ToolFailure('LIMIT_EXCEEDED', 'Text exceeds the remaining workspace script byte budget.', 'reduce_input');
  if (maximum !== undefined && stat.size > maximum) { throw overLimit(); }
  // Harmony's ignoreBOM=true removes the marker (opposite to WHATWG TextDecoder).
  const decoder = new util.TextDecoder('utf-8', { fatal: true, ignoreBOM: false });
  const buffer = new ArrayBuffer(64 * 1024);
  const parts: string[] = [];
  let bytes = 0;
  while (true) {
    cancellation.check();
    const count = await fs.read(fd, buffer);
    if (count === 0) { break; }
    bytes += count;
    if (maximum !== undefined && bytes > maximum) { throw overLimit(); }
    const text = decoder.decodeToString(new Uint8Array(buffer, 0, count), { stream: true });
    if (text.includes('\u0000')) { throw new Error(t('此文件不是可读取的文本文件。')); }
    parts.push(text);
  }
  parts.push(decoder.decodeToString(new Uint8Array(0), { stream: false }));
  cancellation.check();
  return parts.join('');
}
