import { image } from '@kit.ImageKit';
import { Diagnostics } from '../model/Diagnostics';

interface MermaidStartup {
  id: number;
  visibility: number;
  start: () => void;
}

// Opening an ArkWeb surface can block the UI thread. Start another only after this one has rendered or left the list.
class MermaidStartupQueue {
  private jobs: Map<number, MermaidStartup> = new Map();
  private active: number = -1;
  private timer: number = -1;

  request(id: number, visibility: number, start: () => void): void {
    if (this.active === id) { return; }
    this.jobs.set(id, { id: id, visibility: visibility, start: start });
    this.schedule();
  }

  remove(id: number): void { this.jobs.delete(id); }

  finish(id: number): void {
    this.remove(id);
    if (this.active !== id) { return; }
    this.active = -1;
    this.schedule();
  }

  private schedule(): void {
    if (this.active !== -1 || this.timer !== -1 || !this.jobs.size) { return; }
    this.timer = setTimeout(() => {
      this.timer = -1;
      let next: MermaidStartup | undefined;
      for (const job of this.jobs.values()) {
        if (!next || job.visibility > next.visibility) { next = job; }
      }
      if (!next) { return; }
      this.active = next.id;
      this.jobs.delete(next.id);
      next.start();
    }, 16);
  }
}

export const mermaidStartup: MermaidStartupQueue = new MermaidStartupQueue();
const MAX_PREVIEW_BYTES: number = 24 * 1024 * 1024;
export const MAX_MERMAID_SNAPSHOT_PIXELS: number = 2 * 1024 * 1024;

interface PreviewEntry {
  pixel: image.PixelMap;
  height: number;
  bytes: number;
  users: number;
}

export interface MermaidPreview {
  pixel: image.PixelMap;
  height: number;
  release: () => void;
}

export async function mermaidPreviewHasContent(pixel: image.PixelMap, width: number, height: number): Promise<boolean> {
  const sample = await pixel.createScaledPixelMap(Math.min(1, 48 / width), Math.min(1, 48 / height));
  try {
    const buffer = new ArrayBuffer(sample.getPixelBytesNumber());
    await sample.readPixelsToBuffer(buffer);
    const colors = new Uint8Array(buffer);
    for (let offset = 4; offset + 3 < colors.length; offset += 4) {
      for (let channel = 0; channel < 4; channel++) {
        if (Math.abs(colors[offset + channel] - colors[channel]) > 8) { return true; }
      }
    }
    return false;
  } finally { await sample.release(); }
}

function releasePixel(pixel: image.PixelMap): void {
  pixel.release().catch((error: Error) => Diagnostics.log('warn', 'mermaid', 'snapshot_release_failed', undefined, error));
}

class MermaidPreviewCache {
  private entries: Map<string, PreviewEntry> = new Map();
  private bytes: number = 0;

  has(key: string): boolean { return this.entries.has(key); }

  acquire(key: string): MermaidPreview | undefined {
    const entry = this.entries.get(key);
    if (!entry) { return undefined; }
    this.entries.delete(key); this.entries.set(key, entry);
    entry.users++;
    return { pixel: entry.pixel, height: entry.height, release: () => { entry.users--; } };
  }

  store(key: string, pixel: image.PixelMap, height: number): void {
    const bytes = pixel.getPixelBytesNumber();
    if (!bytes || bytes > MAX_PREVIEW_BYTES || this.entries.has(key)) { releasePixel(pixel); return; }
    for (const entryKey of this.entries.keys()) {
      if (this.bytes + bytes <= MAX_PREVIEW_BYTES) { break; }
      const entry = this.entries.get(entryKey)!;
      if (entry.users) { continue; }
      this.entries.delete(entryKey);
      this.bytes -= entry.bytes;
      releasePixel(entry.pixel);
    }
    if (this.bytes + bytes > MAX_PREVIEW_BYTES) { releasePixel(pixel); return; }
    this.entries.set(key, { pixel: pixel, height: height, bytes: bytes, users: 0 });
    this.bytes += bytes;
  }
}

export const mermaidPreviews: MermaidPreviewCache = new MermaidPreviewCache();
