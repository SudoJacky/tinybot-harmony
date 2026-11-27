import { abilityDelegatorRegistry } from '@kit.TestKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { describe, it, expect } from '@ohos/hypium';
import { LinuxTools } from '../../../main/ets/services/LinuxTools';
import { linuxRuntime } from '../../../main/ets/services/LinuxRuntime';
import { LinuxWorkspace, LinuxWorkspaceScope } from '../../../main/ets/services/LinuxWorkspace';
import { Cancellation, RunCancelledError } from '../../../main/ets/services/Cancellation';
import { NativeWorkspaceFiles } from '../../../main/ets/services/NativeWorkspaceFiles';
import { ToolResultError } from '../../../main/ets/model/ToolFailure';
import { WorkspaceStore } from '../../../main/ets/model/WorkspaceStore';

interface Result { exitCode: number; stdout: string; stderr: string; }
interface Args { language: string; source: string; inputPath?: string; outputPath?: string; }

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

    it('restoresOnlySuccessfulProjectJobs', 0, async () => {
      const runner = abilityDelegatorRegistry.getAbilityDelegator();
      const context = runner.getAppContext().createModuleContext('entry_test');
      linuxRuntime.initialize(context);
      const scope: LinuxWorkspaceScope = { id: 'linux-test-' + util.generateRandomUUID(), project: true };
      const workspaces = new WorkspaceStore(context.filesDir);
      await workspaces.ensureThread(scope.id);
      const path = workspaces.pathFor(scope.id);
      const workspace = new LinuxWorkspace(context, scope);
      const tools = new LinuxTools(context, new NativeWorkspaceFiles(path), scope);
      const run = async (source: string): Promise<Result> => {
        const args: Args = { language: 'shell', source: source };
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
