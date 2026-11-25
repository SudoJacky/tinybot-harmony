const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const zip = require('node:zlib');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const sourceRoot = path.resolve(__dirname, '../entry/src/main/ets');
const id = '4986acfc-57fc-447d-85f6-7349e04dfc1d';
const asset = 'chat_sessions/' + id + '_files/pixel.png';
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jQfsAAAAASUVORK5CYII=', 'base64');
const fragment = (type, content) => ({ type, content });
const message = (id, parent_id, role, fragments, status = 'FINISHED') => ({ id, parent_id, role, fragments, status });
const session = { id, title: 'DeepSeek Import Fixture', pinned: true, current_message_id: 3,
  updated_at: '2026-11-24T10:00:00+08:00', messages: [
    message(1, null, 'USER', [fragment('REQUEST', 'Question in the archived conversation.'), { type: 'FILE', files: [
      { export_path: asset, file_name: 'fixture.png', is_image: true }, { export_path: null, file_name: 'unavailable.pdf', is_image: false }
    ] }]),
    message(2, 1, 'ASSISTANT', [fragment('RESPONSE', 'Earlier branch.')]),
    message(3, 1, 'ASSISTANT', [fragment('THINK', 'Stored reasoning.'), fragment('RESPONSE', 'Current reply.'),
      { type: 'TOOL_SEARCH', results: [{ title: 'Example', url: 'https://example.com/result' }] }], 'INCOMPLETE')
  ] };

function archive(entries) {
  const local = [], central = [];
  let offset = 0;
  for (const [name, raw] of entries) {
    const nameBytes = Buffer.from(name), plain = Buffer.from(raw), stored = name.endsWith('.png');
    const packed = stored ? plain : zip.deflateRawSync(plain);
    const checksum = zip.crc32(plain);
    const header = Buffer.alloc(30);
    header.writeUInt32LE(0x04034b50); header.writeUInt16LE(20, 4); header.writeUInt16LE(8, 6);
    header.writeUInt16LE(stored ? 0 : 8, 8); header.writeUInt16LE(nameBytes.length, 26);
    const descriptor = Buffer.alloc(16);
    descriptor.writeUInt32LE(0x08074b50); descriptor.writeUInt32LE(checksum, 4);
    descriptor.writeUInt32LE(packed.length, 8); descriptor.writeUInt32LE(plain.length, 12);
    local.push(header, nameBytes, packed, descriptor);
    const slot = Buffer.alloc(46);
    slot.writeUInt32LE(0x02014b50); slot.writeUInt16LE(20, 4); slot.writeUInt16LE(20, 6); slot.writeUInt16LE(8, 8);
    slot.writeUInt16LE(stored ? 0 : 8, 10); slot.writeUInt32LE(checksum, 16); slot.writeUInt32LE(packed.length, 20);
    slot.writeUInt32LE(plain.length, 24); slot.writeUInt16LE(nameBytes.length, 28); slot.writeUInt32LE(offset, 42);
    central.push(slot, nameBytes);
    offset += header.length + nameBytes.length + packed.length + descriptor.length;
  }
  const directory = Buffer.concat(central), footer = Buffer.alloc(22);
  footer.writeUInt32LE(0x06054b50); footer.writeUInt16LE(entries.length, 8); footer.writeUInt16LE(entries.length, 10);
  footer.writeUInt32LE(directory.length, 12); footer.writeUInt32LE(offset, 16);
  return Buffer.concat([...local, directory, footer]);
}
const entries = [['manifest.json', '{"export_format_version":3}'], ['user.json', '{"email":"account fixture only"}'],
  ['chat_sessions/' + id + '.json', JSON.stringify(session)], [asset, png]];
const fixture = archive(entries);
if (process.env.TINYBOT_DEEPSEEK_FIXTURE) fs.writeFileSync(process.env.TINYBOT_DEEPSEEK_FIXTURE, fixture);

