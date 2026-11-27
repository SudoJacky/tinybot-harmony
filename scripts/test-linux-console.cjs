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
  vm.runInNewContext(outputText, { exports, setTimeout, require: id => {
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
  tty.emit([67, 49, 0xe7]);
  tty.emit([0x8c, 0xab]);
  assert.deepEqual(events, ['ready']);
  assert.equal(Buffer.concat(output).toString(), '猫');
  await stream.resize(120, 36);
  await stream.input('\x03猫');
  assert.deepEqual([...tty.sent[0]], [2, 4, 0, 120, 0, 36, 0]);
  assert.deepEqual([...tty.sent[1]], [1, 4, 0, 3, 0xe7, 0x8c, 0xab]);
  await stream.input('x'.repeat(16385));
  assert.deepEqual(tty.sent.slice(-2).map(frame => frame.readUInt16LE(1)), [16384, 1]);
  await assert.rejects(stream.input('x'.repeat(140000)), /input queue is full/);
  await stream.close();

  const broken = new LinuxSerial(observer);
  await broken.connect('/cache/tty', new Cancellation());
  sockets.at(-1).emit([0, 84, 66, 67, 49]);
  assert.match(events.at(-1), /Invalid Linux console startup response/);
  await broken.close();

  console.log('PASS Linux console serial handshake, UTF-8, resize and input framing');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
