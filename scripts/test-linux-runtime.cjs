const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets');
const jobs = [];
const logged = [];
const directories = new Set();
const files = new Map();
const grants = new Set();
const requests = [];
const deviceInfo = { deviceType: 'phone' };
const boots = [];
let serialEvents;
const power = [];
const MIB = 1024 * 1024;
const TREE_OFFSET = 4 * MIB;
const LARGE_FILE = Buffer.alloc(5 * MIB + 42, 0x65);
let saved;
let failFlush = false;
let nativeStarted;
let packingStarted;
let finishPacking;
let nextId = 0;

const store = {
  getSync: (_key, fallback) => saved ?? fallback,
  putSync: (_key, value) => { saved = value; },
  async flush() { if (failFlush) throw new Error('Preferences flush failed'); }
};

function record(name, data) {
  const encoded = Buffer.from(name);
  const header = Buffer.alloc(13);
  header.writeUInt32LE(encoded.length);
  header.writeUInt8(data === undefined ? 0 : 1, 4);
  header.writeBigUInt64LE(BigInt(data?.length ?? 0), 5);
  return Buffer.concat(data === undefined ? [header, encoded] : [header, encoded, data]);
}

function inspectTree(disk, offset, length) {
  const files = [];
  const end = offset + length;
  while (offset < end) {
    const nameSize = disk.readUInt32LE(offset);
    const dataSize = Number(disk.readBigUInt64LE(offset + 5));
    const name = disk.toString('utf8', offset + 13, offset + 13 + nameSize);
    files.push({ name, dataSize });
    offset += 13 + nameSize + dataSize;
  }
  assert.equal(offset, end);
  return files;
}

function executeGuest(disk) {
  assert.equal(disk.toString('ascii', 0, 4), 'TBJ3');
  const request = JSON.parse(disk.toString('utf8', 8, 8 + disk.readUInt32LE(4)));
  const project = request.projectBytes === undefined ? undefined : inspectTree(disk, TREE_OFFSET, request.projectBytes);
  const mounts = request.mountBytes === undefined ? undefined :
    inspectTree(disk, TREE_OFFSET + (request.projectBytes ?? 0), request.mountBytes);
  requests.push({ ...request, project, mounts });
  const failed = request.source === 'fail';
  const result = { exitCode: failed ? 1 : 0, stdout: 'ok\n', stderr: '', truncated: false };
  if (request.collect && !failed) result.artifact = Buffer.from('exported').toString('base64');
  if (project !== undefined) {
    const state = failed || request.source === 'new-value' ? record('discarded', Buffer.from('bad')) :
      Buffer.concat([record('nested'), record('nested/result', LARGE_FILE)]);
    state.copy(disk, TREE_OFFSET);
    result.projectBytes = state.length;
  }
  const response = Buffer.from(JSON.stringify(result));
  disk.write('TBR3', 2 * MIB);
  disk.writeUInt32LE(response.length, 2 * MIB + 4);
  response.copy(disk, 2 * MIB + 8);
}

function info(file) {
  return { size: files.get(file)?.length ?? 0, isFile: () => files.has(file), isDirectory: () => directories.has(file),
    isSymbolicLink: () => false };
}

const native = {
  linuxMemoryLimit: () => 2048,
  linuxStorageBytes: () => 24 * MIB,
  startEmbeddedLinux(dir, memoryMiB) { boots.push({ mode: 'phone', memoryMiB, dir }); },
  startLinuxChild(id, dir, memoryMiB) {
    boots.push({ mode: 'tablet', memoryMiB, dir });
    return new Promise(() => {});
  },
  async packLinuxDirectory(dir, name, fd, offset) {
    assert.equal(dir, '/' + name);
    if (packingStarted) {
      const notify = packingStarted;
      packingStarted = undefined;
      return new Promise(resolve => { finishPacking = resolve; notify(); });
    }
    const records = [record(name)];
    if (name === 'outside') {
      records.push(record(name + '/large.bin', LARGE_FILE));
      for (let index = 0; index < 300; index++) { records.push(record(name + '/file-' + index, Buffer.from('x'))); }
    }
    const archive = Buffer.concat(records);
    assert.equal(archive.copy(files.get(fd), offset), archive.length);
    return archive.length;
  },
  cancelLinuxDirectory() { finishPacking(0); }
};