const cache = new Map();
let input = fixture, cancelled = false, closeCount = 0, nextAssetId = 0;
const storedFiles = new Set(), openedFiles = [];
const downloaded = new Map(), networkRequests = [];
let closeSessions = 0, cancelDownload = false;
let respond;
const kits = {
  '@kit.CoreFileKit': { fileIo: { OpenMode: { READ_ONLY: 0 },
    open: async name => { openedFiles.push(name); return { fd: downloaded.has(name) ? name : 1 }; },
    close: async () => { closeCount++; },
    stat: async fd => ({ size: (downloaded.get(fd) || input).length, isFile: () => true }),
    access: async name => downloaded.has(name),
    unlink: async name => { downloaded.delete(name); },
    read: async (fd, output, options) => {
      const start = options.offset, end = Math.min(start + options.length, start + 20000);
      const chunk = (downloaded.get(fd) || input).subarray(start, end);
      new Uint8Array(output).set(chunk);
      return chunk.length;
    } },
  picker: { DocumentViewPicker: class { async select() { return cancelled ? [] : ['fixture.zip']; } } } },
  '@kit.ArkTS': { url: { URL: { parseURL: (address, base) => new URL(address, base) } }, util: {
    generateRandomUUID: () => 'download-fixture', TextDecoder: class {
    constructor(encoding, options) { this.decoder = new TextDecoder(encoding, options); }
    decodeToString(bytes) { return this.decoder.decode(bytes); }
  } } },
  '@kit.BasicServicesKit': { zlib: { createZipSync() {
    let stream, final;
    return { inflateInit2(value) { stream = value; }, inflateEnd() {},
      async inflate() {
        const input = Buffer.from(stream.nextIn);
        const output = zip.inflateRawSync(input, { maxOutputLength: stream.availableOut, info: true });
        new Uint8Array(stream.nextOut).set(output.buffer);
        final = { totalIn: output.engine.bytesWritten, totalOut: output.buffer.length };
        return 1;
      },
      getZStream() { return final; } };
  }, createChecksumSync: () => ({ crc32: (crc, data) => zip.crc32(Buffer.from(data), crc) }),
  ReturnStatus: { STREAM_END: 1 }, CompressFlushMode: { FINISH: 4 } } },
  '@kit.RemoteCommunicationKit': { rcp: { createSession(config) {
    assert.equal(config.requestConfiguration.transfer.autoRedirect, false);
    assert.equal(config.requestConfiguration.security.remoteValidation, 'system');
    assert.deepEqual(Object.keys(config.headers), ['Accept']);
    return {
      async downloadToFile(address, { file }) {
        networkRequests.push(address);
        downloaded.set(file, fixture);
        return respond(address, config.requestConfiguration.tracing.httpEventsHandler);
      },
      close() { closeSessions++; },
      cancel() { cancelDownload = true; }
    };
  } } },
  '@kit.AbilityKit': {}, '@ohos/hypium': {}
};
const fauxAttachments = {
  async saveImportedFile(bytes, name, photo) {
    assert.ok(bytes.byteLength > 0);
    const id = 'fixture-attachment-' + ++nextAssetId;
    const attachment = { id, name, mime: 'image/jpeg', size: 20, path: id + '.jpg' };
    assert.equal(photo, true);
    storedFiles.add(id);
    return attachment;
  },
  async discardImportedFile(item) { assert.ok(storedFiles.delete(item.id)); }
};
function load(file) {
  file = path.resolve(file.endsWith('.ets') ? file : file + '.ets');
  if (file === path.join(sourceRoot, 'services/Attachments.ets')) return { Attachments: fauxAttachments };
  if (cache.has(file)) return cache.get(file);
  const exports = {};
  cache.set(file, exports);
  let contents = fs.readFileSync(file, 'utf8');
  if (file.endsWith('SessionService.test.ets')) contents += '\nexport { Fixture, seed };';
  const code = ts.transpileModule(contents, { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true
  } }).outputText;
  vm.runInNewContext(code, { exports, setTimeout, clearTimeout, Observed: value => value, require: name => {
    if (name in kits) return kits[name];
    if (!name.startsWith('.')) throw Error('Unmocked dependency: ' + name);
    return load(path.resolve(path.dirname(file), name));
  } }, { filename: file });
  return exports;
}
const { chooseDeepSeekArchive, importDeepSeekArchive, readDeepSeekPlan } = load(path.join(sourceRoot, 'services/DeepSeekArchive'));
const { withDeepSeekDownload } = load(path.join(sourceRoot, 'services/DeepSeekDownload'));
const { Diagnostics } = load(path.join(sourceRoot, 'model/Diagnostics'));
const { ZipArchive } = load(path.join(sourceRoot, 'services/ZipArchive'));
const { Fixture, seed } = load(path.resolve(sourceRoot, '../../test/SessionService.test'));

