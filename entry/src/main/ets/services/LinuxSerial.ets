import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { socket } from '@kit.NetworkKit';
import { ToolFailure } from '../model/ToolFailure';
import { Cancellation } from './Cancellation';

const READY: number[] = [84, 66, 67, 50]; // TBC2
const CHUNK: number = 16384;
const INPUT_LIMIT: number = 128 * 1024;

export interface LinuxSerialEvents {
  ready: () => void;
  output: (bytes: Uint8Array, history?: boolean) => void;
  failed: (error: Error) => void;
}

export class LinuxSerial {
  private client?: socket.LocalSocket;
  private connected: boolean = false;
  private stopping: boolean = false;
  private marker: number = 0;
  private waitingBytes: number = 0;
  private pending: Promise<void> = Promise.resolve();
  private header: Uint8Array = new Uint8Array(3);
  private headerBytes: number = 0;
  private payload?: Uint8Array;
  private payloadBytes: number = 0;
  private jobDone?: (error?: Error, busy?: string) => void;
  private events: LinuxSerialEvents;

  constructor(events: LinuxSerialEvents) { this.events = events; }

  get ready(): boolean { return this.connected && this.marker === READY.length; }

  private receive(buffer: ArrayBuffer): void {
    if (this.stopping) { return; }
    const bytes = new Uint8Array(buffer);
    let offset = 0;
    while (this.marker < READY.length && offset < bytes.length) {
      if (bytes[offset++] !== READY[this.marker++]) {
        this.fail(new Error('Invalid Linux console startup response'));
        return;
      }
      if (this.marker === READY.length) { this.events.ready(); }
    }
    while (offset < bytes.length && !this.stopping) {
      if (this.headerBytes < 3) {
        const count = Math.min(3 - this.headerBytes, bytes.length - offset);
        this.header.set(bytes.subarray(offset, offset + count), this.headerBytes);
        offset += count;
        this.headerBytes += count;
        if (this.headerBytes < 3) { return; }
      }
      const kind = this.header[0];
      const size = this.header[1] | (this.header[2] << 8);
      if (!(kind === 1 && size > 0 && size <= CHUNK || kind === 3 && size === 1)) {
        this.fail(new Error('Invalid Linux runtime frame'));
        return;
      }
      let frame: Uint8Array;
      if (!this.payload && bytes.length - offset >= size) {
        frame = bytes.subarray(offset, offset + size);
        offset += size;
      } else {
        // Allocate once per split frame, regardless of socket fragmentation.
        const partial = this.payload ?? (this.payload = new Uint8Array(size));
        const count = Math.min(size - this.payloadBytes, bytes.length - offset);
        partial.set(bytes.subarray(offset, offset + count), this.payloadBytes);
        this.payloadBytes += count;
        offset += count;
        if (this.payloadBytes < size) { return; }
        frame = partial;
        this.payload = undefined;
        this.payloadBytes = 0;
      }
      this.headerBytes = 0;
      if (kind === 1) { this.events.output(frame); }
      else if (this.jobDone) {
        const status = frame[0];
        if (status > 4) { this.fail(new Error('Invalid Linux task status')); return; }
        const reasons: string[] = ['', '', 'The terminal has an unfinished input line.',
          'The terminal is processing keyboard input.', 'The terminal is running a foreground command.'];
        this.jobDone(status === 1 ? new Error('Linux task worker exited') : undefined, reasons[status]);
      }
    }
  }

  async connect(path: string, cancellation: Cancellation, exited: () => boolean = () => false): Promise<void> {
    const deadline = Date.now() + 12000;
    while (!await fs.access(path)) {
      cancellation.check();
      if (exited()) { throw new Error('Linux exited before opening the console socket'); }
      if (Date.now() >= deadline) { throw new Error('Linux did not open the console socket'); }
      await new Promise<void>((resolve) => setTimeout(resolve, 40));
    }
    cancellation.check();
    const client = socket.constructLocalSocketInstance();
    this.client = client;
    client.on('message', (event: socket.LocalSocketMessageInfo) => { this.receive(event.message); });
    client.on('error', (error: Error) => { this.fail(error); });
    client.on('close', () => { this.connected = false; this.fail(new Error('Linux serial disconnected')); });
    await client.connect({ address: { address: path }, timeout: 3000 });
    this.connected = true;
    cancellation.check();
  }

