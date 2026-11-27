import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { socket } from '@kit.NetworkKit';
import { Cancellation } from './Cancellation';

const READY: number[] = [84, 66, 67, 49]; // TBC1
const CHUNK: number = 16384;
const INPUT_LIMIT: number = 128 * 1024;

export interface LinuxSerialEvents {
  ready: () => void;
  output: (bytes: Uint8Array) => void;
  failed: (error: Error) => void;
}

export class LinuxSerial {
  private client?: socket.LocalSocket;
  private connected: boolean = false;
  private stopping: boolean = false;
  private marker: number = 0;
  private waitingBytes: number = 0;
  private pending: Promise<void> = Promise.resolve();
  private events: LinuxSerialEvents;

  constructor(events: LinuxSerialEvents) { this.events = events; }

  get ready(): boolean { return this.connected && this.marker === READY.length; }

  private receive(buffer: ArrayBuffer): void {
    if (this.stopping) { return; }
    const bytes = new Uint8Array(buffer);
    let offset = 0;
    while (this.marker < READY.length && offset < bytes.length) {
      if (bytes[offset++] !== READY[this.marker++]) {
        this.stopping = true;
        this.events.failed(new Error('Invalid Linux console startup response'));
        return;
      }
      if (this.marker === READY.length) { this.events.ready(); }
    }
    if (offset < bytes.length && !this.stopping) { this.events.output(bytes.subarray(offset)); }
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
    client.on('error', (error: Error) => { if (!this.stopping) { this.events.failed(error); } });
    client.on('close', () => { this.connected = false; });
    await client.connect({ address: { address: path }, timeout: 3000 });
    this.connected = true;
    cancellation.check();
  }

  private queue(kind: number, bytes: Uint8Array): Promise<void> {
    if (!this.ready || this.stopping || bytes.length === 0) { return Promise.resolve(); }
    if (this.waitingBytes + bytes.length > INPUT_LIMIT) { return Promise.reject(new Error('Linux console input queue is full')); }
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

  async close(): Promise<void> {
    this.stopping = true;
    if (this.connected && this.client) { await this.client.close(); }
    this.connected = false;
    this.client = undefined;
  }
}
