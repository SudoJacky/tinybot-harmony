// Production mailbox storage, protocol framing, MIME parsing, permissions and tools.
// Only Harmony secure assets/TLS are replaced; no real mailbox or credentials are used.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), crypto = require('node:crypto');
const assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets'), cache = new Map(), assets = new Map(), diagnostics = [];
const timers = new Map();
const util = {
  generateRandomUUID: () => crypto.randomUUID(),
  TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } },
  TextDecoder: class { constructor(charset) { this.inner = new TextDecoder(charset); } decodeToString(bytes) { return this.inner.decode(bytes); } },
  Base64Helper: class { encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); } decodeSync(text) { return Uint8Array.from(Buffer.from(text, 'base64')); } }
};
const kits = { '@kit.ArkTS': { util }, '@kit.NetworkKit': { socket: {} } };
function mock(name, exports) { cache.set(path.join(root, name + '.ets'), exports); }
mock('model/Diagnostics', { Diagnostics: { log: (...args) => diagnostics.push(args) } });
mock('services/CredentialStore', { CredentialStore: class {
  async readOptional(key) { return assets.get(key); }
  async write(key, value) { assert.ok(!assets.has(key)); assets.set(key, value); }
  async update(key, value) { assert.ok(assets.has(key)); assets.set(key, value); }
  async remove(key) { assets.delete(key); }
} });
function load(name) {
  const file = path.resolve(root, name.endsWith('.ets') ? name : name + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  const code = ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  vm.runInNewContext(code, { exports, console, Uint8Array, ArrayBuffer, Map, Set,
    setTimeout: (callback, delay) => { const id = setTimeout(() => { timers.delete(id); callback(); }, delay); timers.set(id, callback); return id; },
    clearTimeout: id => { timers.delete(id); clearTimeout(id); },
    require: id => id.startsWith('.') ? load(path.resolve(path.dirname(file), id)) : assert.ok(id in kits, id) || kits[id]
  }, { filename: file }); return exports;
}
const { ImapFramer, imapQuote } = load('model/ImapWire');
const { mailBodyText, mailHeader, imapFolder } = load('model/MailMime');
const { MailAccounts } = load('services/MailAccounts');
const { MailService } = load('services/MailService');
const { MailTools } = load('services/MailTools');
const { Cancellation } = load('services/Cancellation');
const { validatePanelSource } = load('model/PanelSource');
const { RuleTools } = load('services/RuleTools');
const { SelectedTools } = load('services/SelectedTools');
const { ImapClient } = load('services/ImapClient');
const { NetworkTransfers } = load('services/NetworkTransfers');
const header = 'From: sender@example.com\r\nTo: user@example.com\r\nSubject: =?UTF-8?B?' + Buffer.from('订单已发货').toString('base64') + '?=\r\nDate: Thu, 5 Nov 2026 12:00:00 +0800\r\n\r\n';
const body = header.trimEnd() + '\r\nContent-Type: multipart/alternative; boundary="abc"\r\n\r\n--abc\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n' + Buffer.from('包裹明天送达').toString('base64') + '\r\n--abc\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<p>Ignored alternate</p>\r\n--abc--\r\n';
class FakeImap {
  constructor(options = {}) { this.options = options; this.commands = []; this.closed = false; this.started = false; }
  listen(data, failed) { this.data = data; this.failed = failed; }
  reply(text) { const bytes = Buffer.from(text, 'binary'); for (let i = 0; i < bytes.length; i += 7) this.data(Uint8Array.from(bytes.subarray(i, i + 7))); }
  async connect(host, port) { assert.equal(host, 'imap.example.com'); assert.equal(port, 993); this.started = true; if (!this.options.hangConnect) this.reply('* OK test\r\n'); }
  async send(command) {
    this.commands.push(command); const tag = command.split(' ')[0], text = command.slice(tag.length + 1).trim();
    if (this.options.hold && text.startsWith(this.options.hold)) { this.holding = true; return; }
    if (text === 'CAPABILITY') this.reply('* CAPABILITY IMAP4rev1 ID\r\n');
    else if (text.startsWith('LOGIN ')) { if (this.options.authFailure) { this.reply(tag + ' NO PRIVATE_PASSWORD_AND_EMAIL\r\n'); return; } }
    else if (text.startsWith('ID ')) {}
    else if (text.startsWith('EXAMINE ')) this.reply('* 3 EXISTS\r\n* OK [UIDVALIDITY ' + (this.options.validity || 42) + '] epoch\r\n');
    else if (text === 'UID SEARCH ALL') this.reply('* SEARCH 1 5 9\r\n');
    else if (text === 'UID SEARCH UNSEEN') this.reply('* SEARCH 5 9\r\n');
    else if (text.startsWith('UID SEARCH CHARSET UTF-8 ')) this.reply('* SEARCH 5\r\n');
    else if (text.startsWith('UID FETCH ')) {
      const ids = text.split(' ')[2].split(',').map(Number);
      for (const uid of ids) {
        if (this.options.deleted) continue;
        const content = text.includes('BODY.PEEK[]') ? this.options.body || body : header;
        const attrs = text.includes('BODY.PEEK[]') ? `UID ${uid} BODY[]` : `FLAGS (${uid === 1 ? '\\Seen' : ''}) RFC822.SIZE ${this.options.size || body.length} UID ${uid} BODY[HEADER]`;
        this.reply(`* 1 FETCH (${attrs} {${content.length}}\r\n${content})\r\n`);
      }
    } else throw Error('Unexpected test command: ' + text);
    this.reply(tag + ' OK complete\r\n');
  }
  async close() { this.closed = true; }
}
const account = { id: 'test-mail', name: 'Work', host: 'imap.example.com', port: 993, username: 'user@example.com', folders: ['INBOX', '工作'], enabled: true, allowBody: false };
const store = new MailAccounts(), created = [];
function service(options = {}) { return new MailService(store, () => { const transport = new FakeImap(options); created.push(transport); return transport; }); }
const query = { accountId: account.id, folder: 'INBOX', limit: 2 };
const invoke = (tools, name, args) => tools.execute({ id: 'test', function: { name, arguments: JSON.stringify(args) } }, new Cancellation()).then(JSON.parse);
const tick = () => new Promise(resolve => setImmediate(resolve));
async function until(predicate) { for (let i = 0; i < 30; i++) { if (predicate()) return; await tick(); } throw Error('Expected asynchronous test state'); }
async function main() {
  const literal = 'Subject: fake\r\nT1 OK injected\r\n)\r\n';
  const wire = `* 1 FETCH (UID 5 BODY[HEADER] {${literal.length}}\r\n${literal})\r\nT1 OK real\r\n`;
  for (let split = 0; split <= wire.length; split++) {
    const framer = new ImapFramer(), frames = [...framer.push(wire.slice(0, split)), ...framer.push(wire.slice(split))];
    assert.equal(frames.length, 2); assert.equal(frames[0].literals[0], literal); assert.equal(frames[1].text, 'T1 OK real');
  }
  assert.throws(() => new ImapFramer().push('* 1 FETCH ({999999}\r\n'), /512 KiB/);
  assert.throws(() => imapQuote('INBOX\r\nDELETE x'), /control/);
  assert.equal(imapQuote('a"b\\c'), '"a\\"b\\\\c"');
  assert.equal(imapFolder('工作&'), '&XeVPXA-&-');
  assert.equal(mailHeader('=?UTF-8?Q?Hello_=E4=B8=96=E7=95=8C?='), 'Hello 世界');
  assert.equal(mailHeader(Buffer.from('原始中文标题').toString('binary')), '原始中文标题');
  assert.throws(() => mailHeader('=?UTF-8?B?broken%?='), /base64/);
  assert.equal(mailBodyText(body), '包裹明天送达');
  assert.equal(mailBodyText('Content-Type: multipart/mixed; boundary="abc"\r\n\r\n--abc\r\nContent-Type: text/plain\r\n\r\nUse --abc in text.\r\n--abc--\r\n'), 'Use --abc in text.');
  assert.throws(() => mailBodyText('Content-Type: multipart/mixed; boundary="abc"\r\n\r\n--abc\r\nContent-Type: text/plain\r\n\r\nMissing end'), /Incomplete multipart/);
  assert.equal(mailBodyText('Content-Type: text/html\r\n\r\n<script>secret()</script><p>Hello &amp; hi</p><img src="https://tracker">'), 'Hello & hi');
  assert.equal(mailBodyText('Content-Type: text/plain\r\nContent-Disposition: attachment\r\n\r\nprivate'), '');
  assert.throws(() => mailBodyText('Content-Type: multipart/mixed\r\n\r\nbad'), /boundary/);
  console.log('PASS byte framing across every split, literal injection, MIME text and folder encoding');

  await store.save(account, 'app-secret');
  assert.equal((await store.list())[0].username, account.username);
  assert.ok(!JSON.stringify(await store.list()).includes('app-secret'));
  await assert.rejects(store.save({ ...account, host: 'other.example.com' }, ''), /authorization code/);
  await assert.rejects(store.save({ ...account, id: 'new-mail' }, ''), /authorization code/);
  await store.save({ ...account, name: 'Renamed' }, '');
  assert.equal((await store.connection(account.id)).secret, 'app-secret');
  const mail = service(), result = await mail.query(query, new Cancellation());
  assert.equal(result.total, 3); assert.equal(result.unread, 2); assert.equal(result.matched, 3); assert.equal(result.limited, true);
  assert.deepEqual(Array.from(result.messages, item => item.uid), [9, 5]); assert.equal(result.messages[0].subject, '订单已发货');
  assert.equal(result.messages[0].id, '42:9'); assert.ok(created.at(-1).closed);
  assert.ok(created.at(-1).commands.some(command => command.includes('EXAMINE')));
  assert.ok(created.at(-1).commands.every(command => !/\b(SELECT|STORE|EXPUNGE|DELETE|APPEND)\b/.test(command)));
  const filtered = await mail.query({ ...query, subject: '订单', unreadOnly: true }, new Cancellation()); assert.equal(filtered.matched, 1);
  assert.ok(created.at(-1).commands.some(command => command.includes('CHARSET UTF-8 UNSEEN SUBJECT "订单"')));
  let nativeClosed = false, nativeSent = false;
  kits['@kit.NetworkKit'].socket.constructTLSSocketInstance = () => {
    const fake = new FakeImap(), events = new Map(); fake.listen(bytes => events.get('message')({ message: bytes.buffer }), error => events.get('error')(error));
    return {
      on: (name, callback) => events.set(name, callback),
      async bind(address) { assert.equal(address.address, '0.0.0.0'); },
      async connect(options) { assert.equal(options.skipRemoteValidation, false); assert.ok(!options.secureOptions.ca); await fake.connect(options.address.address, options.address.port); },
      async send(text) { assert.equal(typeof text, 'string', 'TLSSocket.send accepts raw string, not a TCP send-options object'); nativeSent = true; await fake.send(text); },
      async close() { nativeClosed = true; await fake.close(); }
    };
  };
  assert.equal((await new MailService(store).query(query, new Cancellation())).unread, 2);
  assert.ok(nativeClosed && nativeSent, 'Production TLS adapter verifies certificates and releases its socket');
  const tools = new MailTools(mail), listed = await invoke(tools, 'list_mail_accounts', {});
  assert.equal(listed.accounts[0].accountId, account.id); assert.ok(!JSON.stringify(listed).includes(account.username));
  assert.equal((await invoke(tools, 'search_mail', query)).messages.length, 2);
  assert.equal(new RuleTools(tools, true).definitions().length, 3);
  const denied = new SelectedTools(tools, { agentMode: 'custom', disabledTools: ['search_mail'] });
  assert.equal(denied.definitions().length, 0); await assert.rejects(invoke(denied, 'read_mail', {}), /关闭/);
  validatePanelSource({ type: 'mail', mail: query, pointer: '', transform: { type: 'javascript', code: 'return {unread: input.unread};' } });
  assert.throws(() => validatePanelSource({ type: 'mail', mail: query, url: 'https://example.com' }), /only/);
  assert.throws(() => validatePanelSource({ type: 'mail', mail: { ...query, password: 'secret' } }), /Invalid mail query/);
  assert.throws(() => validatePanelSource({ type: 'api', url: 'https://example.com', mail: query }), /requires/);
  await assert.rejects(mail.query({ ...query, limit: 100 }, new Cancellation()), /1–20/);
  await assert.rejects(mail.query({ ...query, folder: 'Forbidden' }, new Cancellation()), /not allowed/);
  await assert.rejects(mail.read(account.id, 'INBOX', 42, 9, new Cancellation()), /body access/);
  await store.save({ ...account, allowBody: true }, '');
  assert.equal((await mail.read(account.id, 'INBOX', 42, 9, new Cancellation())).text, '包裹明天送达');
  assert.ok(created.at(-1).commands.some(command => command.includes('BODY.PEEK[]')));
  await assert.rejects(service({ validity: 43 }).read(account.id, 'INBOX', 42, 9, new Cancellation()), /UIDVALIDITY changed/);
  assert.ok(!created.at(-1).commands.some(command => command.includes('BODY.PEEK[]')));
  await assert.rejects(service({ size: 600000 }).read(account.id, 'INBOX', 42, 9, new Cancellation()), /512 KiB/);
  await assert.rejects(service({ deleted: true }).read(account.id, 'INBOX', 42, 9, new Cancellation()), /no longer exists/);
  await assert.rejects(service({ authFailure: true }).query(query, new Cancellation()), error => !error.message.includes('PRIVATE') && /rejected/.test(error.message));
  await store.save({ ...account, enabled: false }, '');
  assert.equal((await mail.available()).length, 0); await assert.rejects(mail.query(query, new Cancellation()), /disabled/);
  await store.save(account, '');
  console.log('PASS secure account lifecycle, scoped credentials, read-only tools, permissions and stale UID rejection');

  let transfers = 0; const detach = NetworkTransfers.observe(async () => { transfers++; return async () => { transfers--; }; });
  let before = created.length;
  const signal = new Cancellation(), pending = service({ hangConnect: true }).query(query, signal);
  const observed = assert.rejects(pending, /停止|cancel/i);
  await until(() => created.length > before && created.at(-1).started); signal.cancel(); await observed; assert.ok(created.at(-1).closed); assert.equal(transfers, 0);
  const hanging = service({ hold: 'UID SEARCH' }).query(query, new Cancellation()); const revoked = assert.rejects(hanging, /停止|cancel/i);
  await until(() => created.at(-1).holding); await store.save({ ...account, enabled: false }, ''); await revoked; assert.equal(transfers, 0);
  await store.save(account, '');
  before = created.length;
  const timed = service({ hangConnect: true }).query(query, new Cancellation()); const timeout = assert.rejects(timed, /timed out/);
  await until(() => created.length > before && created.at(-1).started);
  // Trigger the real session deadline callback without sleeping for a minute.
  [...timers.values()][0](); await timeout; assert.equal(transfers, 0); detach();
  await store.remove(account.id); assert.equal((await store.list()).length, 0); assert.ok(!assets.has('tinybot-mail-test-mail'));
  assert.ok(!JSON.stringify(diagnostics).includes('app-secret')); assert.ok(!JSON.stringify(diagnostics).includes('PRIVATE_PASSWORD'));
  assert.equal(timers.size, 0); console.log('PASS cancellation, revoke-in-flight, deadlines, cleanup and credential-free diagnostics');
}
main().catch(error => { console.error(error); process.exitCode = 1; }).finally(() => { for (const id of timers.keys()) clearTimeout(id); });
