import { abilityDelegatorRegistry } from '@kit.TestKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { describe, it, expect } from '@ohos/hypium';
import { LinuxTools } from '../../../main/ets/services/LinuxTools';
import { LinuxJob, linuxRuntime } from '../../../main/ets/services/LinuxRuntime';
import { LinuxSerialEvents } from '../../../main/ets/services/LinuxSerial';
import { LinuxWorkspace, LinuxWorkspaceScope } from '../../../main/ets/services/LinuxWorkspace';
import { Cancellation, RunCancelledError } from '../../../main/ets/services/Cancellation';
import { NativeWorkspaceFiles } from '../../../main/ets/services/NativeWorkspaceFiles';
import { ToolResultError } from '../../../main/ets/model/ToolFailure';
import { WorkspaceStore } from '../../../main/ets/model/WorkspaceStore';

interface Result { exitCode: number; stdout: string; stderr: string; }
interface Args { session?: string; language: string; source: string; inputPath?: string; outputPath?: string; }

export default function testsuite() {
  describe('LinuxRuntime', () => {
    it('runsOfflineJobsAndCancelsTheGuest', 0, async () => {
      expect(linuxRuntime.available).assertTrue();
      const runner = abilityDelegatorRegistry.getAbilityDelegator();
      const context = runner.getAppContext().createModuleContext('entry_test');
      linuxRuntime.initialize(context);
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

    it('sharesTheGuestAndPreservesTheInteractiveShell', 0, async () => {
      const context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext().createModuleContext('entry_test');
      linuxRuntime.initialize(context);
      const stop = new Cancellation();
      let ready = false;
      let ended = false;
      let output = '';
      let failure: Error | undefined;
      const events: LinuxSerialEvents = { ready: () => { ready = true; }, output: (bytes, history) => {
        const chunk = new util.TextDecoder('utf-8').decodeToString(bytes);
        output += chunk;
        if (!history && chunk.includes('\x1b[6n')) {
          linuxRuntime.input('\x1b[12;7R').catch((error: Error) => { failure = error; stop.cancel(); });
        }
      }, failed: (error) => { failure = error; stop.cancel(); } };
      const pending = linuxRuntime.runConsole(context, events, stop).catch((error: Error) => { failure = error; })
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
        await linuxRuntime.resize(113, 37);
        await linuxRuntime.input('export TB_TEST=shared; cd /tmp\rprintf "cwd-%s\\n" "$PWD"\rstty size\r');
        await waitFor(() => output.includes('cwd-/tmp') && output.includes('37 113'));
        await linuxRuntime.input('sleep 120\r');
        await waitFor(() => output.includes('sleep 120'));
        await new Promise<void>((resolve) => setTimeout(resolve, 400));
        await linuxRuntime.input('\x03');
        await linuxRuntime.input('printf "caught-%s\\n" interrupt\r');
        await waitFor(() => output.includes('caught-interrupt'));
        const job: LinuxJob = { language: 'shell', source:
          'test "$(id -u):$(id -g):$(id -un)" = 0:0:root && test "$TB_TEST:$PWD" = shared:/tmp && ' +
          'export TB_FROM_CHAT=ok && cat /proc/sys/kernel/random/boot_id' };
        const receipt = await linuxRuntime.runTool(context, job, new NativeWorkspaceFiles(context.cacheDir), new Cancellation());
        const bootId = receipt.stdout.trim();
        expect(bootId.length).assertEqual(36);
        await linuxRuntime.input('cat /proc/sys/kernel/random/boot_id\r');
        await waitFor(() => output.includes(bootId));
        stop.cancel();
        await waitFor(() => ended);
        const again = new Cancellation();
        ready = false;
        output = '';
        const reattached = linuxRuntime.runConsole(context, events, again);
        try {
          await waitFor(() => ready && output.includes(bootId));
          await linuxRuntime.input('printf "still-%s\\n" "$TB_FROM_CHAT:$PWD"\r');
          await waitFor(() => output.includes('still-ok:/tmp'));
        } finally { again.cancel(); await reattached; }
      } finally { stop.cancel(); await pending; }
    });

    it('restoresOnlySuccessfulProjectJobs', 0, async () => {
      const runner = abilityDelegatorRegistry.getAbilityDelegator();
      const context = runner.getAppContext().createModuleContext('entry_test');
      linuxRuntime.initialize(context);
      const scope: LinuxWorkspaceScope = { id: 'linux-test-' + util.generateRandomUUID(), project: true };
      const workspaces = new WorkspaceStore(context.getApplicationContext().filesDir);
      await workspaces.ensureThread(scope.id);
      const path = workspaces.pathFor(scope.id);
      const workspace = new LinuxWorkspace(context, scope);
      const tools = new LinuxTools(context, new NativeWorkspaceFiles(path), scope);
      const run = async (source: string): Promise<Result> => {
        const args: Args = { language: 'shell', source: source, session: 'workspace' };
        const text = await tools.execute({ id: 'project-test', type: 'function', function: {
          name: 'run_linux', arguments: JSON.stringify(args) } }, new Cancellation());
        return JSON.parse(text) as Result;
      };
      try {
        await linuxRuntime.editWorkspace(() => workspace.setPersistent(true));
        await run('set -e\ncd "$TINYBOT_PROJECT_DIR"\nmkdir nested\nprintf kept > nested/value\n' +
          'dd if=/dev/zero of=nested/large bs=1048576 count=5 2>/dev/null\n' +
          'i=0; while [ "$i" -lt 300 ]; do : > "nested/entry-$i"; i=$((i + 1)); done');
        let failed = false;
        try { await run('printf discarded > "$TINYBOT_PROJECT_DIR/nested/value"; exit 2'); }
        catch (error) { if (!(error instanceof ToolResultError)) { throw error as Error; } failed = true; }
        expect(failed).assertTrue();
        const restored = await run('cd "$TINYBOT_PROJECT_DIR/nested" && cat value && printf "\\n" && ' +
          'wc -c < large && find . -name "entry-*" | wc -l');
        expect(restored.stdout.trim().split(/\s+/).join(' ')).assertEqual('kept 5242880 300');
        await linuxRuntime.editWorkspace(() => workspace.clearProject());
        expect((await workspace.info()).storedBytes).assertEqual(0);
      } finally { await fs.rmdir(path); }
    });
  });
}
