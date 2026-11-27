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

// One QEMU machine in this app process. Only its private exchange inode stays open.
// The guest boots from the read-only root for every call, including after cancellation.
export class EmbeddedLinux {
  private client?: socket.LocalSocket;
  private incoming: string = '';
  private greeted: boolean = false;
  private sequence: number = 0;
  private reply?: QmpMessage;
  private shutdown: boolean = false;
  private resets: number = 0;
  private fault: string = '';
  private onFault: () => void;

  constructor(onFault: () => void) { this.onFault = onFault; }

  get initialized(): boolean { return this.client !== undefined; }
  get failure(): string { return this.fault; }

  private fail(message: string): void {
    this.fault = message;
    this.onFault();
  }

  private async until(ready: () => boolean, timeout: number, action: string, cancel?: Cancellation): Promise<void> {
    const deadline = Date.now() + timeout;
    while (!ready()) {
      cancel?.check();
      if (this.fault) { throw new Error(this.fault); }
      if (Date.now() >= deadline) { throw new Error('Linux timed out waiting for ' + action); }
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
    } catch (error) { this.fail('Invalid QMP message: ' + (error as Error).message); }
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

  async start(dir: string, memoryMiB: number): Promise<void> {
    const client = socket.constructLocalSocketInstance();
    this.client = client;
    try {
      client.on('message', (event: socket.LocalSocketMessageInfo) => {
        this.receive(new util.TextDecoder('utf-8').decodeToString(new Uint8Array(event.message)));
      });
      client.on('error', (error: Error) => { this.fail('QMP: ' + error.message); });
      client.on('close', () => { this.fail('The embedded Linux engine closed its control connection.'); });
      native.startEmbeddedLinux(dir, memoryMiB);
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
      this.fail('Embedded Linux initialization failed: ' + (error as Error).message);
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

  async run(cancellation: Cancellation, timeoutSeconds: number): Promise<void> {
    if (this.fault) { throw new Error(this.fault); }
    cancellation.check();
    this.shutdown = false;
    try {
      await this.command('cont');
      await this.until(() => this.shutdown, timeoutSeconds * 1000, 'guest completion', cancellation);
    } finally {
      try { await this.reset(); }
      catch (error) {
        this.fail('Linux guest could not reset: ' + (error as Error).message);
        throw new Error(this.fault);
      }
    }
  }
}