const platform = {
  '@kit.ArkData': { preferences: { getPreferencesSync: () => store } },
  '@kit.ArkTS': { util: {
    generateRandomUUID: () => 'test-' + nextId++,
    Base64Helper: class {
      encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); }
      decodeSync(value) { return Uint8Array.from(Buffer.from(value, 'base64')); }
    },
    TextEncoder: class { encodeInto(value) { return new TextEncoder().encode(value); } },
    TextDecoder: { create: () => ({ decodeToString: value => new TextDecoder().decode(value) }) }
  } },
  '@kit.BasicServicesKit': { deviceInfo },
  '@kit.CoreFileKit': {
    fileIo: {
      OpenMode: { READ_ONLY: 0, WRITE_ONLY: 1, READ_WRITE: 2, CREATE: 64, TRUNC: 512, NOFOLLOW: 0, NONBLOCK: 0 },
      async open(file, mode) {
        if (mode & 64) files.set(file, Buffer.alloc(0));
        assert.ok(files.has(file), file);
        return { fd: file };
      },
      close: async () => {},
      fsync: async () => {},
      access: async file => files.has(file) || directories.has(file),
      lstat: async file => info(file),
      stat: async file => info(file),
      truncate: async (file, size) => files.set(file, Buffer.alloc(size)),
      async write(file, buffer, { offset }) {
        const old = files.get(file);
        if (old.length < offset + buffer.byteLength) {
          const expanded = Buffer.alloc(offset + buffer.byteLength);
          old.copy(expanded);
          files.set(file, expanded);
        }
        return Buffer.from(buffer).copy(files.get(file), offset);
      },
      read: async (file, buffer, { offset }) => files.get(file).copy(Buffer.from(buffer), 0, offset, offset + buffer.byteLength),
      async mkdir(dir) { assert.ok(!directories.has(dir)); directories.add(dir); },
      async rmdir(dir) {
        assert.ok(directories.delete(dir));
        for (const file of files.keys()) if (file.startsWith(dir + '/')) files.delete(file);
      },
      async rename(from, to) { files.set(to, files.get(from)); assert.ok(files.delete(from)); },
      async unlink(file) { assert.ok(files.delete(file)); }
    },
    fileShare: {
      OperationMode: { READ_MODE: 1 },
      checkPersistentPermission: async policies => policies.map(({ uri }) => grants.has(uri)),
      async persistPermission(policies) { for (const policy of policies) { assert.equal(policy.operationMode, 1); grants.add(policy.uri); } },
      async activatePermission(policies) { for (const { uri } of policies) assert.ok(grants.has(uri)); }
    },
    fileUri: { FileUri: class { constructor(uri) { this.path = new URL(uri).pathname; } } }
  },
  'libtinybot_sandbox.so': { default: native },
  '../model/Diagnostics': { Diagnostics: { log: (...event) => logged.push(event) } },
  './LinuxControl': { LinuxControl: class {
    async connect(dir) { assert.ok(files.has(dir + '/exchange')); }
    async setRunning(running) { power.push(running); if (running) serialEvents.ready(); }
  } },
  './LinuxSerial': { LinuxSerial: class {
    constructor(events) { this.events = events; }
    async connect(path) { this.dir = path.slice(0, -4); serialEvents = this.events; }
    async close() {}
    async runJob(signal, seconds, shared) {
      jobs.push({ seconds, shared });
      if (nativeStarted) {
        const notify = nativeStarted;
        nativeStarted = undefined;
        await new Promise(resolve => { signal.onCancel(resolve); notify(); });
        signal.check();
      }
      executeGuest(files.get(this.dir + '/exchange'));
    }
  } },
  './FileBytes': {
    async readBounded(file, limit) { assert.ok(files.get(file).length <= limit); return Uint8Array.from(files.get(file)).buffer; },
    async writeBytes(file, bytes) { files.set(file, Buffer.from(bytes)); }
  },
  './ProjectFolderAccess': { ProjectFolderAccess: { supported: () => true } },
  './WorkspaceTools': { workspaceRelativePath: value => value }
};

