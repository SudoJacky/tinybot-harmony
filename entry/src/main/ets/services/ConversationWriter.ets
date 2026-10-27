import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

// The UI submits an immutable string. Encoding, buffer copies and filesystem work
// belong to the worker; a worker/IO failure rejects the original save barrier.
@Concurrent
export async function writeConversationFile(path: string, text: string): Promise<number> {
  const bytes = new util.TextEncoder().encodeInto(text);
  const file = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  try {
    let written = 0;
    while (written < bytes.byteLength) {
      const count = await fs.write(file.fd, written === 0 ? bytes.buffer : bytes.buffer.slice(written), { offset: written });
      if (count <= 0) { throw new Error('Conversation file write made no progress.'); }
      written += count;
    }
    await fs.fsync(file.fd);
    return bytes.byteLength;
  } finally { await fs.close(file); }
}
