const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict'), zlib = require('node:zlib');
const { TextEncoder, TextDecoder } = require('node:util');
const root = path.resolve(__dirname, '..');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const files = new Map(), writes = [], removed = [], released = [], draws = [], captureOrder = [];
const exportLogs = [];
let destination = 'saved', captureFailure = false, uuid = 0, packFailure = false;
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a1ioAAAAASUVORK5CYII=', 'base64');
const buffer = value => { const b = Buffer.from(value); return b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength); };
const io = {
  OpenMode: {}, access: async name => files.has(name),
  open: async name => ({ fd: name }), close: async () => {}, unlink: async name => { removed.push(name); files.delete(name); }
};
const image = {
  PixelMapFormat: {}, AlphaType: {},
  createImagePacker: () => ({ packToData: async pixel => {
    if (pixel.final && packFailure) throw Error('encoder failed');
    return buffer(png);
  }, release: async () => released.push('packer') }),
  createEmptyPixelMap: options => ({ final: true, options, release: async () => released.push('result') }),
  createImageSource: fd => ({ createPixelMap: async () => ({ fd, release: async () => released.push(fd) }),
    release: async () => released.push('source') })
};
const native = {
  '@kit.BasicServicesKit': {},
  '@kit.AbilityKit': {}, '@kit.ImageKit': { image },
  '@kit.ArkGraphics2D': { drawing: { Canvas: class { drawColor() {} drawImageRect(pixel, rect) { draws.push(rect); } } } },
  '@kit.CoreFileKit': { fileIo: io, picker: { DocumentViewPicker: class { async save() { return destination ? [destination] : []; } } } },
  '@kit.ShareKit': {}, '@kit.MediaLibraryKit': {},
  '@kit.ArkTS': { util: { generateRandomUUID: () => 'id-' + ++uuid,
    TextEncoder: class { encodeInto(value) { return new TextEncoder().encode(value); } },
    TextDecoder: class { constructor(...args) { this.decoder = new TextDecoder(...args); } decodeToString(value) { return this.decoder.decode(value); } } } }
};
const cache = new Map();
function load(name) {
  if (cache.has(name)) return cache.get(name);
  if (name === 'model/Diagnostics') return { Diagnostics: { log: (...args) => exportLogs.push(args) } };
  if (name === 'model/I18n') return { t: (s, values = []) => s.replace(/\{(\d+)\}/g, (_, n) => values[+n]) };
  if (name === 'services/Attachments') return {
    readBounded: async fd => buffer(files.get(fd)),
    writeBytes: async (name, bytes) => { writes.push(name); files.set(name, Buffer.from(bytes)); }, Attachments: {}
  };
  const exports = {}; cache.set(name, exports);
  const source = fs.readFileSync(path.join(root, 'entry/src/main/ets', name + '.ets'), 'utf8');
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS,
    target: ts.ScriptTarget.ES2021 } }).outputText, {
    exports, Uint8Array, ArrayBuffer, DataView, console,
    require: id => native[id] || load(path.posix.normalize(path.posix.join(path.posix.dirname(name), id)))
  }, { filename: name });
  return exports;
}
function chunks(bytes) {
  const result = [];
  for (let at = 8; at < bytes.length;) {
    const size = bytes.readUInt32BE(at), type = bytes.toString('ascii', at + 4, at + 8);
    result.push({ type, raw: bytes.subarray(at, at + size + 12), data: bytes.subarray(at + 8, at + 8 + size) });
    at += size + 12;
  }
  return result;
}
function crc32(bytes) {
  let c = 0xffffffff;
  for (const b of bytes) { c ^= b; for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (c & 1 ? 0xedb88320 : 0); }
  return (c ^ 0xffffffff) >>> 0;
}
(async () => {
  const { exportMetadata, stampMarkdown, stampHtml, stampPng } = load('model/ExportMetadata');
  const { markdownBlocks } = load('model/Markdown');
  const metadata = exportMetadata('中文-uuid');
  const original = '# Title\n\n- **Bold**\n\n```html\n<!-- tinybot-export-aigc {} -->\n```\n';
  const stamped = stampMarkdown(original, metadata);
  assert.deepEqual(markdownBlocks(stamped), markdownBlocks(original));
  assert.equal(stampMarkdown(stamped, metadata), stamped, 're-export does not duplicate the marker');
  for (const prefix of ['---\ntitle: Test\n---\n', '\ufeff---\r\ntitle: Test\r\n---\r\n']) {
    const marked = stampMarkdown(prefix + original, metadata);
    assert.ok(marked.startsWith(prefix)); assert.equal(stampMarkdown(marked, metadata), marked);
  }
  const html = '<!doctype html>\n<!-- <head> -->\n<html lang="zh"><head data-note="a>b"><title>T</title></head><body><script>const h="<head>";</script>正文</body></html>';
  const markedHtml = stampHtml(html, metadata);
  assert.ok(markedHtml.includes('<head data-note="a>b">\n<meta name="AIGC"'));
  assert.ok(markedHtml.endsWith('<body><script>const h="<head>";</script>正文</body></html>'));
  assert.equal(stampHtml(markedHtml, metadata), markedHtml);
  assert.equal(stampHtml('<script>const s="<head>";</script>', metadata).split('\n\n')[1], '<script>const s="<head>";</script>');
  const markedPng = Buffer.from(stampPng(png, new TextEncoder().encode(JSON.stringify(metadata))));
  const originalChunks = chunks(png), markedChunks = chunks(markedPng);
  assert.deepEqual(markedChunks.filter(c => c.type !== 'iTXt').map(c => c.raw), originalChunks.map(c => c.raw));
  const itxt = markedChunks.find(c => c.type === 'iTXt');
  assert.equal(itxt.data.subarray(0, 9).toString('hex'), '414947430000000000');
  assert.deepEqual(JSON.parse(itxt.data.subarray(9).toString()), JSON.parse(JSON.stringify(metadata)));
  assert.equal(itxt.raw.readUInt32BE(itxt.raw.length - 4), crc32(itxt.raw.subarray(4, -4)));
  assert.deepEqual(zlib.inflateSync(Buffer.concat(markedChunks.filter(c => c.type === 'IDAT').map(c => c.data))),
    zlib.inflateSync(Buffer.concat(originalChunks.filter(c => c.type === 'IDAT').map(c => c.data))));
  assert.throws(() => stampPng(new Uint8Array(12), new Uint8Array()), /signature/);

  const { exportFile } = load('services/NativeActions');
  const context = { cacheDir: 'cache' };
  files.set('original', Buffer.from(original));
  await exportFile(context, 'original', 'chat.md', true);
  assert.ok(files.get('saved').toString().includes('tinybot-export-aigc')); assert.equal(files.get('original').toString(), original);
  for (const [name, ai] of [['user.md', false], ['data.csv', true], ['backup.json', false]]) {
    await exportFile(context, 'original', name, ai); assert.equal(files.get('saved').toString(), original);
  }
  files.set('html', Buffer.from(html)); await exportFile(context, 'html', 'page.html', true);
  assert.ok(files.get('saved').toString().includes('<meta name="AIGC"'));
  destination = ''; const count = writes.length; await exportFile(context, 'original', 'chat.md', true);
  assert.equal(writes.length, count); destination = 'saved';

  const { conversationSections, aiAssistedFile } = load('model/ConversationExport');
  const receipt = { status: 'complete', call: { function: { name: 'write_file', arguments: '{"path":"./page.html"}' } } };
  const long = '全文🙂'.repeat(2000);
  const thread = { id: 't', title: 'Long conversation', messages: [
    { role: 'user', content: 'first' },
    { role: 'assistant', modelRef: { providerId: 'provider', modelId: 'model-v1' }, content: long, steps: [{ content: long, tools: [receipt] }] },
    { role: 'user', content: 'last' }
  ] };
  const sections = conversationSections(thread);
  assert.equal(sections.filter(s => s.kind === 'text' && !s.user).map(s => s.text).join(''), long);
  assert.ok(sections.at(-1).text.includes('AI可能会犯错，请仔细鉴别。'));
  assert.equal(sections.filter(s => s.kind === 'role').length, 3);
  const branded = conversationSections(thread, [{ id: 'provider', name: 'Provider name', presetId: 'deepseek' }]);
  const assistant = branded.find(s => s.kind === 'role' && !s.user);
  assert.equal(assistant.provider, 'Provider name'); assert.equal(assistant.model, 'model-v1');
  assert.equal(assistant.providerPreset, 'deepseek');
  assert.equal(branded.filter(s => s.bubbleStart).length, 2);
  assert.equal(branded.filter(s => s.bubbleEnd).length, 2);
  const preview = id => ({ status: 'complete', call: { id, function: { name: 'publish_preview' } },
    previewContent: '<div>preview</div>', output: '{"path":"chart.html","title":"Chart"}',
    previewScreenshot: { image: { name: id + '.jpg', mime: 'image/jpeg' }, width: 400, height: 1200 } });
  const previewSections = conversationSections({ title: 'Preview', messages: [{ id: 'answer', role: 'assistant', content: '',
    steps: [{ content: '', tools: [preview('old'), preview('latest')] }] }] });
  assert.equal(previewSections.filter(s => s.kind === 'attachment-image').length, 1);
  assert.equal(previewSections.find(s => s.kind === 'attachment-image').attachment.name, 'latest.jpg');
  assert.equal(previewSections.find(s => s.kind === 'attachment-image').imageRatio, 3);
  const code = 'line\n'.repeat(200);
  const codeSections = conversationSections({ title: 'Code', messages: [{ role: 'assistant', content: '```\n' + code + '```' }] });
  assert.equal(codeSections.filter(s => s.kind === 'code').map(s => s.text).join(''), code.slice(0, -1));
  assert.ok(codeSections.filter(s => s.kind === 'code').every(s => s.text.split('\n').length <= 61));
  const data = { threads: [thread] };
  assert.equal(aiAssistedFile(data, 't', 'page.html'), true);
  assert.equal(aiAssistedFile(data, 't', 'original.md'), false);
  assert.equal(aiAssistedFile(data, 'another-workspace', 'page.html'), false);
  receipt.status = 'error'; assert.equal(aiAssistedFile(data, 't', 'page.html'), false); receipt.status = 'complete';

  const { conversationImage } = load('services/ConversationImageExport');
  const capture = async section => {
    captureOrder.push(section.text);
    if (captureFailure && section.kind === 'footer') throw Error('snapshot failed');
    return { getImageInfo: async () => ({ size: { width: 720, height: 40 } }), release: async () => released.push('capture') };
  };
  const output = await conversationImage(context, sections, capture);
  assert.equal(captureOrder.length, sections.length); assert.equal(captureOrder.at(-1), sections.at(-1).text);
  assert.equal(draws.length, sections.length); assert.equal(draws.at(-1).bottom, sections.length * 40);
  assert.ok(chunks(files.get(output)).some(c => c.type === 'iTXt'));
  assert.equal([...files.keys()].filter(name => name.startsWith('cache/')).length, 1, 'only final PNG remains');
  files.delete(output); captureFailure = true;
  await assert.rejects(conversationImage(context, sections, capture), /snapshot failed/);
  assert.equal(exportLogs.at(-1)[1], 'export'); assert.equal(exportLogs.at(-1)[2], 'image_failed');
  assert.equal(exportLogs.at(-1)[3].phase, 'capture');
  assert.equal(exportLogs.at(-1)[3].chunk, sections.length - 1);
  assert.equal([...files.keys()].filter(name => name.startsWith('cache/')).length, 0);
  captureFailure = false; packFailure = true;
  await assert.rejects(conversationImage(context, sections, capture), /encoder failed/);
  assert.equal(exportLogs.at(-1)[3].phase, 'encode');
  assert.equal([...files.keys()].filter(name => name.startsWith('cache/')).length, 0);
  packFailure = false;
  await assert.rejects(conversationImage(context, sections, async () => ({
    getImageInfo: async () => ({ size: { width: 720, height: 50000 } }), release: async () => released.push('too-large')
  })), /会话过长/);
  assert.equal([...files.keys()].filter(name => name.startsWith('cache/')).length, 0);
  console.log('PASS export-only Markdown/HTML metadata, PNG CRC/pixel payload, full transcript stitching and failure cleanup');
})().catch(error => { console.error(error); process.exitCode = 1; });
