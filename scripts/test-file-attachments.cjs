const backupAccount = { openID: 'fixture-openid-A', error: undefined, async backupOpenID() { if (this.error) throw this.error; if (!this.openID) throw Error('请登录创建备份时使用的华为账号。'); return this.openID; } };
const { legacyBackupFixture, backupCrypto } = require('./backup-fixture.cjs');
// Real workspace bytes and production attachment/read/backup code; only Harmony APIs are replaced.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict'), crypto = require('node:crypto'), zlib = require('node:zlib');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const source = path.resolve(__dirname, '../entry/src/main/ets');
const fixture = path.resolve(__dirname, '../.hvigor/file-attachments-' + crypto.randomUUID());
fs.mkdirSync(fixture, { recursive: true });
const disk = value => value.startsWith('file://') ? disk(value.slice(7)) : value.startsWith('/sandbox/') ? path.join(fixture, value.slice(9)) : value;
const handles = new Map(), cache = new Map();
let copyFailure = false, pdfReads = 0, pdfPages = [], jsReads = 0;
let selectedUris = [], sharedRecords = [], pickerMaximum;
const fileIo = {
  rmdir: async p => {
    const target = path.resolve(disk(p));
    assert.ok(target.startsWith(fixture + path.sep));
    await fs.promises.rm(target, { recursive: true });
  },
  OpenMode: { READ_ONLY: 1, CREATE: 2, WRITE_ONLY: 4, TRUNC: 8, NOFOLLOW: 16 },
  access: async p => fs.existsSync(disk(p)), mkdir: (p, recursive = false) => fs.promises.mkdir(disk(p), { recursive }),
  lstat: async p => { try { return await fs.promises.lstat(disk(p)); } catch (error) { if (error.code === 'ENOENT') error.code = 13900002; throw error; } },
  stat: p => typeof p === 'number' ? handles.get(p).stat() : fs.promises.stat(disk(p)),
  open: async (p, flags) => { const handle = await fs.promises.open(disk(p), flags & 4 ? 'w' : 'r'); handles.set(handle.fd, handle); return { fd: handle.fd }; },
  close: async file => { const fd = typeof file === 'number' ? file : file.fd; const handle = handles.get(fd); handles.delete(fd); await handle.close(); },
  read: async (fd, bytes) => { jsReads++; return (await handles.get(fd).read(new Uint8Array(bytes))).bytesRead; },
  write: async (fd, bytes, options) => (await handles.get(fd).write(new Uint8Array(bytes), 0, bytes.byteLength, options.offset)).bytesWritten,
  fsync: fd => handles.get(fd).sync(), unlink: p => fs.promises.unlink(disk(p)),
  listFile: p => fs.promises.readdir(disk(p)), rename: (a, b) => fs.promises.rename(disk(a), disk(b)),
  copyFile: async (input, output) => {
    const buffer = new Uint8Array(64 * 1024);
    while (true) {
      const { bytesRead } = await handles.get(input).read(buffer); if (!bytesRead) break;
      await handles.get(output).write(buffer.subarray(0, bytesRead));
      if (copyFailure) throw Error('injected copy failure');
    }
  }
};
const kits = {
  '@kit.AssetStoreKit': { asset: {} },
  '@kit.ArkData': {
    uniformTypeDescriptor: { getTypeDescriptor: type => ({ belongsTo: parent => type === parent ||
      (parent === 'general.image' && ['general.jpeg', 'general.png', 'general.heic'].includes(type)) }) },
    unifiedDataChannel: { ProgressIndicator: { NONE: 0 }, ListenerStatus: { FINISHED: 0, PROCESSING: 1, CANCELED: 2 } }
  },
  '@kit.CoreFileKit': { fileIo, picker: { DocumentViewPicker: class {
    async select(options) { pickerMaximum = options.maxSelectNumber; return selectedUris; }
  } } },
  '@kit.MediaLibraryKit': { photoAccessHelper: { PhotoViewMIMETypes: { IMAGE_TYPE: 1 }, PhotoViewPicker: class {
    async select(options) { pickerMaximum = options.maxSelectNumber; return { photoUris: selectedUris }; }
  } } },
  '@kit.ShareKit': { systemShare: { getSharedData: async () => ({ getRecords: () => sharedRecords }) } },
  '@kit.ImageKit': { image: {
    createImageSource: () => ({ getImageInfo: async () => ({ size: { width: 16, height: 16 } }),
      createPixelMap: async () => ({ release: async () => {} }), release: async () => {} }),
    createImagePacker: () => ({ packing: async () => Uint8Array.from([255, 216, 255]).buffer, release: async () => {} })
  } }, '@kit.ArkGraphics2D': { drawing: {} },
  '@kit.ArkTS': { util: {
    generateRandomUUID: () => crypto.randomUUID(),
    TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } },
    TextDecoder: class { constructor(encoding, options) { this.decoder = new TextDecoder(encoding, options); } decodeToString(bytes, options) { return this.decoder.decode(bytes, options); } },
    Base64Helper: class { encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); } async encodeToString(bytes) { return this.encodeToStringSync(bytes); } decodeSync(text) { return Uint8Array.from(Buffer.from(text, 'base64')); } }
  } },
  '@kit.CryptoArchitectureKit': { cryptoFramework: { ...backupCrypto, createMd: () => { const hash = crypto.createHash('sha256'); return {
    update: async value => hash.update(value.data), digest: async () => ({ data: Uint8Array.from(hash.digest()) })
  }; } } },
  '@kit.BasicServicesKit': { zlib: { ReturnStatus: { STREAM_END: 1 }, CompressFlushMode: { FINISH: 4 }, createZipSync: () => {
    let size = 0; return { inflateInit2: async () => {}, inflateEnd: async () => {}, getZStream: async () => ({ totalOut: size }),
      inflate: async stream => { const bytes = zlib.inflateRawSync(Buffer.from(stream.nextIn), { maxOutputLength: stream.availableOut }); new Uint8Array(stream.nextOut).set(bytes); size = bytes.length; return 1; } };
  } } },
  '@kit.PDFKit': { pdfService: { PdfDocument: class {
    loadDocument(p) { assert.equal(fs.readFileSync(disk(p)).subarray(0, 4).toString(), '%PDF'); pdfReads++; }
    getPageCount() { return pdfPages.length; } getPage(i) { return { getTextContent: () => pdfPages[i], release() {} }; }
    releaseDocument() {}
  } } }
};
const t = (text, values = []) => text.replace(/\{(\d+)\}/g, (_, i) => String(values[i]));
function mock(name, value) { cache.set(path.join(source, name + '.ets'), value); }
mock('model/I18n', { t }); mock('model/Diagnostics', { Diagnostics: { acceptsLog: () => false, log() {}, begin: () => 0, end() {} } });
mock('common/ApiLevel', { ApiLevel: { pdfTextContent: true } });
mock('services/ProjectFolderAccess', { ProjectFolderAccess: { activate: async () => {} } });
mock('services/NativeActions', { exportFile: async () => {} });
function compile(text) { return ts.transpileModule(text, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS, experimentalDecorators: true } }).outputText; }
function load(name) {
  const file = path.resolve(source, name.endsWith('.ets') ? name : name + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  vm.runInNewContext(compile(fs.readFileSync(file, 'utf8')), { exports, ArrayBuffer, Uint8Array, DataView, Error, Map, Set, console,
    setTimeout, clearTimeout, Observed: cls => cls,
    require: id => id === './HuaweiAccount' ? { huaweiAccount: backupAccount } : id.startsWith('.') ? load(path.resolve(path.dirname(file), id)) : assert.ok(id in kits, id) || kits[id]
  }, { filename: file });
  return exports;
}
function zip(parts) {
  const local = [], central = []; let offset = 0;
  for (const [name, text] of Object.entries(parts)) {
    const filename = Buffer.from(name), raw = Buffer.from(text), packed = zlib.deflateRawSync(raw);
    const header = Buffer.alloc(30); header.writeUInt32LE(0x04034b50); header.writeUInt16LE(8, 8);
    header.writeUInt32LE(packed.length, 18); header.writeUInt32LE(raw.length, 22); header.writeUInt16LE(filename.length, 26);
    const directory = Buffer.alloc(46); directory.writeUInt32LE(0x02014b50); directory.writeUInt16LE(8, 10);
    directory.writeUInt32LE(packed.length, 20); directory.writeUInt32LE(raw.length, 24); directory.writeUInt16LE(filename.length, 28); directory.writeUInt32LE(offset, 42);
    local.push(header, filename, packed); central.push(directory, filename); offset += header.length + filename.length + packed.length;
  }
  const directory = Buffer.concat(central), end = Buffer.alloc(22), count = Object.keys(parts).length;
  end.writeUInt32LE(0x06054b50); end.writeUInt16LE(count, 8); end.writeUInt16LE(count, 10);
  end.writeUInt32LE(directory.length, 12); end.writeUInt32LE(offset, 16);
  return Buffer.concat([...local, directory, end]);
}
const { Attachments } = load('services/Attachments'), { WorkspaceStore } = load('model/WorkspaceStore');
const { NativeWorkspaceFiles } = load('services/NativeWorkspaceFiles'), { WorkspaceTools } = load('services/WorkspaceTools');
const { Cancellation } = load('services/Cancellation'), { validateAttachments } = load('model/Productivity');
const { emptyData } = load('model/Conversation');
const root = '/sandbox/app', workspace = new WorkspaceStore(root);
const files = id => new NativeWorkspaceFiles(workspace.pathFor(id));
const tools = id => new WorkspaceTools(files(id));
const invoke = (toolset, name, args) => toolset.execute({ id: 'call', function: { name, arguments: JSON.stringify(args) } }, new Cancellation());
async function attach(name, bytes, id = 'chat') {
  const uri = root + '/' + name; fs.writeFileSync(disk(uri), bytes);
  const staged = await Attachments.import(uri, false);
  await workspace.ensureThread(id);
  return (await Attachments.inWorkspace([staged], id))[0];
}
async function main() {
  fs.mkdirSync(disk(root + '/cache'), { recursive: true }); Attachments.configure(root);
  const raw = Buffer.from('\uFEFFalpha\r\n中文🙂\r\nEND');
  const item = await attach('资料.txt', raw);
  assert.deepEqual(fs.readFileSync(disk(Attachments.path(item))), raw);
  assert.equal(item.text, undefined); assert.equal(item.workspaceId, 'chat');
  fs.unlinkSync(disk(root + '/资料.txt'));
  const hydrated = (await Attachments.hydrate([{ role: 'user', content: 'read', attachments: [item] }]))[0];
  assert.ok(hydrated.content.includes(item.path)); assert.ok(!hydrated.content.includes('alpha'));
  assert.equal(JSON.parse(await invoke(tools('chat'), 'read_file', { path: item.path })).content, 'alpha\r\n中文🙂\r\nEND');
  await assert.rejects(invoke(tools('chat'), 'write_file', { path: item.path, content: 'overwrite' }), /Original attachments/);
  const duplicate = await attach('资料.txt', 'different'); assert.notEqual(duplicate.path, item.path);
  assert.deepEqual(fs.readFileSync(disk(Attachments.path(item))), raw);
  await workspace.ensureThread('branch');
  const branchItem = (await Attachments.inWorkspace([item], 'branch'))[0];
  assert.equal(branchItem.path, item.path); assert.deepEqual(fs.readFileSync(disk(Attachments.path(branchItem))), raw);
  assert.equal((await Attachments.inWorkspace([item], 'branch'))[0].workspaceId, 'branch');
  for (const patch of [{ path: '../escape' }, { name: '../escape' }, { workspaceId: '../escape' }, { text: 'inline' }]) {
    assert.throws(() => validateAttachments([{ ...item, ...patch }]));
  }
  console.log('PASS byte-preserving imports, path-only model input, same-name files, branch copies and write protection');

  const documents = [
    ['report.docx', { 'word/document.xml': '<w:document><w:p><w:t>' + 'x'.repeat(40000) + 'END_DOC</w:t></w:p></w:document>' }, 'END_DOC'],
    ['slides.pptx', { 'ppt/slides/slide1.xml': '<a:p><a:t>Slide one</a:t></a:p>', 'ppt/slides/slide2.xml': '<a:p><a:t>Slide two</a:t></a:p>' }, 'Slide two'],
    ['table.xlsx', { 'xl/sharedStrings.xml': '<sst><si><t>Revenue</t></si></sst>', 'xl/worksheets/sheet1.xml': '<worksheet><row><c r="A1" t="s"><v>0</v></c><c r="B1"><v>42</v></c></row></worksheet>' }, 'B1: 42']
  ];
  for (const [name, parts, expected] of documents) {
    const bytes = zip(parts), doc = await attach(name, bytes); let offset = 1, column = 1, joined = '';
    while (true) {
      const page = JSON.parse(await invoke(tools('chat'), 'read_file', { path: doc.path, offset, column, maxBytes: 1024 }));
      joined += page.content; if (!page.truncated) break;
      offset = page.nextOffset; column = page.nextColumn;
    }
    assert.ok(joined.includes(expected)); assert.deepEqual(fs.readFileSync(disk(Attachments.path(doc))), bytes);
  }
  pdfPages = Array.from({ length: 105 }, (_, index) => 'page-' + (index + 1) + '-' + 'x'.repeat(400));
  const pdf = await attach('paper.pdf', '%PDF fixture'); assert.equal(pdfReads, 0);
  const pdfText = JSON.parse(await invoke(tools('chat'), 'read_file', { path: pdf.path, maxBytes: 100000 })).content;
  assert.ok(pdfText.includes('page-105')); assert.ok(pdfText.length > 31000); assert.equal(pdfReads, 1);
  assert.ok(!fs.readdirSync(disk(workspace.pathFor('chat'))).some(name => name.startsWith('.tinybot-pdf-')));
  pdfPages = ['']; await assert.rejects(invoke(tools('chat'), 'read_file', { path: pdf.path }), /没有可提取的文字/);
  const broken = await attach('broken.docx', 'not a zip'); await assert.rejects(invoke(tools('chat'), 'read_file', { path: broken.path }));
  const binary = await attach('binary.dat', Buffer.from([0xff, 0, 0xfe])); await assert.rejects(invoke(tools('chat'), 'read_file', { path: binary.path }));
  copyFailure = true; await assert.rejects(attach('failure.bin', 'partial'), /injected copy failure/); copyFailure = false;
  assert.equal(handles.size, 0);
  console.log('PASS lazy PDF/Office extraction, pagination past old cutoffs, scan/invalid-file errors and copy failure cleanup');

  const largeId = 'large-documents';
  const largePdfBytes = Buffer.concat([Buffer.from('%PDF fixture'), Buffer.alloc(9 * 1024 * 1024)]);
  const largePdf = await attach('large.pdf', largePdfBytes, largeId); pdfPages = ['large PDF text'];
  const previousReads = jsReads;
  assert.equal(JSON.parse(await invoke(tools(largeId), 'read_file', { path: largePdf.path })).content.trim(), '[第 1 页]\nlarge PDF text');
  assert.equal(jsReads, previousReads, 'PDF source bytes use native copying without a JS full-file read');
  const archive = zip({ 'word/document.xml': '<w:p><w:t>Large archive text</w:t></w:p>', 'word/media/photo.bin': crypto.randomBytes(9 * 1024 * 1024) });
  assert.ok(archive.length > 8 * 1024 * 1024);
  const largeDoc = await attach('large.docx', archive, largeId);
  assert.match(JSON.parse(await invoke(tools(largeId), 'read_file', { path: largeDoc.path })).content, /Large archive text/);
  const expandedParts = {};
  for (let index = 1; index <= 4; index++) expandedParts['ppt/slides/slide' + index + '.xml'] = '<a:p><a:t>' + 'x'.repeat(2 * 1024 * 1024 + 40) + 'END_' + index + '</a:t></a:p>';
  const expanded = await attach('large-text.pptx', zip(expandedParts), largeId);
  const expandedText = JSON.parse(await invoke(tools(largeId), 'read_file', { path: expanded.path, maxBytes: 12 * 1024 * 1024 }));
  assert.ok(expandedText.content.length > 8 * 1024 * 1024); assert.match(expandedText.content, /END_4/); assert.equal(expandedText.truncated, false);
  const manyParts = { 'word/document.xml': '<w:p><w:t>Many entries</w:t></w:p>' };
  for (let index = 0; index < 3001; index++) manyParts['word/media/' + index + '.bin'] = 'x';
  const manyDoc = await attach('many-parts.docx', zip(manyParts), largeId);
  assert.match(JSON.parse(await invoke(tools(largeId), 'read_file', { path: manyDoc.path })).content, /Many entries/);
  assert.equal(handles.size, 0);
  console.log('PASS PDF/Office above 8 MiB, XML above 2 MiB, extracted text above 8 MiB and archives above 3000 entries');

  const { createBackupFile, readBackupFile } = load('services/Backup');
  const data = emptyData(); data.activeThreadId = 'chat';
  data.threads = [{ id: 'chat', title: 'Files', updatedAt: 1, messages: [], attachments: [item, pdf] },
    { id: 'branch', title: 'Branch', updatedAt: 1, messages: [], attachments: [branchItem] }];
  const context = { cacheDir: root + '/cache', getApplicationContext: () => ({ filesDir: root }) };
  const backup = await createBackupFile(context, data), envelope = legacyBackupFixture(fs.readFileSync(disk(backup)));
  assert.equal(envelope.attachments.length, 2); assert.ok(!envelope.files.some(file => file.path === item.path));
  const restoredRoot = '/sandbox/restored'; fs.mkdirSync(disk(restoredRoot + '/cache'), { recursive: true });
  const restoredContext = { cacheDir: restoredRoot + '/cache', getApplicationContext: () => ({ filesDir: restoredRoot }) };
  Attachments.configure(restoredRoot);
  const restored = await readBackupFile(restoredContext, backup, emptyData());
  for (const thread of restored.threads) {
    assert.equal(thread.attachments[0].workspaceId, thread.id);
    assert.deepEqual(fs.readFileSync(disk(Attachments.path(thread.attachments[0]))), raw);
  }
  assert.equal((await readBackupFile(restoredContext, backup, restored)).threads.length, 0);
  console.log('PASS backup stores original bytes once, restores each branch path and skips already-restored chats');

  const legacy = { id: 'legacy', name: 'old.txt', path: 'legacy.txt', mime: 'text/plain', size: 3, text: 'old' };
  validateAttachments([legacy]);
  const legacyTools = new (load('services/AttachmentTools').AttachmentTools)([legacy]);
  assert.equal(JSON.parse(await invoke(legacyTools, 'read_attachment', { id: 'legacy' })).content, 'old');
  const photo = { id: 'photo', name: 'photo.jpg', path: 'photo.jpg', mime: 'image/jpeg', size: 3 };
  fs.writeFileSync(disk(restoredRoot + '/attachments/photo.jpg'), Buffer.from([255, 216, 255]));
  assert.equal((await Attachments.hydrate([{ role: 'user', content: '', attachments: [photo] }]))[0].images[0], 'data:image/jpeg;base64,/9j/');
  assert.equal(handles.size, 0);
  console.log('PASS historical text attachments and image model input remain readable');

  // Exercise the actual session admission/fork lifecycle; provider generation is not used here.
  Attachments.configure(root);
  const { SessionService } = load('services/SessionService');
  let saved = emptyData(); saved.activeThreadId = 'session';
  saved.threads = [{ id: 'session', title: 'Session', updatedAt: 1, messages: [], attachments: [] }];
  const repository = { load: async () => JSON.parse(JSON.stringify(saved)), save: async value => { saved = JSON.parse(JSON.stringify(value)); } };
  const resources = {
    createId: () => crypto.randomUUID(), configureProviders() {}, reportError() {},
    ensureWorkspace: (id, workspaceId) => workspace.ensureThread(workspaceId || id),
    prepareAttachments: async (items, id, workspaceId) => { await workspace.ensureThread(workspaceId || id); return Attachments.inWorkspace(items, workspaceId || id); }
  };
  const runtime = { fork() { return this; } };
  const session = new SessionService(repository, runtime, {}, resources);
  session.refreshContext = () => {}; // Model projection itself is verified above against Attachments.hydrate.
  await session.initialize();
  fs.writeFileSync(disk(root + '/session.txt'), 'session document');
  const pending = await Attachments.import(root + '/session.txt', false);
  assert.equal(await session.setAttachments([pending]), true);
  assert.equal(saved.threads[0].attachments[0].workspaceId, 'session');
  const beforeFailure = JSON.stringify(saved);
  const rejected = await Attachments.import(root + '/session.txt', false);
  copyFailure = true; assert.equal(await session.setAttachments([rejected]), false); copyFailure = false;
  assert.equal(JSON.stringify(saved), beforeFailure, 'A failed copy never becomes a persisted attachment');
  const committed = saved.threads[0].attachments[0];
  const history = session.snapshot();
  history.threads[0].messages = [{ id: 'user', role: 'user', content: 'Read', status: 'complete', error: '', attachments: [committed] },
    { id: 'answer', role: 'assistant', content: 'Done', status: 'complete', error: '' }];
  saved = history;
  const reopened = new SessionService(repository, runtime, {}, resources); reopened.refreshContext = () => {};
  await reopened.initialize(); assert.equal(await reopened.forkThread('answer'), true);
  const fork = saved.threads.find(thread => thread.id === saved.activeThreadId), copied = fork.messages[0].attachments[0];
  assert.equal(copied.workspaceId, fork.id); assert.equal(copied.path, committed.path);
  assert.equal(fs.readFileSync(disk(Attachments.path(copied)), 'utf8'), 'session document');
  console.log('PASS session commits only prepared files, retains drafts on copy failure and copies historical files into forks');

  const projectItem = await attach('project.xlsx', zip({ 'xl/worksheets/sheet1.xml': '<worksheet><c r="A1"><v>42</v></c></worksheet>' }), 'project-original');
  const projectData = emptyData(); projectData.activeThreadId = 'project-chat';
  projectData.projects = [{ id: 'project', workspaceId: 'project-original', name: 'Project', instructions: '', createdAt: 1, updatedAt: 1 }];
  projectData.threads = [{ id: 'project-chat', projectId: 'project', title: 'Project', updatedAt: 1, messages: [], attachments: [projectItem] }];
  const projectBackup = await createBackupFile(context, projectData);
  Attachments.configure(restoredRoot);
  const restoredProject = await readBackupFile(restoredContext, projectBackup, emptyData());
  const projectCopy = restoredProject.threads[0].attachments[0];
  assert.notEqual(projectCopy.workspaceId, 'project-original');
  assert.equal(projectCopy.workspaceId, restoredProject.projects[0].workspaceId);
  assert.equal(projectCopy.path, projectItem.path);
  assert.deepEqual(fs.readFileSync(disk(Attachments.path(projectCopy))), fs.readFileSync(disk(root + '/project.xlsx')));
  const existingProject = emptyData(); existingProject.projects = [{ ...projectData.projects[0], workspaceId: 'project-existing' }];
  await new WorkspaceStore(restoredRoot).ensureThread('project-existing');
  const intoExisting = await readBackupFile(restoredContext, projectBackup, existingProject);
  assert.equal(intoExisting.threads[0].attachments[0].workspaceId, 'project-existing');
  assert.ok(fs.existsSync(disk(Attachments.path(intoExisting.threads[0].attachments[0]))));
  assert.equal(handles.size, 0);
  console.log('PASS original attachments restore into fresh and existing project workspaces');

  // Exercise real selection, import, session persistence and model hydration at the shared limit.
  {
  cache.delete(path.join(source, 'services/NativeActions.ets'));
  const { selectAttachments, ShareInbox } = load('services/NativeActions');
  const { MAX_MESSAGE_ATTACHMENTS } = load('model/Productivity');
  Attachments.configure(root);
  selectedUris = Array.from({ length: 10 }, (_, index) => {
    const uri = root + '/selected-' + index + '.jpg'; fs.writeFileSync(disk(uri), Buffer.from([255, 216, 255])); return uri;
  });
  const photos = await selectAttachments({}, true, MAX_MESSAGE_ATTACHMENTS);
  assert.equal(pickerMaximum, 10); assert.equal(photos.length, 10); validateAttachments(photos);
  assert.equal(await reopened.setAttachments(photos), true);
  assert.equal(load('model/Conversation').parseAppData(JSON.stringify(saved)).threads.find(t => t.id === saved.activeThreadId).attachments.length, 10);
  assert.equal((await Attachments.hydrate([{ role: 'user', content: '', attachments: photos }]))[0].images.length, 10);
  const beforeOverflow = JSON.stringify(saved);
  assert.equal(await reopened.setAttachments(photos.concat([{ ...photos[0], id: 'eleventh', path: 'eleventh.jpg' }])), false);
  assert.match(reopened.state.error, /10/); assert.equal(JSON.stringify(saved), beforeOverflow);
  selectedUris = Array(10).fill(root + '/session.txt');
  const documents = await selectAttachments({}, false, MAX_MESSAGE_ATTACHMENTS);
  assert.equal(pickerMaximum, 10); assert.equal(documents.length, 10);
  assert.equal(await reopened.setAttachments(documents), true);
  assert.equal(await reopened.setAttachments(documents.slice(0, 5).concat(photos.slice(0, 5))), true);
  await assert.rejects(selectAttachments({}, false, 0), /10/);
  console.log('PASS ten images, ten files and mixed attachments persist and reload; ten images reach model input and an eleventh cannot replace the draft');

  for (const photo of [false, true]) {
    sharedRecords = Array.from({ length: 10 }, (_, index) => ({ utd: photo ? 'general.image' : 'general.text',
      uri: 'file://' + root + (photo ? '/selected-' + index + '.jpg' : '/session.txt') }));
    await ShareInbox.receive({ action: 'ohos.want.action.sendData' }, root);
    const received = ShareInbox.take(); assert.equal(received.error, ''); assert.equal(received.attachments.length, 10);
    validateAttachments(received.attachments);
  }
  sharedRecords.push(sharedRecords[0]);
  await ShareInbox.receive({ action: 'ohos.want.action.sendData' }, root);
  const overflow = ShareInbox.take(); assert.match(overflow.error, /10/); assert.equal(overflow.attachments.length, 0);
  const manifest = fs.readFileSync(path.resolve(source, '../module.json5'), 'utf8');
  const limits = [...manifest.matchAll(/"maxFileSupported":\s*(\d+)/g)].map(match => Number(match[1]));
  assert.equal(limits.length, 7); assert.ok(limits.every(limit => limit === MAX_MESSAGE_ATTACHMENTS));
  assert.equal(handles.size, 0);
  console.log('PASS system share accepts ten images/files, rejects eleven before importing, and all declared share types match the limit');

  const { AttachmentDrop, droppedFiles, importDroppedAttachments } = load('services/AttachmentDrop');
  const record = (uri, type = 'general.file') => ({ getTypes: () => ['general.file-uri', type],
    getType: () => type, getEntry: () => ({ oriUri: uri, fileType: type }) });
  const dragData = records => ({ getRecords: () => records });
  const uri = 'file://' + root + '/session.txt', photoUri = 'file://' + root + '/selected-0.jpg';
  const mixed = dragData([record(uri), record(photoUri, 'general.jpeg'), record(uri)]);
  assert.equal(droppedFiles(mixed, 2).length, 2);
  assert.throws(() => droppedFiles(mixed, 1), /10/);
  assert.throws(() => droppedFiles(dragData([]), 10), /没有收到/);
  assert.throws(() => droppedFiles(dragData([record('https://example.com/image.png', 'general.png')]), 10), /本地/);
  const legacyImage = { getTypes: () => ['general.image'], getType: () => 'general.image', imageUri: photoUri };
  assert.equal(droppedFiles(dragData([legacyImage]), 10)[0].photo, true);
  const bitmap = { getTypes: () => ['openharmony.pixel-map'], getType: () => 'openharmony.pixel-map' };
  assert.throws(() => droppedFiles(dragData([bitmap]), 10), /纯位图/);
  await importDroppedAttachments(mixed, 10, () => true, async items => {
    assert.equal(await reopened.setAttachments(items), true);
    assert.equal(reopened.active.attachments.length, 2);
    assert.equal(reopened.active.attachments[1].mime, 'image/jpeg');
  });
  assert.equal(load('model/Conversation').parseAppData(JSON.stringify(saved)).threads.find(t => t.id === saved.activeThreadId).attachments.length, 2);

  const originalImport = Attachments.import; const importedPaths = [];
  Attachments.import = async (...args) => { const item = await originalImport(...args); importedPaths.push(Attachments.path(item)); return item; };
  try {
    let committed = false, checks = 0;
    await assert.rejects(importDroppedAttachments(mixed, 10, () => ++checks < 2, async () => { committed = true; }), /对话已切换/);
    assert.equal(committed, false); assert.equal(fs.existsSync(disk(importedPaths.at(-1))), false);
    await assert.rejects(importDroppedAttachments(dragData([record(photoUri, 'general.jpeg'), record('file:///missing-file')]),
      10, () => true, async () => { committed = true; }), /ENOENT/);
    assert.equal(fs.existsSync(disk(importedPaths.at(-1))), false); assert.equal(committed, false);
    await assert.rejects(importDroppedAttachments(dragData([record(photoUri, 'general.jpeg')]), 10, () => true,
      async () => { throw Error('save failed'); }), /save failed/);
    assert.equal(fs.existsSync(disk(importedPaths.at(-1))), true, 'Keep adopted draft files for retry save');
  } finally { Attachments.import = originalImport; }

  let listener; const event = { startDataLoading: options => { listener = options.dataProgressListener; return 'drop-key'; } };
  const receiver = new AttachmentDrop();
  const pending = receiver.load(event);
  listener({ status: 1, progress: 25 }, null);
  listener({ status: 0, progress: 100 }, mixed);
  listener({ status: 0, progress: 100 }, dragData([]));
  assert.equal(await pending, mixed);
  const canceled = receiver.load(event); const late = listener; let canceledKey = '';
  receiver.cancel({ getDragController: () => ({ cancelDataLoading: key => { canceledKey = key; } }) });
  await assert.rejects(canceled, /对话已切换/); assert.equal(canceledKey, 'drop-key');
  late({ status: 0, progress: 100 }, mixed);
  const failed = receiver.load(event); listener({ status: 204, progress: -1 }, null);
  await assert.rejects(failed, /204/);
  await assert.rejects(receiver.load({ startDataLoading: () => { throw Error('native load failed'); } }), /native load failed/);
  console.log('PASS drag records, mixed imports and persisted drafts; overflow, unsupported data, navigation cleanup, partial failures, save retry, native cancellation and late callbacks');

  await largeBackupTest();
  await encryptedBackupTest();
  if (process.argv.includes('--ui')) {
    const panelSource = path.join(source, 'views/ChatPanel.ets');
    const emitted = path.resolve(source, '../../../build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/views/ChatPanel.ts');
    assert.ok(fs.statSync(emitted).mtimeMs >= fs.statSync(panelSource).mtimeMs, 'Rebuild ChatPanel');
    const tree = ts.createSourceFile(emitted, fs.readFileSync(emitted, 'utf8'), ts.ScriptTarget.Latest, true);
    const panel = tree.statements.find(node => ts.isClassDeclaration(node) && node.name.text === 'ChatPanel');
    const methods = ['dropEditable', 'dragAttachment', 'composerDrop', 'receiveAttachmentDrop', 'cancelAttachmentDrop'];
    const selected = panel.members.filter(member => member.name && methods.includes(member.name.getText(tree)));
    assert.equal(selected.length, methods.length);
    const exports = {}, DragResult = { DRAG_FAILED: 1, DRAG_SUCCESSFUL: 0, DROP_ENABLED: 4, DROP_DISABLED: 5 };
    vm.runInNewContext(compile('class Panel {' + selected.map(member => member.getText(tree)).join('\n') + '} exports.Panel = Panel;'),
      { exports, t, Error, Object, MAX_MESSAGE_ATTACHMENTS, DragResult, DragBehavior: { COPY: 1 }, importDroppedAttachments });
    const ui = new exports.Panel(); let commits = 0;
    Object.assign(ui, { attachmentDrop: new AttachmentDrop(), dropGeneration: 0, importing: false,
      speechActive: () => false, getUIContext: () => ({ getDragController: () => ({ cancelDataLoading() {} }) }),
      thread: { id: 'drop-chat', archived: false, attachments: [] },
      app: { ready: true, busy: false, saveError: '', error: '', active: { id: 'drop-chat' },
        setAttachments: async items => { commits++; ui.thread.attachments = items; return true; } } });
    const nativeEvent = { ...event, setResult(value) { this.result = value; } };
    ui.dragAttachment(nativeEvent); assert.equal(ui.dropHover, true);
    let run = ui.receiveAttachmentDrop(nativeEvent);
    assert.equal(ui.importing, true); assert.equal(ui.dropHover, false);
    listener({ status: 0, progress: 100 }, mixed); await run;
    assert.equal(commits, 1); assert.equal(ui.thread.attachments.length, 2); assert.equal(ui.importing, false);
    run = ui.receiveAttachmentDrop(nativeEvent); ui.app.active.id = 'other'; ui.cancelAttachmentDrop(); await run;
    assert.equal(commits, 1); assert.match(ui.app.error, /对话已切换/);
    ui.app.active.id = 'drop-chat'; ui.thread.attachments = Array(10).fill({});
    await ui.receiveAttachmentDrop(nativeEvent); assert.equal(nativeEvent.result, DragResult.DRAG_FAILED); assert.equal(commits, 1);
    ui.composerDrop({ getSummary: () => ({ summary: { 'general.plain-text': 4 } }), setResult() { assert.fail('Native text drop was intercepted'); } });
    console.log('PASS compiled ChatPanel callbacks: hover, attachment strip, current conversation, navigation cancellation, full draft and native text drop');
  }
  }
}
async function largeBackupTest() {
  const { createBackupFile, readBackupFile, exportBackup } = load('services/Backup');
  const { writeBackupArchive, openBackupArchive, cleanupBackupArchive } = load('services/BackupArchive');
  const app = '/sandbox/large-backup', target = '/sandbox/large-restored';
  fs.mkdirSync(disk(app + '/workspace/large'), { recursive: true });
  fs.mkdirSync(disk(app + '/cache'), { recursive: true });
  fs.mkdirSync(disk(target + '/cache'), { recursive: true });
  const context = { cacheDir: app + '/cache', getApplicationContext: () => ({ filesDir: app }) };
  const restoreContext = { cacheDir: target + '/cache', getApplicationContext: () => ({ filesDir: target }) };
  const sourceFile = app + '/workspace/large/payload.bin';
  const payload = crypto.randomBytes(24 * 1024 * 1024 + 17);
  fs.writeFileSync(disk(sourceFile), payload);
  fs.writeFileSync(disk(app + '/workspace/large/empty.txt'), '');
  const data = emptyData(); data.activeThreadId = 'large';
  data.threads = [{ id: 'large', title: 'Large backup', updatedAt: 1, messages: [] }];
  const originalRead = fileIo.read, originalWrite = fileIo.write;
  let maximumRead = 0, maximumWrite = 0;
  fileIo.read = async (fd, bytes) => { maximumRead = Math.max(maximumRead, bytes.byteLength); return originalRead(fd, bytes); };
  fileIo.write = async (fd, bytes, options) => { maximumWrite = Math.max(maximumWrite, bytes.byteLength); return originalWrite(fd, bytes, options); };
  try {
    const backup = await createBackupFile(context, data);
    assert.ok(backup.endsWith('.tinybot'));
    const size = fs.statSync(disk(backup)).size;
    assert.ok(size > 20 * 1024 * 1024 && size < payload.length + 4096, 'raw files have no Base64 expansion');
    const restored = await readBackupFile(restoreContext, backup, emptyData());
    assert.equal(restored.threads[0].id, 'large');
    assert.deepEqual(fs.readFileSync(disk(target + '/workspace/large/payload.bin')), payload);
    assert.equal(fs.statSync(disk(target + '/workspace/large/empty.txt')).size, 0);
    assert.ok(maximumRead <= 256 * 1024 && maximumWrite <= 256 * 1024, 'binary I/O stays bounded');
    assert.deepEqual(fs.readdirSync(disk(target + '/cache')), [], 'successful restore cleans staging');
    const picker = kits['@kit.CoreFileKit'].picker.DocumentViewPicker.prototype;
    picker.save = async options => { assert.ok(options.newFileNames[0].endsWith('.tinybot')); return [app + '/exported.tinybot']; };
    await exportBackup(context, data);
    assert.deepEqual(fs.readFileSync(disk(app + '/exported.tinybot')), fs.readFileSync(disk(backup)));
    picker.save = async () => [];
    const cacheBefore = fs.readdirSync(disk(context.cacheDir));
    await exportBackup(context, data);
    assert.deepEqual(fs.readdirSync(disk(context.cacheDir)), cacheBefore, 'cancelled export cleans its temporary archive');
    assert.ok(maximumRead <= 256 * 1024, 'export does not call the old bounded whole-file reader');

    const pristine = fs.readFileSync(disk(backup));
    const corrupt = Buffer.from(pristine); corrupt[corrupt.length - 33] ^= 1;
    const bad = app + '/cache/bad.tinybot';
    const rejected = '/sandbox/rejected-backup'; fs.mkdirSync(disk(rejected + '/cache'), { recursive: true });
    const rejectContext = { cacheDir: rejected + '/cache', getApplicationContext: () => ({ filesDir: rejected }) };
    for (const bytes of [corrupt, pristine.subarray(0, -1), Buffer.concat([pristine, Buffer.from([0])])]) {
      fs.writeFileSync(disk(bad), bytes);
      await assert.rejects(readBackupFile(rejectContext, bad, emptyData()), /不完整或已损坏/);
      assert.deepEqual(fs.readdirSync(disk(rejected)), ['cache'], 'corruption never reaches app files');
      assert.deepEqual(fs.readdirSync(disk(rejected + '/cache')), [], 'failed restore cleans staging');
    }
    const invalidIndex = Buffer.from(pristine.subarray(0, 12)); invalidIndex.writeUInt32LE(0xffffffff, 8);
    fs.writeFileSync(disk(bad), invalidIndex);
    await assert.rejects(readBackupFile(rejectContext, bad, emptyData()), /不完整或已损坏/);

    // A valid checksum does not authorize unsafe paths or invalid blob references.
    const envelope = { format: 'tinybot-harmony.backup.v3', data, attachments: [],
      files: [{ workspaceId: 'large', path: '../escape', bytes: '0' }] };
    await writeBackupArchive(bad, JSON.stringify(envelope), [app + '/workspace/large/empty.txt']);
    await assert.rejects(readBackupFile(rejectContext, bad, emptyData()), /路径/);
    envelope.files[0].path = 'valid.txt'; envelope.files[0].bytes = '1';
    await writeBackupArchive(bad, JSON.stringify(envelope), [app + '/workspace/large/empty.txt']);
    await assert.rejects(readBackupFile(rejectContext, bad, emptyData()), /备份文件无效/);
    assert.deepEqual(fs.readdirSync(disk(rejected + '/cache')), []);

    // Native APIs can return short reads/writes without an error.
    fileIo.read = async (fd, bytes) => {
      const part = new ArrayBuffer(Math.min(7, bytes.byteLength));
      const count = await originalRead(fd, part); new Uint8Array(bytes).set(new Uint8Array(part, 0, count)); return count;
    };
    fileIo.write = (fd, bytes, options) => originalWrite(fd, bytes.slice(0, 11), options);
    envelope.files[0].bytes = '0';
    await writeBackupArchive(bad, JSON.stringify(envelope), [app + '/workspace/large/empty.txt']);
    await readBackupFile(rejectContext, bad, emptyData());
    fileIo.read = originalRead;
    fileIo.write = async () => { throw Error('injected backup disk full'); };
    const failed = app + '/cache/failed.tinybot';
    await assert.rejects(writeBackupArchive(failed, JSON.stringify(envelope), [sourceFile]), /disk full/);
    assert.equal(fs.existsSync(disk(failed)), false, 'failed writes never leave a completed backup');
    fileIo.write = async () => 0;
    await assert.rejects(writeBackupArchive(failed, JSON.stringify(envelope), []), /写入未完成/);
    assert.equal(fs.existsSync(disk(failed)), false);
    fileIo.write = originalWrite;
    // These exceed the former limits using real files, not source-text assertions.
    const metadataLength = 64 * 1024 * 1024 + 1;
    await writeBackupArchive(bad, 'x'.repeat(metadataLength), []);
    const opened = await openBackupArchive(bad, context.cacheDir);
    assert.equal(opened.metadata.length, metadataLength);
    await cleanupBackupArchive(opened.directory);
    const legacyData = emptyData(); legacyData.config.userDocument = 'y'.repeat(20 * 1024 * 1024 + 1);
    fs.writeFileSync(disk(bad), JSON.stringify({ format:'tinybot-harmony.backup.v2', data:legacyData, attachments:[], files:[] }));
    const legacyRestored = await readBackupFile(restoreContext, bad, emptyData());
    assert.equal(legacyRestored.config.userDocument.length, legacyData.config.userDocument.length);
    assert.equal(handles.size, 0, 'all descriptors are released');
    console.log('PASS >20 MiB backup/export/legacy import, >64 MiB index, bounded I/O, corruption rejection and failure cleanup');
  } finally { fileIo.read = originalRead; fileIo.write = originalWrite; }
}
async function encryptedBackupTest() {
  const {createBackupFile,readBackupFile}=load('services/Backup');
  const {SessionService}=load('services/SessionService');
  const app='/sandbox/encrypted-backup';fs.mkdirSync(disk(app+'/cache'),{recursive:true});
  const context={cacheDir:app+'/cache',getApplicationContext:()=>({filesDir:app})};
  const data=emptyData();data.providerProfiles=[{id:'api',name:'My API',protocol:'chat-completions',baseUrl:'https://api.example.com/v1',
    credentialAlias:'original-alias',noApiKey:false,enabled:true,models:['model-a']}];
  data.config={...data.config,configured:true,providerId:'api',model:'model-a',baseUrl:'https://api.example.com/v1',credentialAlias:'original-alias'};
  const secret='sk-PRIVATE-DO-NOT-WRITE-PLAINTEXT',openID='fixture-openid-A';
  const stored=new Map([['original-alias',secret]]);
  const vault={read:async id=>stored.get(id)||'',write:async(id,value)=>{assert.ok(!stored.has(id));stored.set(id,value);},remove:async id=>stored.delete(id)};
  const before=JSON.stringify(data);
  const backup=await createBackupFile(context,data,vault);
  const bytes=fs.readFileSync(disk(backup));assert.ok(!bytes.includes(Buffer.from(secret)));assert.ok(!bytes.includes(Buffer.from(openID)));
  assert.ok(bytes.includes(Buffer.from('https://api.example.com/v1')),'public API configuration stays readable');
  assert.equal(JSON.stringify(data),before);
  const again=await createBackupFile(context,data,vault);
  assert.notDeepEqual(fs.readFileSync(disk(again)),bytes,'fresh salt and nonce for each backup');
  const cacheBefore=fs.readdirSync(disk(context.cacheDir));
  backupAccount.openID='';await assert.rejects(readBackupFile(context,backup,emptyData()),/请登录/);
  backupAccount.openID='fixture-openid-B';await assert.rejects(readBackupFile(context,backup,emptyData()),/账号与备份不匹配/);
  backupAccount.openID=openID;
  assert.deepEqual(fs.readdirSync(disk(context.cacheDir)),cacheBefore,'wrong account is rejected before extraction');
  const bad=legacyBackupFixture(bytes),modified=app+'/modified.json';
  bad.data.providerProfiles[0].baseUrl='https://attacker.invalid/v1';fs.writeFileSync(disk(modified),JSON.stringify(bad));
  await assert.rejects(readBackupFile(context,modified,emptyData()),/配置不一致/);
  bad.data.providerProfiles[0].baseUrl='https://api.example.com/v1';
  const ciphertext=Buffer.from(bad.protectedKeys.ciphertext,'base64');ciphertext[0]^=1;bad.protectedKeys.ciphertext=ciphertext.toString('base64');
  fs.writeFileSync(disk(modified),JSON.stringify(bad));await assert.rejects(readBackupFile(context,modified,emptyData()),/账号与备份不匹配/);
  assert.equal(stored.size,1,'read/validation alone never writes credentials');
  let saved=emptyData(),failSave=false;
  const repository={load:async()=>JSON.parse(JSON.stringify(saved)),save:async value=>{
    if(failSave)throw Error('injected backup settings failure');
    assert.ok(!JSON.stringify(value).includes(secret));saved=JSON.parse(JSON.stringify(value));
  }};
  const {ProviderRegistry}=load('services/providers/ProviderRegistry');
  const registry=new ProviderRegistry();let sent;
  const resources={createId:()=>crypto.randomUUID(),configureProviders(profiles){
    for(const item of registry.list())registry.unregister(item.id);
    for(const profile of profiles)registry.register({info:{id:profile.id,name:profile.name,protocol:profile.protocol,
      defaultBaseUrl:profile.baseUrl,defaultModel:profile.models[0],models:profile.models},
      endpoint:base=>base+'/chat/completions',async stream(request){sent=request;return {content:'restored service works',toolCalls:[]};}});
  },reportError(){},ensureWorkspace:async()=>{}};
  const session=new SessionService(repository,{fork(){return this;}},vault,resources);session.refreshContext=()=>{};await session.initialize();
  const imported=await readBackupFile(context,backup,session.snapshot());
  assert.ok(!JSON.stringify(imported).includes(secret),'AppData never contains raw keys');
  failSave=true;assert.equal(await session.importSnapshot(imported),false);assert.equal(stored.size,1,'failed commit removes new aliases');
  assert.equal(saved.providerProfiles.length,0);
  assert.equal(registry.list().length,0,'a failed restore must not expose uncommitted services');
  failSave=false;assert.equal(await session.importSnapshot(imported),true,session.state.error);
  const profile=saved.providerProfiles[0];assert.notEqual(profile.credentialAlias,'original-alias');assert.equal(stored.get(profile.credentialAlias),secret);
  assert.equal(profile.enabled,true);assert.equal(profile.noApiKey,false);assert.equal(profile.name,'My API');
  assert.equal(saved.config.configured,true);assert.equal(saved.config.model,'model-a');
  assert.equal(saved.threads.find(t=>t.id===saved.activeThreadId).modelRef.providerId,profile.id);
  const {Cancellation}=load('services/Cancellation');
  const answer=await registry.bind(session.currentConfig,vault).stream([{role:'user',content:'hello'}],[],new Cancellation(),()=>{});
  assert.equal(answer.content,'restored service works','the restored model is usable before restarting or editing settings');
  assert.equal(sent.model,'model-a');assert.equal(sent.baseUrl,'https://api.example.com/v1');assert.equal(sent.apiKey,secret);
  const existingCount=stored.size,existingAlias=profile.credentialAlias;
  stored.set(existingAlias,'LOCAL-KEY');
  const repeated=await readBackupFile(context,backup,session.snapshot());
  assert.equal(await session.importSnapshot(repeated),true,session.state.error);assert.equal(stored.size,existingCount);
  assert.equal(stored.get(existingAlias),'LOCAL-KEY','matching local services and credentials always win');
  backupAccount.openID='';await assert.rejects(createBackupFile(context,data,vault),/请登录/);backupAccount.openID=openID;
  const noKey=JSON.parse(JSON.stringify(data));noKey.providerProfiles[0].noApiKey=true;noKey.providerProfiles[0].credentialAlias='';
  const noKeyPath=await createBackupFile(context,noKey,vault);assert.equal(legacyBackupFixture(fs.readFileSync(disk(noKeyPath))).protectedKeys.version,2);
  console.log('PASS encrypted API keys, fresh nonces, no plaintext secrets, account/tamper rejection, secure-store restore, transactional rollback and local-key preservation');
}
main().catch(error => { console.error(error); process.exitCode = 1; }).finally(() => console.log('Fixtures: ' + fixture));
