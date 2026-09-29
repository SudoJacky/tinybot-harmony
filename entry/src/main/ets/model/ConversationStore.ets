import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { AppData, emptyData, parseAppData } from './Conversation';

export class ConversationStore {
  private path: string;

  constructor(filesDir: string) {
    this.path = filesDir + '/tinybot-v1.json';
  }

  async load(): Promise<AppData> {
    if (!await fs.access(this.path)) {
      return emptyData();
    }
    return parseAppData(await fs.readText(this.path));
  }

  // The ViewModel serializes mutations. The old file survives any failure before rename.
  async save(data: AppData): Promise<void> {
    const bytes = new util.TextEncoder().encodeInto(JSON.stringify(data));
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
