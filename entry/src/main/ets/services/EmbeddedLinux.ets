import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { socket } from '@kit.NetworkKit';
import native from 'libtinybot_sandbox.so';
import { Cancellation } from './Cancellation';

interface QmpError { desc: string; }
interface QmpStatus { running?: boolean; }
interface QmpMessage { QMP?: Object; event?: string; id?: number; error?: QmpError; return?: QmpStatus; }
interface QmpCommand { execute: string; id: number; }

function pause(): Promise<void> { return new Promise<void>((resolve) => setTimeout(resolve, 30)); }

// One QEMU machine in this app process, shared by jobs and the user console.
// The guest boots from the read-only root for every call, including after cancellation.
export class EmbeddedLinux {
  private client?: socket.LocalSocket;
  private disk?: fs.File;
  private incoming: string = '';
  private greeted: boolean = false;
  private sequence: number = 0;
  private reply?: QmpMessage;
  private shutdown: boolean = false;
  private resets: number = 0;
  private fault: string = '';

  get initialized(): boolean { return this.client !== undefined; }

  private async until(ready: () => boolean, timeout: number, action: string, cancel?: Cancellation): Promise<void> {
    const deadline = Date.now() + timeout;
    while (!ready()) {
      cancel?.check();
      if (this.fault) { throw new Error(this.fault); }
      if (timeout > 0 && Date.now() >= deadline) { throw new Error('Linux timed out waiting for ' + action); }
      await pause();
    }
  }

  private receive(text: string): void {
    this.incoming += text;
    let end = this.incoming.indexOf('\n');
    try {
      while (end >= 0) {
        const line = this.incoming.slice(0, end).trim();
        this.incoming = this.incoming.slice(end + 1);
        if (line) {
          const msg = JSON.parse(line) as QmpMessage;
          if (msg.QMP) { this.greeted = true; }
          if (msg.event === 'SHUTDOWN') { this.shutdown = true; }
          if (msg.event === 'RESET') { this.resets++; }
          if (msg.id === this.sequence) { this.reply = msg; }
        }
        end = this.incoming.indexOf('\n');
      }
    } catch (error) { this.fault = 'Invalid QMP message: ' + (error as Error).message; }
  }

  private lastReply(): QmpMessage {
    if (!this.reply) { throw new Error('QMP response missing'); }
    return this.reply;
  }

  private async command(name: string): Promise<QmpStatus> {
    if (!this.client || this.fault) { throw new Error(this.fault || 'Linux control socket is unavailable'); }
    this.reply = undefined;
    const cmd: QmpCommand = { execute: name, id: ++this.sequence };
    await this.client.send({ data: JSON.stringify(cmd) + '\n' });
    await this.until(() => this.reply !== undefined, 5000, name);
    const message = this.lastReply();
    if (message.error) { throw new Error('QMP ' + name + ': ' + message.error.desc); }
    return message.return || {};
  }

  private async start(dir: string): Promise<void> {
    const client = socket.constructLocalSocketInstance();
    this.client = client;
    try {
      this.disk = await fs.open(dir + '/exchange', fs.OpenMode.READ_WRITE);
      client.on('message', (event: socket.LocalSocketMessageInfo) => {
        this.receive(new util.TextDecoder('utf-8').decodeToString(new Uint8Array(event.message)));
      });
      client.on('error', (error: Error) => { this.fault = 'QMP: ' + error.message; });
      client.on('close', () => { this.fault = 'The embedded Linux engine closed its control connection.'; });
      native.startEmbeddedLinux(dir);
      const path = dir + '/qmp';
      const deadline = Date.now() + 12000;
      while (!(await fs.access(path))) {
        if (Date.now() >= deadline) { throw new Error('Linux did not create its QMP socket'); }
        await pause();
      }
      await client.connect({ address: { address: path }, timeout: 3000 });
      await this.until(() => this.greeted, 12000, 'QMP greeting');
      await this.command('qmp_capabilities');
    } catch (error) {
      this.fault = 'Embedded Linux initialization failed: ' + (error as Error).message;
      throw new Error(this.fault);
    }
  }

  private async reset(): Promise<void> {
    await this.command('stop');
    const previous = this.resets;
    await this.command('system_reset');
    await this.until(() => this.resets > previous, 5000, 'guest reset');
    if ((await this.command('query-status')).running !== false) { throw new Error('Guest failed to pause after reset'); }
  }

  private async writeRequest(dir: string, packet: ArrayBuffer, cancellation: Cancellation): Promise<fs.File> {
    if (this.fault) { throw new Error(this.fault); }
    if (!this.client) { await this.start(dir); }
    const file = this.disk;
    if (!file) { throw new Error('Linux exchange disk unavailable'); }
    let pos = 0;
    while (pos < packet.byteLength) {
      const written = await fs.write(file.fd, packet.slice(pos), { offset: pos });
      if (written <= 0) { throw new Error('Incomplete Linux request'); }
      pos += written;
    }
    await fs.fsync(file.fd);
    cancellation.check();
    return file;
  }

  private async boot<T>(timeout: number, cancellation: Cancellation, finish: () => Promise<T>): Promise<T> {
    this.shutdown = false;
    try {
      await this.command('cont');
      await this.until(() => this.shutdown, timeout, 'guest completion', cancellation);
      return await finish();
    } finally {
      try { await this.reset(); }
      catch (error) {
        this.fault = 'Linux guest could not reset: ' + (error as Error).message;
        throw new Error(this.fault);
      }
    }
  }

  async console(dir: string, packet: ArrayBuffer, cancellation: Cancellation, connect: () => Promise<void>): Promise<void> {
    await this.writeRequest(dir, packet, cancellation);
    await connect();
    cancellation.check();
    await this.boot<void>(0, cancellation, async () => {});
  }

  async run(dir: string, packet: ArrayBuffer, cancellation: Cancellation): Promise<ArrayBuffer> {
    const file = await this.writeRequest(dir, packet, cancellation);
    return this.boot<ArrayBuffer>(120000, cancellation, async () => {
      const result = new Uint8Array(packet.byteLength);
      let pos = 0;
      while (pos < result.length) {
        const chunk = new ArrayBuffer(result.length - pos);
        const count = await fs.read(file.fd, chunk, { offset: pos });
        if (count <= 0) { throw new Error('Incomplete Linux receipt'); }
        result.set(new Uint8Array(chunk, 0, count), pos); pos += count;
      }
      return result.buffer as ArrayBuffer;
    });
  }
}
