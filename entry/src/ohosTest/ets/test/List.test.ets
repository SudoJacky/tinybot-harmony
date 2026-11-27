import { abilityDelegatorRegistry } from '@kit.TestKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { describe, it, expect } from '@ohos/hypium';
import { LinuxTools } from '../../../main/ets/services/LinuxTools';
import { linuxRuntime } from '../../../main/ets/services/LinuxRuntime';
import { LinuxSerial } from '../../../main/ets/services/LinuxSerial';
import { Cancellation, RunCancelledError } from '../../../main/ets/services/Cancellation';
import { NativeWorkspaceFiles } from '../../../main/ets/services/NativeWorkspaceFiles';
import { ToolResultError } from '../../../main/ets/model/ToolFailure';

interface Result { exitCode: number; stdout: string; stderr: string; }
interface Args { language: string; source: string; inputPath?: string; outputPath?: string; }

export default function testsuite() {
  describe('LinuxRuntime', () => {
    it('runsOfflineJobsAndCancelsTheGuest', 0, async () => {
      expect(LinuxTools.available()).assertTrue();
      const runner = abilityDelegatorRegistry.getAbilityDelegator();
      const context = runner.getAppContext().createModuleContext('entry_test');
      const dir = context.cacheDir + '/test-' + util.generateRandomUUID();
      await fs.mkdir(dir);
      const files = new NativeWorkspaceFiles(dir), tools = new LinuxTools(context, files);
      const run = async (args: Args, signal: Cancellation = new Cancellation()): Promise<Result> => {
        const text = await tools.execute({ id: 'test', type: 'function', function: {
          name: 'run_linux', arguments: JSON.stringify(args) } }, signal);
        return JSON.parse(text) as Result;
      };
      try {
        const start = Date.now();
        let failure: Result | undefined;
        try { await run({ language: 'python', source: 'raise AssertionError("red test")' }); }
        catch (error) {
          if (!(error instanceof ToolResultError)) { throw error as Error; }
          failure = JSON.parse((error as ToolResultError).output) as Result;
        }
        expect(failure?.exitCode).assertEqual(1);
        expect(failure?.stderr.includes('AssertionError: red test')).assertTrue();
        const coldMs = Date.now() - start;
        await runner.print('Cold Python error and stderr: ' + coldMs + ' ms\n');
        const createStart = Date.now();
        const fixture = await run({ language: 'python', source:
          'import sqlite3\nc=sqlite3.connect("output")\nc.execute("CREATE TABLE items(n INT)")\nc.executemany("INSERT INTO items VALUES (?)", [(3,), (4,)])\nc.commit()', outputPath: 'items.db' });
        expect(fixture.exitCode).assertEqual(0);
        await runner.print('Python created items.db: ' + (Date.now() - createStart) + ' ms\n');
        const cancel = new Cancellation();
        const pending = run({ language: 'shell', source: 'sleep 100 & wait' }, cancel);
        const timer = setTimeout(() => { cancel.cancel(); }, Math.min(coldMs + 3000, 60000));
        let stopped = false;
        try { await pending; } catch (error) {
          if (!(error instanceof RunCancelledError)) { throw error as Error; } stopped = true;
        } finally { clearTimeout(timer); }
        expect(stopped).assertTrue();
        const exportStart = Date.now();
        const result = await run({ language: 'shell', inputPath: 'items.db', outputPath: 'summary.csv',
          source: 'sqlite3 -header -csv input "select sum(n) as total from items" > output\nprintf done' });
        expect(result.stdout).assertEqual('done');
        expect((await files.read('summary.csv', new Cancellation())).content.trim()).assertEqual('total\n7');
        await runner.print('After cancellation, SQLite exported total=7: ' + (Date.now() - exportStart) + ' ms\n');
      } finally { await fs.rmdir(dir); }
    });

    it('keepsAnInteractiveShellUntilExit', 0, async () => {
      const context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext().createModuleContext('entry_test');
      const stop = new Cancellation();
      let ready = false;
      let ended = false;
      let output = '';
      let failure: Error | undefined;
      const serial = new LinuxSerial({ ready: () => { ready = true; }, output: (bytes) => {
        output += new util.TextDecoder('utf-8').decodeToString(bytes);
      }, failed: (error) => { failure = error; stop.cancel(); } });
      const pending = linuxRuntime.runConsole(context, serial, stop).catch((error: Error) => { failure = error; })
        .finally(() => { ended = true; });
      const waitFor = async (condition: () => boolean): Promise<void> => {
        const deadline = Date.now() + 45000;
        while (!condition()) {
          if (failure) { throw failure; }
          if (Date.now() >= deadline) { throw new Error('Timed out waiting for Linux console output: ' + output.slice(-500)); }
          await new Promise<void>((resolve) => setTimeout(resolve, 30));
        }
      };
      try {
        await waitFor(() => ready);
        await serial.resize(113, 37);
        await serial.input('cd /tmp\rprintf "cwd-%s\\n" "$PWD"\rstty size\r');
        await waitFor(() => output.includes('cwd-/tmp') && output.includes('37 113'));
        await serial.input('sleep 120\r');
        await waitFor(() => output.includes('sleep 120'));
        await new Promise<void>((resolve) => setTimeout(resolve, 400));
        await serial.input('\x03');
        await serial.input('printf "caught-%s\\n" interrupt\r');
        await waitFor(() => output.includes('caught-interrupt'));
        expect(await linuxRuntime.exclusive(async () => true).catch(() => false)).assertFalse();
        await serial.input('exit\r');
        await waitFor(() => ended);
        await pending;
        if (failure) { throw failure; }
        expect(await linuxRuntime.exclusive(async () => true)).assertTrue();
      } finally { stop.cancel(); await pending; }
    });
  });
}