(async () => {
  const existing = seed();
  existing.threads[0].draft = 'An existing unsent draft';
  const app = new Fixture(existing);
  await app.session.initialize();
  const commit = (threads, prepare) => app.session.importDeepSeek(threads, prepare);
  assert.equal(await chooseDeepSeekArchive({}, commit), 2);
  const durable = await app.repository.load();
  const group = durable.threads.filter(thread => thread.importSource === 'deepseek');
  assert.equal(group.length, 2);
  assert.equal(durable.activeThreadId, existing.activeThreadId);
  assert.equal(durable.threads.find(thread => thread.id === existing.activeThreadId).draft, 'An existing unsent draft');
  assert.ok(group.every(thread => thread.projectId === undefined));
  assert.equal(group[0].title, session.title);
  assert.equal(group[0].updatedAt, Date.parse(session.updated_at));
  assert.equal(group[0].pinned, true);
  assert.equal(group[0].messages[1].status, 'stopped');
  assert.equal(group[0].messages[1].steps[0].reasoningContent, 'Stored reasoning.');
  assert.match(group[0].messages[1].content, /https:\/\/example.com\/result/);
  assert.match(group[0].messages[0].content, /unavailable.pdf/);
  assert.equal(group[1].parentThreadId, group[0].id);
  assert.equal(group[1].parentMessageId, group[0].messages[0].id);
  assert.equal(group[1].messages[1].content, 'Earlier branch.');
  assert.deepEqual(Array.from(group, thread => thread.messages[0].attachments[0].id), Array(2).fill('fixture-attachment-1'));
  assert.equal(storedFiles.size, 1, 'Sharing branch history does not duplicate binary attachments');
  assert.equal(await chooseDeepSeekArchive({}, commit), 0);
  assert.equal(storedFiles.size, 1);
  assert.ok(!JSON.stringify(durable).includes('account fixture only'));
  assert.equal(closeCount, 2);
  cancelled = true;
  assert.equal(await chooseDeepSeekArchive({}, commit), undefined);
  assert.equal(openedFiles.length, 2);
  cancelled = false;
  const brokenRepository = new Fixture(seed());
  await brokenRepository.session.initialize();
  brokenRepository.repository.beforeSave = async () => { throw Error('injected disk failure'); };
  assert.equal(await chooseDeepSeekArchive({}, (threads, prepare) => brokenRepository.session.importDeepSeek(threads, prepare)), -1);
  assert.equal(storedFiles.size, 1, 'A failed commit must remove only the newly staged attachment');
  assert.equal(brokenRepository.session.snapshot().threads.length, 1);
  input = archive(entries.concat([entries[2]]));
  await assert.rejects(() => ZipArchive.readDirectory(1), /ZIP/);
  input = Buffer.from(fixture);
  input[input.indexOf(png) + 12] ^= 1;
  const tampered = await ZipArchive.readDirectory(1);
  await assert.rejects(() => tampered.read(tampered.entry(asset), 1024), /ZIP/);
  input = archive(entries.map(([name, bytes]) => [name, name === 'manifest.json' ? '{"export_format_version":4}' : bytes]));
  await assert.rejects(async () => readDeepSeekPlan(await ZipArchive.readDirectory(1)), /版本/);
  const cycle = { ...session, messages: [session.messages[0], session.messages[1], { ...session.messages[2], parent_id: 3 }] };
  input = archive(entries.map(([name, bytes]) => [name, name.endsWith(id + '.json') ? JSON.stringify(cycle) : bytes]));
  await assert.rejects(async () => readDeepSeekPlan(await ZipArchive.readDirectory(1)), /格式/);
  console.log('PASS scoped DeepSeek import, message graph, reasoning and sources, attachment sharing, repeat import, rollback, cancellation and invalid archives');

  const absolute = 'https://chat.deepseek.example/download?token=secret%2f%2B';
  const signedCdn = 'https://archive-cdn.example/file?signature=another%2bvalue';
  const fresh = new Fixture(seed());
  await fresh.session.initialize();
  let serverStatus = 0;
  respond = () => ++serverStatus === 1 ? { statusCode: 302, headers: { Location: [signedCdn] } } :
    { statusCode: 200, headers: { 'content-type': 'application/octet-stream' } };
  const downloadedCount = await withDeepSeekDownload('/cache', ' ' + absolute + ' ', name => {
    assert.equal(name, '/cache/deepseek-download-fixture.zip');
    return importDeepSeekArchive(name, (threads, prepare) => fresh.session.importDeepSeek(threads, prepare));
  });
  assert.equal(downloadedCount, 2);
  assert.deepEqual(networkRequests, [absolute, signedCdn]);
  assert.equal(downloaded.size, 0);
  assert.equal(closeSessions, 2);
  assert.ok(!JSON.stringify(await fresh.repository.load()).includes('another%2bvalue'));
  const rejectLink = address => withDeepSeekDownload('/cache', address, () => assert.fail('Unexpected archive import'));
  respond = () => ({ statusCode: 403, headers: {} });
  await assert.rejects(() => rejectLink(absolute), /可能已过期/);
  respond = () => ({ statusCode: 200, headers: { 'Content-Type': ['text/html; charset=utf-8'] } });
  await assert.rejects(() => rejectLink(absolute), /直接下载链接/);
  respond = () => ({ statusCode: 307, headers: { location: 'http://archive-cdn.example/zip' } });
  await assert.rejects(() => rejectLink(absolute), /有效的 HTTPS/);
  respond = () => ({ statusCode: 307, headers: { location: '/download?token=secret%2f%2B' } });
  await assert.rejects(() => rejectLink(absolute), /重定向异常/);
  await assert.rejects(() => rejectLink('https://127.0.0.1/export.zip'), /有效的 HTTPS/);
  await assert.rejects(() => rejectLink('https://user:password@archive-cdn.example/export.zip'), /有效的 HTTPS/);
  const diagnosticEvents = [];
  Diagnostics.configureLogSink(event => diagnosticEvents.push(event));
  respond = address => { throw Object.assign(Error('native error for ' + address), { code: 2300028 }); };
  await assert.rejects(() => rejectLink(absolute), error => /检查网络/.test(error.message) && !error.message.includes('secret'));
  assert.equal(diagnosticEvents.at(-1).fields.code, 2300028);
  assert.ok(!JSON.stringify(diagnosticEvents).includes('secret'));
  respond = (_address, events) => {
    events.onDownloadProgress(700 * 1024 * 1024, 100);
    throw Error('cancelled by download budget');
  };
  await assert.rejects(() => rejectLink(absolute), /512 MB/);
  assert.equal(cancelDownload, true);
  assert.equal(downloaded.size, 0, 'All failed paths must remove any downloaded data');
  console.log('PASS signed HTTPS link import, redirect validation, response budget, expired and HTML responses, secret redaction and temporary-file cleanup');

  if (process.argv[2]) {
    input = fs.readFileSync(process.argv[2]);
    const actual = await ZipArchive.readDirectory(1);
    const plan = await readDeepSeekPlan(actual);
    const files = new Set();
    for (const attachments of plan.files.values()) for (const item of attachments) files.add(item.path);
    for (const file of files) {
      assert.ok(await actual.read(actual.entry(file), 20 * 1024 * 1024));
    }
    console.log(JSON.stringify({ sessions: plan.threads.filter(thread => !thread.parentThreadId).length,
      branches: plan.threads.filter(thread => thread.parentThreadId).length, embeddedFiles: files.size }));
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
