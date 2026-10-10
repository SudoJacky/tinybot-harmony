import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { t } from '../model/I18n';
import { Cancellation } from './Cancellation';

export async function importTextFile(uri: string): Promise<string> {
  const file = await fs.open(uri, fs.OpenMode.READ_ONLY);
  try { return await readUtf8File(file.fd); } finally { await fs.close(file); }
}

// The chunk size bounds each I/O allocation, not the size of an accepted text file.
export async function readUtf8File(fd: number, cancellation: Cancellation = new Cancellation()): Promise<string> {
  if (!(await fs.stat(fd)).isFile()) { throw new Error(t('请选择普通文件。')); }
  const decoder = new util.TextDecoder('utf-8', { fatal: true });
  const buffer = new ArrayBuffer(64 * 1024);
  const parts: string[] = [];
  while (true) {
    cancellation.check();
    const count = await fs.read(fd, buffer);
    if (count === 0) { break; }
    const text = decoder.decodeToString(new Uint8Array(buffer, 0, count), { stream: true });
    if (text.includes('\u0000')) { throw new Error(t('此文件不是可读取的文本文件。')); }
    parts.push(text);
  }
  parts.push(decoder.decodeToString(new Uint8Array(0), { stream: false }));
  cancellation.check();
  return parts.join('');
}
