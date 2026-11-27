const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets');
const sockets = [];

class LocalSocket {
  constructor() { this.handlers = new Map(); this.sent = []; sockets.push(this); }
  on(name, handler) { this.handlers.set(name, handler); }
  async connect() {}
  async close() { this.closed = true; this.handlers.get('close')(); }
  async send({ data }) { this.sent.push(Buffer.from(data)); }
  emit(bytes) { this.handlers.get('message')({ message: Uint8Array.from(bytes).buffer }); }
}

const platform = {
  '@kit.ArkTS': { util: { TextEncoder: class { encodeInto(value) { return new TextEncoder().encode(value); } } } },
  '@kit.NetworkKit': { socket: { constructLocalSocketInstance: () => new LocalSocket() } },
  '@kit.CoreFileKit': { fileIo: { access: async name => name.endsWith('/tty') } }
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
    if (!id.startsWith('.')) throw new Error('Unexpected dependency ' + id);
    return load(path.resolve(path.dirname(file), id));
  } }, { filename: file + '.ets' });
  return exports;
}

async function main() {
  const { LinuxSerial } = load(path.join(root, 'services/LinuxSerial'));
  const { Cancellation } = load(path.join(root, 'services/Cancellation'));
  const events = [], output = [];
  const observer = { ready: () => events.push('ready'), output: bytes => output.push(Buffer.from(bytes)),
    failed: error => events.push(error.message) };
  const stream = new LinuxSerial(observer);
  await stream.connect('/cache/tty', new Cancellation());
  const tty = sockets.at(-1);
  await stream.input('ignored before handshake');
  assert.equal(tty.sent.length, 0);
  tty.emit([84, 66]);
  tty.emit([67, 50, 1, 3]);
  tty.emit([0, 0xe7, 0x8c, 0xab]);
  assert.deepEqual(events, ['ready']);
  assert.equal(Buffer.concat(output).toString(), '猫');
  await stream.resize(120, 36);
  await stream.input('\x03猫');
  assert.deepEqual([...tty.sent[0]], [2, 4, 0, 120, 0, 36, 0]);
  assert.deepEqual([...tty.sent[1]], [1, 4, 0, 3, 0xe7, 0x8c, 0xab]);
  await stream.input('x'.repeat(16385));
  assert.deepEqual(tty.sent.slice(-2).map(frame => frame.readUInt16LE(1)), [16384, 1]);
  await assert.rejects(stream.input('x'.repeat(140000)), /input queue is full/);
  await stream.input('still connected');
  assert.equal(tty.sent.at(-1).subarray(3).toString(), 'still connected');
  const job = stream.runJob(new Cancellation(), 30, true);
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual([...tty.sent.at(-1)], [5, 1, 0, 0]);
  tty.emit([3, 1, 0, 0]);
  await job;
  const busy = stream.runJob(new Cancellation(), 30, true);
  await new Promise(resolve => setImmediate(resolve));
  tty.emit([3, 1, 0, 2]);
  await assert.rejects(busy, { code: 'BUSY', message: /unfinished input/ });
  const stop = new Cancellation();
  const interrupted = stream.runJob(stop, 30, false);
  stop.cancel();
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual([...tty.sent.at(-1)], [4, 1, 0, 0]);
  tty.emit([3, 1, 0, 1]);
  await assert.rejects(interrupted, { code: 'CANCELLED' });
  await stream.close();

  const broken = new LinuxSerial(observer);
  await broken.connect('/cache/tty', new Cancellation());
  sockets.at(-1).emit([0, 84, 66, 67, 49]);
  assert.match(events.at(-1), /Invalid Linux console startup response/);
  await broken.close();

  testScreenCopy();
  console.log('PASS Linux console serial handshake, UTF-8, resize, input framing and viewport copy');
}

function testScreenCopy() {
  const rows = [
    ['off screen', false], ['wide  ', false], ['猫   ', true], ['  ', false], ['after viewport', false]
  ];
  const host = { consoleCopy: (...args) => copies.push(args) };
  const copies = [];
  let selected = '', native = null;
  const surface = { contains: node => node === surface };
  class Terminal {
    constructor() {
      this.parser = { registerOscHandler() {}, registerCsiHandler() {} };
      this.rows = 3;
      this.buffer = { active: { viewportY: 1, length: rows.length, getLine: index => ({
        isWrapped: rows[index][1], translateToString: trim => trim ? rows[index][0].trimEnd() : rows[index][0]
      }) } };
    }
    loadAddon() {} open() {} onScroll() {} onData() {}
    getSelection() { return selected; }
  }
  const window = { Terminal, FitAddon: { FitAddon: class {} }, addEventListener() {},
    tinybotConsoleHost: host, getSelection: () => native };
  const document = { getElementById: id => id === 'terminal' ? surface : { addEventListener() {} } };
  vm.runInNewContext(fs.readFileSync(path.join(root, '../resources/rawfile/linux-console/console.js'), 'utf8'), { window, document });
  window.tinybotTerminal.copy();
  native = { anchorNode: surface, toString: () => 'touch selection' };
  window.tinybotTerminal.copy();
  selected = 'xterm selection';
  window.tinybotTerminal.copy();
  assert.deepEqual(copies, [['wide  猫', true], ['touch selection', false], ['xterm selection', false]]);
}

main().catch(error => { console.error(error); process.exitCode = 1; });