  private queue(kind: number, bytes: Uint8Array): Promise<void> {
    if (!this.ready || this.stopping || bytes.length === 0) { return Promise.resolve(); }
    if (this.waitingBytes + bytes.length > INPUT_LIMIT && kind === 1) {
      return Promise.reject(new ToolFailure('LIMIT_EXCEEDED', 'Linux console input queue is full', 'reduce_input'));
    }
    this.waitingBytes += bytes.length;
    const send = async (): Promise<void> => {
      try {
        for (let from = 0; from < bytes.length; from += CHUNK) {
          if (!this.ready || this.stopping || !this.client) { return; }
          const length = Math.min(CHUNK, bytes.length - from);
          const frame = new Uint8Array(3 + length);
          frame[0] = kind;
          new DataView(frame.buffer).setUint16(1, length, true);
          frame.set(bytes.subarray(from, from + length), 3);
          await this.client.send({ data: frame.buffer as ArrayBuffer });
        }
      } finally { this.waitingBytes -= bytes.length; }
    };
    this.pending = this.pending.then(send, send);
    return this.pending;
  }

  input(text: string): Promise<void> {
    return this.queue(1, new util.TextEncoder().encodeInto(text));
  }

  resize(columns: number, rows: number): Promise<void> {
    if (!Number.isInteger(columns) || !Number.isInteger(rows) || columns < 2 || columns > 500 || rows < 2 || rows > 300) {
      return Promise.resolve();
    }
    const size = new Uint8Array(4);
    const fields = new DataView(size.buffer);
    fields.setUint16(0, columns, true);
    fields.setUint16(2, rows, true);
    return this.queue(2, size);
  }

  fail(error: Error): void {
    if (this.stopping) { return; }
    this.stopping = true;
    this.jobDone?.(error);
    this.events.failed(error);
  }

  async runJob(signal: Cancellation, seconds: number, shared: boolean): Promise<void> {
    signal.check();
    if (!this.ready || this.stopping || this.jobDone) { throw new Error('Linux job channel unavailable'); }
    let abort: Error | undefined;
    let watchdog: number = -1;
    let disconnect: () => void = () => {};
    const control = (kind: number): void => {
      this.queue(kind, new Uint8Array([0])).catch((error: Error) => this.fail(error));
    };
    const cancel = (error: Error): void => {
      if (abort || !this.jobDone) { return; }
      abort = error;
      control(4);
      watchdog = setTimeout(() => this.fail(new Error('Linux did not acknowledge cancellation')), 10000);
    };
    const timeout = setTimeout(() => cancel(new Error('Linux task exceeded ' + seconds + ' seconds')), seconds * 1000);
    try {
      await new Promise<void>((resolve, reject) => {
        this.jobDone = (error?: Error, busy?: string): void => {
          this.jobDone = undefined;
          if (abort || error) { reject(abort ?? error); }
          else if (busy) { reject(new ToolFailure('BUSY', busy, 'wait_then_check')); }
          else { resolve(); }
        };
        control(shared ? 5 : 3);
        disconnect = signal.onCancel(() => cancel(new Error('Linux job cancelled')));
      });
    } catch (error) { signal.check(); throw error as Error; }
    finally { disconnect(); clearTimeout(timeout); clearTimeout(watchdog); }
  }

  async close(): Promise<void> {
    this.stopping = true;
    if (this.connected && this.client) { await this.client.close(); }
    this.connected = false;
    this.client = undefined;
  }
}