const modules = new Map();
function load(file) {
  if (modules.has(file)) return modules.get(file);
  const exports = {};
  modules.set(file, exports);
  const { outputText } = ts.transpileModule(fs.readFileSync(file + '.ets', 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
  });
  vm.runInNewContext(outputText, { exports, setTimeout, clearTimeout, require: id => {
    if (Object.hasOwn(platform, id)) return platform[id];
    if (!id.startsWith('.')) throw new Error('Unexpected platform dependency ' + id);
    return load(path.resolve(path.dirname(file), id));
  } }, { filename: file + '.ets' });
  return exports;
}

async function main() {
  const runtimeModule = path.join(root, 'services/LinuxRuntime');
  const { linuxRuntime } = load(runtimeModule);
  const { LinuxTools } = load(path.join(root, 'services/LinuxTools'));
  const { LinuxWorkspace } = load(path.join(root, 'services/LinuxWorkspace'));
  const { ToolSet } = load(path.join(root, 'services/ToolSet'));
  const { RuleTools } = load(path.join(root, 'services/RuleTools'));
  const { Cancellation, RunCancelledError } = load(path.join(root, 'services/Cancellation'));
  const { findSettings } = load(path.join(root, 'model/SettingsSearch'));
  const loading = [];
  const context = { cacheDir: '/cache', filesDir: '/entry/files', getApplicationContext: () => ({ filesDir: '/files' }), resourceManager: {
    getRawFileContent: async name => { loading.push(name); return new Uint8Array(1); }
  } };
  const workspace = {
    readJobInput: async () => assert.fail('Disallowed file was read'),
    createJobOutput: async () => assert.fail('Disallowed file was created')
  };
  const tools = new LinuxTools(context, workspace);
  const outputs = new Map();
  const exchangeTools = new LinuxTools(context, {
    readJobInput: async () => Uint8Array.from(Buffer.from('imported')),
    async createJobOutput(target, data) { outputs.set(target, Buffer.from(data).toString()); }
  });
  const catalog = new ToolSet([tools]);
  const readOnly = new RuleTools(catalog, true);
  const call = args => ({ id: 'call', type: 'function', function: { name: 'run_linux',
    arguments: JSON.stringify({ language: 'shell', source: 'true', ...args }) } });
  const properties = () => Object.keys(catalog.definitions()[0].function.parameters.properties);

  assert.equal(catalog.definitions().length, 0);
  saved = JSON.stringify({ enabled: true, allowInput: true, allowOutput: true, timeoutSeconds: 120 });
  linuxRuntime.initialize(context);
  assert.equal(linuxRuntime.snapshot().settings.memoryMiB, 192);
  await linuxRuntime.prewarmOnStartup(context);
  assert.equal(jobs.length, 0);
  assert.deepEqual(properties(), ['language', 'source', 'session', 'inputPath', 'outputPath']);
  assert.equal(readOnly.definitions().length, 0);
  await assert.rejects(readOnly.execute(call({}), new Cancellation()), { code: 'PERMISSION_DENIED' });
  assert.equal(findSettings('Linux Runtime', [], false)[0].route, 'sandbox-management');
  assert.equal(findSettings('沙盒管理', [], false)[0].route, 'sandbox-management');

  const settings = { enabled: true, allowInput: false, allowOutput: false, timeoutSeconds: 30, startup: 'on-demand', memoryMiB: 256 };
  await linuxRuntime.save(settings);
  assert.deepEqual(JSON.parse(saved), settings);
  assert.deepEqual(properties(), ['language', 'source', 'session']);
  await assert.rejects(catalog.execute(call({ inputPath: 'input' }), new Cancellation()), { code: 'PERMISSION_DENIED' });
  await assert.rejects(catalog.execute(call({ outputPath: 'output' }), new Cancellation()), { code: 'PERMISSION_DENIED' });
  assert.equal(jobs.length, 0);

  failFlush = true;
  await assert.rejects(linuxRuntime.save({ ...settings, enabled: false }), /flush failed/);
  failFlush = false;
  assert.deepEqual(JSON.parse(saved), settings);
  assert.equal(linuxRuntime.snapshot().settings.enabled, true);
  assert.equal(logged.at(-1)[2], 'settings_save_failed');

  await Promise.all([linuxRuntime.warmUp(context), linuxRuntime.warmUp(context),
    catalog.execute(call({}), new Cancellation())]);
  assert.equal(boots.length, 1);
  assert.equal(requests.length, 1);
  assert.equal(jobs.at(-1).shared, true);
  assert.equal(boots[0].memoryMiB, 256);
  assert.equal(linuxRuntime.snapshot().history[0].kind, 'tool');
  assert.equal(linuxRuntime.snapshot().history[1].kind, 'warm-up');
  await linuxRuntime.save({ timeoutSeconds: 60 });
  await catalog.execute(call({}), new Cancellation());
  assert.equal(jobs.at(-1).seconds, 60);
  const customMemory = 768;
  await linuxRuntime.save({ memoryMiB: customMemory });
  for (const bad of [191, 192.25, 2049]) {
    await assert.rejects(linuxRuntime.save({ memoryMiB: bad }), /192.*2048/);
  }
  await linuxRuntime.warmUp(context);
  assert.equal(linuxRuntime.snapshot().memoryInUse, 256);
  assert.equal(boots.length, 1);
  assert.deepEqual(loading, ['linux/kernel', 'linux/root-v5-shell.qcow2']);

  const started = new Promise(resolve => { nativeStarted = resolve; });
  const parent = new Cancellation();
  const pending = catalog.execute(call({}), parent);
  await started;
  assert.equal(linuxRuntime.snapshot().active, 'tool');
  await assert.rejects(catalog.execute(call({}), new Cancellation()), { code: 'BUSY' });
  await assert.rejects(linuxRuntime.save(settings), /current sandbox operation|当前沙盒操作/);
  linuxRuntime.stop();
  assert.equal(linuxRuntime.snapshot().stopping, true);
  await assert.rejects(pending, RunCancelledError);
  assert.equal(parent.cancelled, false);
  assert.equal(linuxRuntime.snapshot().history[0].outcome, 'cancelled');
  assert.equal(linuxRuntime.snapshot().active, undefined);
  assert.equal(Array.from(directories).filter(dir => dir.startsWith('/cache/linux-')).length, 0);

  directories.add('/files/workspace');
  directories.add('/files/workspace/project-1');
  const scope = { id: 'project-1', project: true };
  const scoped = new LinuxWorkspace(context, scope);
  const projectTools = new LinuxTools(context, workspace, scope);
  const projectRun = source => projectTools.execute(call({ source, session: 'workspace' }), new Cancellation());
  await linuxRuntime.editWorkspace(() => scoped.setPersistent(true));
  await linuxRuntime.editWorkspace(() => scoped.addMount('file:///outside'));
  for (let index = 0; index < 9; index++) {
    await linuxRuntime.editWorkspace(() => scoped.addMount('file:///folder-' + index));
  }
  assert.equal((await scoped.info()).mounts.length, 10);
  const legacyPath = '/files/workspace/project-1/.tinybot-linux-project.json';
  files.set(legacyPath, Buffer.from(JSON.stringify([{ path: 'legacy.txt', data: 'b2xk' }])));
  await projectRun('true');
  assert.equal(requests.at(-1).project, undefined, 'transfer switch suppresses persistent files');
  assert.equal(requests.at(-1).mounts, undefined, 'transfer switch suppresses mount reads');
  await linuxRuntime.save({ allowInput: true, allowOutput: true });
  await exchangeTools.execute(call({ inputPath: 'in', outputPath: 'out' }), new Cancellation());
  assert.equal(Buffer.from(requests.at(-1).input, 'base64').toString(), 'imported');
  assert.equal(outputs.get('out'), 'exported');
  assert.equal(jobs.at(-1).shared, false);
  const packing = new Promise(resolve => { packingStarted = resolve; });
  const snapshotPending = projectRun('true');
  await packing;
  linuxRuntime.stop();
  await assert.rejects(snapshotPending, RunCancelledError);
  await projectRun('true');
  assert.deepEqual(requests.at(-1).project, [{ name: 'legacy.txt', dataSize: 3 }]);
  assert.equal(files.has(legacyPath), false);
  assert.equal(requests.at(-1).mounts.length, 311);
  assert.deepEqual(requests.at(-1).mounts[1], { name: 'outside/large.bin', dataSize: LARGE_FILE.length });
  assert.equal(boots.at(-1).memoryMiB, 256);
  await assert.rejects(projectRun('fail'), { code: 'EXECUTION_FAILED' });
  await assert.rejects(projectTools.execute(call({ source: 'new-value', outputPath: 'blocked' }), new Cancellation()), /Disallowed file was created/);
  await projectRun('true');
  assert.deepEqual(requests.at(-1).project, [{ name: 'nested', dataSize: 0 }, { name: 'nested/result', dataSize: LARGE_FILE.length }]);
  assert.equal((await new LinuxWorkspace(context, { id: 'other', project: true }).info()).persistent, false);
  const { mounts } = await scoped.info();
  grants.delete(mounts[0].uri);
  const runsBeforeRevoke = jobs.length;
  await assert.rejects(projectRun('true'), /expired|授权已失效/);
  assert.equal(jobs.length, runsBeforeRevoke);
  for (const mount of mounts) { await linuxRuntime.editWorkspace(() => scoped.removeMount(mount.id)); }
  await linuxRuntime.editWorkspace(() => scoped.clearProject());
  await projectRun('true');
  assert.equal(requests.at(-1).mounts, undefined);
  assert.deepEqual(requests.at(-1).project, []);

  await linuxRuntime.save({ startup: 'prewarm' });
  deviceInfo.deviceType = 'tablet';
  modules.delete(runtimeModule);
  const restored = load(runtimeModule).linuxRuntime;
  restored.initialize(context);
  assert.equal(restored.snapshot().ready, true);
  assert.deepEqual(JSON.parse(JSON.stringify(restored.snapshot().settings)), {
    ...settings, timeoutSeconds: 60, allowInput: true, allowOutput: true, startup: 'prewarm', memoryMiB: customMemory
  });
  const count = requests.length;
  const stop = new Cancellation();
  let attach;
  const attached = new Promise(resolve => { attach = resolve; });
  const output = [];
  const observer = { ready: attach, output: bytes => output.push(Buffer.from(bytes).toString()), failed: assert.fail };
  const firstView = restored.runConsole(context, observer, stop);
  await Promise.all([attached, restored.prewarmOnStartup(context), restored.prewarmOnStartup(context)]);
  assert.equal(boots.length, 2);
  assert.equal(boots.at(-1).mode, 'tablet');
  assert.equal(requests.length, count);
  serialEvents.output(Buffer.from('before'));
  stop.cancel();
  await firstView;
  serialEvents.output(Buffer.from('after'));
  const again = new Cancellation();
  let replay;
  const reconnected = new Promise(resolve => { replay = resolve; });
  const reattach = restored.runConsole(context, { ...observer, ready: replay }, again);
  await reconnected;
  assert.deepEqual(output, ['before', 'before', 'after']);
  await restored.runTool(context, { language: 'shell', source: 'true' }, workspace, new Cancellation());
  assert.equal(boots.length, 2);
  again.cancel();
  await reattach;
  await linuxRuntime.save({ enabled: false });
  assert.equal(catalog.definitions().length, 0);
  await assert.rejects(linuxRuntime.runConsole(context, {}, new Cancellation()), { code: 'TOOL_UNAVAILABLE' });
  await assert.rejects(tools.execute(call({}), new Cancellation()), { code: 'TOOL_UNAVAILABLE' });
  await assert.rejects(linuxRuntime.warmUp(context), { code: 'TOOL_UNAVAILABLE' });
  assert.equal(power.at(-1), false);
  console.log('PASS Linux streaming exchange, large directory trees, project migration and rollback, custom memory, permissions and cancellation');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
