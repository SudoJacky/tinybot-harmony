import { worker, MessageEvents } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';
import { Diagnostics } from '../model/Diagnostics';
import { MathDimensions, MathRequest, MathResponse } from '../model/MathContent';

export interface MathImage extends MathDimensions {
  id: number;
  pixelMap: image.PixelMap;
}

export interface MathLease {
  result: Promise<MathImage>;
  release: () => void;
}

interface Entry {
  key: string;
  job: MathRequest;
  result: Promise<MathImage>;
  resolve: (image: MathImage) => void;
  reject: (error: Error) => void;
  users: number;
  bytes: number;
  done: boolean;
  pixelMap?: image.PixelMap;
}

// Visible views pin their bitmaps. Evict least recently used unpinned bitmaps as needed.
const CACHE_BYTES: number = 32 * 1024 * 1024;
const CACHE_ENTRIES: number = 384;
const entries = new Map<string, Entry>();
const waiting = new Map<string, Entry>();
let renderer: worker.ThreadWorker | undefined;
let active: Entry | undefined;
let timeout: number = -1;
let sequence: number = 0;
let bytes: number = 0;

function trim(): void {
  for (const key of entries.keys()) {
    if (bytes <= CACHE_BYTES && entries.size <= CACHE_ENTRIES) { return; }
    const entry = entries.get(key)!;
    if (!entry.done || entry.users) { continue; }
    entries.delete(key);
    bytes -= entry.bytes;
    entry.pixelMap?.release().catch((error: Error) => Diagnostics.log('warn', 'math', 'bitmap_release_failed', undefined, error));
  }
}

function complete(response?: MathResponse, failure: string = 'worker_failed'): void {
  const entry = active;
  if (!entry) { return; }
  clearTimeout(timeout); timeout = -1; active = undefined;
  entry.done = true;
  if (response?.pixelMap && !response.error) {
    entry.pixelMap = response.pixelMap;
    entry.bytes = response.bytes; bytes += response.bytes;
    entry.resolve({ id: ++sequence, pixelMap: response.pixelMap, width: response.width, height: response.height, descent: response.descent });
  } else {
    const code = response?.error || failure;
    if (code !== 'invalid_formula' && code !== 'formula_too_large') { entries.delete(entry.key); }
    Diagnostics.log('warn', 'math', code, { code: response?.nativeCode });
    entry.reject(new Error(code));
  }
  trim();
  next();
}

function restart(code: string): void {
  const previous = renderer;
  renderer = undefined;
  previous?.terminate();
  complete(undefined, code);
}

function dispatch(entry: Entry): void {
  if (!renderer) {
    const thread = new worker.ThreadWorker('entry/ets/workers/MathWorker.ets');
    renderer = thread;
    thread.onmessage = (event: MessageEvents) => {
      if (renderer === thread) { complete(event.data as MathResponse); }
    };
    thread.onerror = () => { if (renderer === thread) { restart('worker_failed'); } };
    thread.onmessageerror = () => { if (renderer === thread) { restart('worker_message_failed'); } };
    thread.onexit = () => {
      if (renderer === thread) { renderer = undefined; complete(undefined, 'worker_exited'); }
    };
  }
  timeout = setTimeout(() => restart('worker_timeout'), 8000);
  renderer.postMessage(entry.job);
}

function next(): void {
  if (active || !waiting.size) { return; }
  for (const key of waiting.keys()) {
    const entry = waiting.get(key)!;
    waiting.delete(key);
    active = entry;
    try { dispatch(entry); }
    catch (error) {
      Diagnostics.log('warn', 'math', 'worker_dispatch_failed', undefined, error as Error);
      restart('worker_dispatch_failed');
    }
    return;
  }
}

export function acquireMath(tex: string, display: boolean, color: string, emPixels: number): MathLease {
  const key = JSON.stringify([tex, display, color, emPixels]);
  let entry = entries.get(key);
  if (entry) {
    entries.delete(key);
  } else {
    let resolve: (image: MathImage) => void = () => {};
    let reject: (error: Error) => void = () => {};
    const result = new Promise<MathImage>((answer, fail) => { resolve = answer; reject = fail; });
    const job: MathRequest = { tex: tex, display: display, color: color, emPixels: emPixels };
    entry = { key: key, job: job, result: result, resolve: resolve, reject: reject, users: 0, bytes: 0, done: false };
    waiting.set(key, entry);
  }
  const leased = entry;
  leased.users++;
  entries.set(key, leased);
  next();
  let released = false;
  return { result: leased.result, release: () => {
    if (released) { return; }
    released = true;
    leased.users--;
    if (!leased.users && waiting.get(key) === leased) {
      waiting.delete(key);
      entries.delete(key);
      leased.reject(new Error('cancelled'));
    }
    trim();
  }};
}
