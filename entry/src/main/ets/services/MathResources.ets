import { worker, MessageEvents } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { Diagnostics } from '../model/Diagnostics';
import { MathDimensions, MathRequest, MathResponse } from '../model/MathContent';

export interface MathImage extends MathDimensions {
  uri: string;
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
}

const CACHE_BYTES: number = 8 * 1024 * 1024;
const CACHE_ENTRIES: number = 384;
const entries = new Map<string, Entry>();
const waiting = new Map<string, Entry>();
let renderer: worker.ThreadWorker | undefined;
let active: Entry | undefined;
let initialized: boolean = false;
let timeout: number = -1;
let sequence: number = 0;
let bytes: number = 0;

function unlink(path: string): void {
  fs.access(path).then(async (exists: boolean) => { if (exists) { await fs.unlink(path); } })
    .catch(() => Diagnostics.log('warn', 'math', 'cache_remove_failed'));
}

function trim(): void {
  for (const key of entries.keys()) {
    if (bytes <= CACHE_BYTES && entries.size <= CACHE_ENTRIES) { return; }
    const entry = entries.get(key)!;
    if (!entry.done || entry.users) { continue; }
    entries.delete(key);
    bytes -= entry.bytes;
    if (entry.bytes) { unlink(entry.job.path); }
  }
}

function complete(response?: MathResponse, failure: string = 'worker_failed'): void {
  const entry = active;
  if (!entry) { return; }
  clearTimeout(timeout); timeout = -1; active = undefined;
  entry.done = true;
  if (response && !response.error) {
    entry.bytes = response.bytes; bytes += response.bytes;
    entry.resolve({ uri: 'file://' + entry.job.path, width: response.width, height: response.height, descent: response.descent });
  } else {
    const code = response?.error || failure;
    if (code === 'cache_write_failed' || !response) {
      entries.delete(entry.key);
      unlink(entry.job.path);
    }
    Diagnostics.log('warn', 'math', code);
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

async function dispatch(entry: Entry): Promise<void> {
  if (!initialized) {
    const directory = entry.job.path.slice(0, entry.job.path.lastIndexOf('/'));
    if (await fs.access(directory)) { await fs.rmdir(directory); }
    await fs.mkdir(directory);
    initialized = true;
  }
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
    dispatch(entry).catch((error: Error) => {
      Diagnostics.log('warn', 'math', 'worker_dispatch_failed', undefined, error);
      restart('worker_dispatch_failed');
    });
    return;
  }
}

export async function forgetMissingMath(tex: string, display: boolean, color: string, uri: string): Promise<boolean> {
  const key = JSON.stringify([tex, display, color]);
  const path = uri.slice('file://'.length);
  if (await fs.access(path)) { return false; }
  const entry = entries.get(key);
  if (entry?.job.path === path) {
    entries.delete(key);
    bytes -= entry.bytes;
  }
  return true;
}

export function acquireMath(cacheDir: string, tex: string, display: boolean, color: string): MathLease {
  const key = JSON.stringify([tex, display, color]);
  let entry = entries.get(key);
  if (entry) {
    entries.delete(key);
  } else {
    let resolve: (image: MathImage) => void = () => {};
    let reject: (error: Error) => void = () => {};
    const result = new Promise<MathImage>((answer, fail) => { resolve = answer; reject = fail; });
    const path = cacheDir + '/math-svg/' + (++sequence) + '.svg';
    const job: MathRequest = { tex: tex, display: display, color: color, path: path };
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
