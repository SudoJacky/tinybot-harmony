import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { socket } from '@kit.NetworkKit';

interface QmpError { desc: string; }
interface QmpMessage { QMP?: Object; event?: string; id?: number; error?: QmpError; }
interface QmpCommand { execute: string; id: number; }

function pause(): Promise<void> { return new Promise<void>((resolve) => setTimeout(resolve, 30)); }

export class LinuxControl {
  private client?: socket.LocalSocket;
  private incoming: string = '';
  private greeted: boolean = false;
  private sequence: number = 0;
  private reply?: QmpMessage;
  private fault: string = '';
  private notify?: () => void;
  private onFault: (error: Error) => void;

  constructor(onFault: (error: Error) => void) { this.onFault = onFault; }

  private fail(message: string): void {
    this.fault = message;
    this.notify?.();
    this.onFault(new Error(message));
  }

  private async until(ready: () => boolean, timeout: number, action: string): Promise<void> {
    if (this.fault) { throw new Error(this.fault); }
    if (ready()) { return; }
    if (this.notify) { throw new Error('Another Linux control response is pending'); }
    let timer: number = -1;
    try {
      await new Promise<void>((resolve, reject) => {
        this.notify = () => {
          if (this.fault) { reject(new Error(this.fault)); }
          else if (ready()) { resolve(); }
        };
        timer = setTimeout(() => reject(new Error('Linux timed out waiting for ' + action)), timeout);
      });
    } finally { clearTimeout(timer); this.notify = undefined; }
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
          if (msg.event === 'SHUTDOWN') { this.fail('Linux shut down unexpectedly'); }
          if (msg.id === this.sequence) { this.reply = msg; }
          this.notify?.();
        }
        end = this.incoming.indexOf('\n');
      }
    } catch (error) { this.fail('Invalid QMP message: ' + (error as Error).message); }
  }

  private lastReply(): QmpMessage {
    if (!this.reply) { throw new Error('QMP response missing'); }
    return this.reply;
  }

  private async command(name: string): Promise<void> {
    if (!this.client || this.fault) { throw new Error(this.fault || 'Linux control socket is unavailable'); }
    this.reply = undefined;
    const cmd: QmpCommand = { execute: name, id: ++this.sequence };
    await this.client.send({ data: JSON.stringify(cmd) + '\n' });
    await this.until(() => this.reply !== undefined, 5000, name);
    const message = this.lastReply();
    if (message.error) { throw new Error('QMP ' + name + ': ' + message.error.desc); }
  }

  async connect(dir: string): Promise<void> {
    const client = socket.constructLocalSocketInstance();
    this.client = client;
    try {
      client.on('message', (event: socket.LocalSocketMessageInfo) => {
        this.receive(new util.TextDecoder('utf-8').decodeToString(new Uint8Array(event.message)));
      });
      client.on('error', (error: Error) => { this.fail('QMP: ' + error.message); });
      client.on('close', () => { this.fail('Linux closed its control connection.'); });
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
      this.fail('Linux control initialization failed: ' + (error as Error).message);
      throw new Error(this.fault);
    }
  }

  async setRunning(running: boolean): Promise<void> {
    await this.command(running ? 'cont' : 'stop');
  }
}
