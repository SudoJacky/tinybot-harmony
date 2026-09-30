import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { AppData, emptyData, parseAppData } from './Conversation';
import { SessionRepository } from '../services/SessionContracts';

export class ConversationStore implements SessionRepository {
  private path: string;
  private pendingSave: Promise<void> = Promise.resolve();

  constructor(filesDir: string) {
    this.path = filesDir + '/tinybot-v1.json';
  }

  async load(): Promise<AppData> {
    if (!await fs.access(this.path)) {
      return emptyData();
    }
    return parseAppData(await fs.readText(this.path));
  }

  // Queue updates can arrive during tool checkpoints. Snapshot at call time and serialize writes
  // so they cannot truncate the same temporary file or publish older state after newer state.
  save(data: AppData): Promise<void> {
    const bytes = new util.TextEncoder().encodeInto(JSON.stringify(data));
    const saved = this.pendingSave.then(() => this.write(bytes));
    // The caller receives the failure. A later explicit save may retry with the current snapshot.
    this.pendingSave = saved.catch(() => {});
    return saved;
  }

  private async write(bytes: Uint8Array): Promise<void> {
    const temporaryPath = this.path + '.tmp';
    const file = await fs.open(temporaryPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      let written = 0;
      while (written < bytes.byteLength) {
        const count = await fs.write(file.fd, bytes.buffer.slice(written), { offset: written });
        if (count <= 0) {
          throw new Error('本地会话写入未完成。');
        }
        written += count;
      }
      await fs.fsync(file.fd);
    } finally {
      await fs.close(file);
    }
    await fs.rename(temporaryPath, this.path);
  }
}
