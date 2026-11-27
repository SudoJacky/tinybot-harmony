import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { deviceInfo } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import native from 'libtinybot_sandbox.so';
import { ToolFailure } from '../model/ToolFailure';
import { Cancellation } from './Cancellation';
import { EmbeddedLinux } from './EmbeddedLinux';
import { readBounded, writeBytes } from './FileBytes';
import { LinuxSerial } from './LinuxSerial';

export const LINUX_EXCHANGE_HALF: number = 2 * 1024 * 1024;
const ASSETS: string[] = ['kernel', 'root-console.qcow2'];

export interface LinuxJobResult { buffer: ArrayBuffer; diagnostics: string; }

class LinuxRuntime {
  private phoneVm: EmbeddedLinux = new EmbeddedLinux();
  private busy: boolean = false;

  get available(): boolean { return typeof native.startLinux === 'function'; }
  private get separateProcess(): boolean { return deviceInfo.deviceType === 'tablet' || deviceInfo.deviceType === '2in1'; }

  async exclusive<T>(operation: () => Promise<T>): Promise<T> {
    if (this.busy) { throw new ToolFailure('BUSY', 'A Linux guest is already running.', 'wait_then_check'); }
    this.busy = true;
    try { return await operation(); }
    finally { this.busy = false; }
  }

  private async withGuest<T>(context: common.Context, packet: ArrayBuffer, cancellation: Cancellation,
    operation: (dir: string, id: string) => Promise<T>): Promise<T> {
    const id = util.generateRandomUUID();
    const separate = this.separateProcess;
    const dir = context.cacheDir + (separate ? '/linux-' + id : '/tinybot-linux-console');
    let created = false;
    try {
      if (separate || !this.phoneVm.initialized) {
        cancellation.check();
        if (!separate && await fs.access(dir)) { await fs.rmdir(dir); }
        await fs.mkdir(dir);
        created = true;
        await writeBytes(dir + '/exchange', packet);
        for (const name of ASSETS) {
          cancellation.check();
          const bytes = await context.resourceManager.getRawFileContent('linux/' + name);
          await writeBytes(dir + '/' + name, bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.length));
        }
      }
      cancellation.check();
      return await operation(dir, id);
    } finally {
      // The embedded engine needs its serial socket pathname again on the next boot.
      if (created && (separate || !this.phoneVm.initialized)) { await fs.rmdir(dir); }
    }
  }

  async runJob(context: common.Context, packet: ArrayBuffer, cancellation: Cancellation): Promise<LinuxJobResult> {
    return this.withGuest<LinuxJobResult>(context, packet, cancellation, async (dir, id) => {
      if (!this.separateProcess) {
        const buffer = await this.phoneVm.run(dir, packet, cancellation);
        return { buffer: buffer, diagnostics: '' };
      }
      const pending = native.startLinux(id, dir);
      const unsubscribe = cancellation.onCancel(() => { native.cancelLinux(id); });
      let diagnostics = '';
      try { diagnostics = await pending; } finally { unsubscribe(); cancellation.check(); }
      const handle = await fs.open(dir + '/exchange', fs.OpenMode.READ_ONLY);
      try { return { buffer: await readBounded(handle.fd, packet.byteLength), diagnostics: diagnostics }; }
      finally { await fs.close(handle); }
    });
  }

  async runConsole(context: common.Context, serial: LinuxSerial, cancellation: Cancellation): Promise<void> {
    if (!this.available) { throw new ToolFailure('TOOL_UNAVAILABLE', 'This build has no Linux runtime.', 'check_available_tools'); }
    const bytes = new Uint8Array(2 * LINUX_EXCHANGE_HALF);
    bytes.set([84, 66, 67, 49]); // TBC1 selects the interactive guest.
    await this.exclusive<void>(() => this.withGuest<void>(context, bytes.buffer as ArrayBuffer, cancellation, async (dir, id) => {
      try {
        if (this.separateProcess) { await this.runConsoleChild(dir, id, serial, cancellation); }
        else { await this.phoneVm.console(dir, bytes.buffer as ArrayBuffer, cancellation, () => serial.connect(dir + '/tty', cancellation)); }
      } finally { await serial.close(); }
    }));
  }

  private async runConsoleChild(dir: string, id: string, serial: LinuxSerial, cancellation: Cancellation): Promise<void> {
    let exited = false;
    let failure: Error | undefined;
    const pending = native.startLinuxConsole(id, dir).then((_diagnostics: string) => { exited = true; }, (error: Error) => {
      failure = error;
      exited = true;
    });
    const unsubscribe = cancellation.onCancel(() => { native.cancelLinux(id); });
    try {
      try { await serial.connect(dir + '/tty', cancellation, () => exited); }
      catch (error) { throw failure ?? error as Error; }
      await pending;
      cancellation.check();
      if (failure) { throw failure; }
    } finally {
      unsubscribe();
      if (!exited) { native.cancelLinux(id); }
      await pending;
    }
  }
}

export const linuxRuntime: LinuxRuntime = new LinuxRuntime();
