// The actual LAN adapter and collaboration controllers, with platform crypto backed by Node AES-GCM.
// Socket fixtures deliberately deliver split frames immediately, including before connect() resolves.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const crypto = require('node:crypto');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets'), cache = new Map(), servers = new Map(), wire = [];
let nextPort = 30000, pauseListen, listeningStarted = false;
class Channel {
  handlers = new Map(); closed = false; peer;
  on(name, callback) { const handlers = this.handlers.get(name) || []; handlers.push(callback); this.handlers.set(name, handlers); }
  emit(name, info) { for (const callback of this.handlers.get(name) || []) callback(info); }
  async bind() {}
  async connect(options) {
    const server = servers.get(options.address.port); if (!server) throw new Error('Connection refused');
    const peer = new Channel(); peer.peer = this; this.peer = peer; server.emit('connect', peer);
  }
  async send({ data }) {
    if (this.closed || !this.peer || this.peer.closed) throw new Error('Closed socket');
    wire.push(data); const bytes = Buffer.from(data);
    for (let offset = 0; offset < bytes.length; offset += 97) {
      const chunk = Uint8Array.from(bytes.subarray(offset, offset + 97));
      this.peer.emit('message', { message: chunk.buffer });
    }
  }
  async close() {
    if (this.closed) return; this.closed = true;
    this.emit('close');
    if (this.peer && !this.peer.closed) { this.peer.closed = true; this.peer.emit('close'); }
  }
}
class Server extends Channel {
  async listen() { listeningStarted = true; if (pauseListen) await pauseListen; this.port = ++nextPort; servers.set(this.port, this); }
  async getLocalAddress() { return { port: this.port }; }
  async close() { servers.delete(this.port); }
}
const kits = {
  '@kit.NetworkKit': { socket: { constructTCPSocketInstance: () => new Channel(), constructTCPSocketServerInstance: () => new Server() },
    connection: { getDefaultNet: async () => ({}), getConnectionProperties: async () => ({ linkAddresses: [{ address: { address: '192.168.1.2' } }] }) } },
  '@kit.BasicServicesKit': { pasteboard: {} },
  '@kit.ArkTS': { util: { generateRandomUUID: () => crypto.randomUUID(),
    TextEncoder: class { encodeInto(value) { return new TextEncoder().encode(value); } },
    TextDecoder: class { constructor(encoding, options) { this.decoder = new TextDecoder(encoding, options); }
      decodeToString(bytes) { return this.decoder.decode(bytes); } },
    Base64Helper: class { encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); } decodeSync(text) { return Uint8Array.from(Buffer.from(text, 'base64')); } } } },
  '@kit.CryptoArchitectureKit': { cryptoFramework: { CryptoMode: { ENCRYPT_MODE: 1, DECRYPT_MODE: 2 },
    createRandom: () => ({ generateRandom: async count => ({ data: Uint8Array.from(crypto.randomBytes(count)) }) }),
    createSymKeyGenerator: () => ({ convertKey: async ({ data }) => ({ data: Uint8Array.from(data), clearMem() { this.data.fill(0); } }) }),
    createCipher: () => ({ async init(mode, key, params) { this.mode = mode; this.key = key; this.params = params; },
      async doFinal({ data }) {
        const p = this.params;
        if (this.mode === 1) {
          const cipher = crypto.createCipheriv('aes-256-gcm', this.key.data, p.iv.data); cipher.setAAD(p.aad.data);
          return { data: Uint8Array.from(Buffer.concat([cipher.update(data), cipher.final(), cipher.getAuthTag()])) };
        }
        const cipher = crypto.createDecipheriv('aes-256-gcm', this.key.data, p.iv.data); cipher.setAAD(p.aad.data); cipher.setAuthTag(p.authTag.data);
        return { data: Uint8Array.from(Buffer.concat([cipher.update(data), cipher.final()])) };
      } }) } }
};
function load(name) {
  const file = path.resolve(name.endsWith('.ets') ? name : name + '.ets'); if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true,
  } }).outputText, { exports, console, setTimeout, clearTimeout, Observed: x => x,
    require: id => id.startsWith('@kit.') ? kits[id] : load(path.resolve(path.dirname(file), id)) }, { filename: file });
  return exports;
}
const from = name => load(path.join(root, name));
const { LanCollaborationCrypto, parseLanInvitation } = from('services/LanCollaborationCrypto');
const { DeviceCollaboration } = from('services/DeviceCollaboration');
const { LanDeviceCollaboration } = from('services/LanDeviceCollaboration');
async function until(check) {
  for (let i = 0; i < 500; i++) { if (check()) return; await new Promise(resolve => setTimeout(resolve, 5)); }
  assert.ok(check(), 'LAN asynchronous state not reached');
}
function fixture(name) {
  let sequence = 0; const listeners = [], inputs = [];
  const thread = { id: name + '-thread', title: name, updatedAt: 1, phase: 'idle', error: '', queued: 0, model: 'test' };
  const messages = [];
  const session = { state: { ready: true }, subscribe(callback) { listeners.push(callback); return () => {}; },
    collaborationThreads: () => [JSON.parse(JSON.stringify(thread))],
    collaborationOutput: id => { assert.equal(id, thread.id); return { thread: { ...thread }, messages: JSON.parse(JSON.stringify(messages)) }; },
    async submitCollaborationInput(id, text) {
      assert.equal(id, thread.id); inputs.push(text);
      messages.push({ id: name + ++sequence, role: 'assistant', content: text, status: 'complete', error: '', thinking: false, tools: [] });
      thread.status = 'complete'; listeners.forEach(listener => listener({ kind: 'snapshot' }));
    } };
  const model = new DeviceCollaboration(() => name + '-request-' + ++sequence); model.localName = name; model.attach(session);
  return { model, lan: new LanDeviceCollaboration(model), thread, inputs };
}
async function main() {
  const secret = await LanCollaborationCrypto.secret(), encoder = new LanCollaborationCrypto(), decoder = new LanCollaborationCrypto();
  await encoder.initialize(secret); await decoder.initialize(secret);
  try {
    const packet = { version: 1, kind: 'hello', name: '敏感会话🙂'.repeat(5000) };
    const encrypted = await encoder.encrypt(packet, 'nonce-a', 'host', 0);
    assert.ok(!encrypted.includes('敏感会话'));
    assert.equal((await decoder.decrypt(encrypted, 'nonce-a', 'host', 0)).name, packet.name);
    await assert.rejects(decoder.decrypt(encrypted, 'nonce-b', 'host', 0), 'Cannot replay an old socket on a new challenge');
    await assert.rejects(decoder.decrypt(encrypted, 'nonce-a', 'guest', 0), 'Cannot reflect a packet in the other direction');
    await assert.rejects(decoder.decrypt(encrypted, 'nonce-a', 'host', 1), /sequence/);
    const tampered = JSON.parse(encrypted); tampered.data = 'AAAA' + tampered.data.slice(4);
    await assert.rejects(decoder.decrypt(JSON.stringify(tampered), 'nonce-a', 'host', 0));
    assert.throws(() => parseLanInvitation('tinybot-lan://8.8.8.8:80/' + secret));
    assert.throws(() => parseLanInvitation('tinybot-lan://127.0.0.1:80/' + secret));
  } finally { encoder.dispose(); decoder.dispose(); }
  const phone = fixture('phone'), tablet = fixture('tablet');
  try {
    let releaseListen;
    pauseListen = new Promise(resolve => { releaseListen = resolve; });
    const cancelledHost = phone.lan.host(); await until(() => listeningStarted);
    phone.lan.stop(); releaseListen(); await cancelledHost; pauseListen = undefined;
    assert.equal(servers.size, 0, 'Cancelling a pending listen must release the port when it completes');
    assert.equal(phone.lan.invitation, '');
    for (let round = 0; round < 4; round++) {
      const host = round % 2 ? phone : tablet, guest = round % 2 ? tablet : phone;
      await host.lan.host(); guest.lan.input = host.lan.invitation;
      await guest.lan.join(); await until(() => host.model.peerCatalogReady && guest.model.peerCatalogReady);
      assert.equal(host.lan.active, true); assert.equal(guest.lan.active, true);
      guest.model.select('peer', host.thread.id); await until(() => guest.model.output?.thread.id === host.thread.id);
      guest.model.draft = 'encrypted request 中文🙂 round ' + round; await guest.model.submit();
      await until(() => guest.model.messages.some(message => message.content.includes('round ' + round)));
      assert.ok(host.inputs.some(text => text.includes('round ' + round)));
      assert.ok(!wire.some(frame => frame.includes('encrypted request')), 'Never transmit unencrypted business messages');
      guest.lan.disconnect(); await until(() => !host.model.connected && !guest.model.connected);
      await guest.lan.join(); await until(() => host.model.connected && guest.model.connected);
      assert.equal(guest.lan.active, true, 'Same invitation reconnects while it is valid');
      host.lan.stop(); guest.lan.stop();
    }
    await tablet.lan.host(); const invitation = tablet.lan.invitation;
    phone.lan.input = invitation.slice(0, -1) + (invitation.endsWith('0') ? '1' : '0');
    await phone.lan.join(); await until(() => !!phone.lan.error && !phone.lan.busy);
    assert.equal(tablet.model.connected, false, 'Wrong keys cannot enter business collaboration');
    phone.lan.input = invitation; await phone.lan.join(); await until(() => phone.model.connected && tablet.model.connected);
  } finally { phone.lan.stop(); tablet.lan.stop(); phone.model.dispose(); tablet.model.dispose(); }
  assert.equal(servers.size, 0, 'No listening ports leak after shutdown');
  console.log('PASS LAN AES-GCM authentication, replay/tamper rejection, fragmented reception, two-way execution, repeated role changes and reconnects, wrong-key recovery and socket cleanup');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
