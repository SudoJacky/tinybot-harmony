// Exercise the actual ArkTS parser and native feedback service with HTTP/AssetStore/preferences boundaries mocked.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets');
const t = (key, values = []) => key.replace(/\{(\d+)\}/g, (_, i) => String(values[i]));
function load(file, imports) {
  const exports = {};
  const compiled = ts.transpileModule(fs.readFileSync(path.join(root, file), 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS, experimentalDecorators: true }
  }).outputText;
  vm.runInNewContext(compiled, { exports, Error, ArrayBuffer, encodeURIComponent, Observed: value => value,
    require: id => { assert.ok(id in imports, `Unexpected import: ${id}`); return imports[id]; } });
  return exports;
}
const model = load('model/Feedback.ets', { './I18n': { t } });
const recentModel = load('model/RecentDiagnosticLog.ets', {});
const { DiagnosticsCollector } = load('model/Diagnostics.ets', { './DiagnosticLog': load('model/DiagnosticLog.ets', {}) });
const token = 'fi_' + 's'.repeat(43), id = '5c5f0c81-f428-44d5-a5ab-7acd507bd013';
const time = '2026-10-24T04:01:00.000Z';
const item = (values = {}) => ({ id, body: '建议', contact: '', createdAt: time, status: 'new', type: 'other', attachments: [], reply: null, ...values });
const identity = { schemaVersion: 1, token, identityId: id, createdAt: time };
const receipt = { schemaVersion: 1, id, createdAt: time };
const page = (items = [], cursor = null) => ({ schemaVersion: 1, items, nextCursor: cursor, counts: { new: 24, handled: 2 } });
const reply = { body: '<script>pure text</script>', updatedAt: time };
const upload = (kind = 'image') => ({ localId: kind + '-local', kind, filename: kind === 'image' ? '截图-image.jpg' : 'log-local.log',
  mimeType: kind === 'image' ? 'image/jpeg' : 'text/plain; charset=utf-8', size: 12, path: '/private/' + kind,
  state: 'pending', remoteId: '', beforeIds: [], error: '' });
const attachment = (kind = 'image') => ({ id: kind === 'image' ? 'a60dfdf2-5c0d-4639-8b95-3651d39d8354' : 'b60dfdf2-5c0d-4639-8b95-3651d39d8354',
  kind, filename: kind === 'image' ? '截图-image.webp' : 'log-local.log', mimeType: kind === 'image' ? 'image/webp' : 'text/plain; charset=utf-8', size: 12, createdAt: time });
function harness(initialToken, persisted = new Map()) {
  const diagnosticLogs = [], diagnostics = new DiagnosticsCollector();
  diagnostics.configureLogSink(data => diagnosticLogs.push(data));
  let secure = initialToken, failRead = false, failWrite = false, failFlush = false, allowed = true;
  const calls = [], events = [], responses = [];
  const disk = persisted, working = new Map(disk);
  const store = {
    getSync: (key, fallback) => working.has(key) ? working.get(key) : fallback,
    putSync: (key, value) => working.set(key, value),
    flushSync() { if (failFlush) throw Error('disk failure'); disk.clear(); for (const [k, v] of working) disk.set(k, v); }
  };
  class Vault {
    async readOptional(alias) { assert.equal(alias, 'tinybot.feedback.identity.v1'); if (failRead) throw Error('locked'); return secure; }
    async write(alias, secret) { events.push('save-token'); if (failWrite) throw Error('locked'); assert.equal(secure, undefined); secure = secret; }
  }
  let created = 0, destroyed = 0;
  // The HTTP transport itself is covered by test-compat-http.cjs. This harness pins the contract
  // FeedbackService depends on: a redirect-refusing exchange, the bearer header only on the
  // origin, a JSON body for metadata and raw bytes for attachments.
  const compat = { request: async (spec, registerAbort) => {
    created++;
    calls.push({ url: spec.url, method: spec.method, header: spec.headers, extraData: spec.body,
      expectDataType: spec.dataType === 'buffer' ? 'ARRAY_BUFFER' : 'STRING', maxRedirects: 0, usingCache: false });
    try {
      events.push(spec.url.endsWith('/identity') ? 'identity' : spec.method);
      assert.equal(spec.redirect, 'refuse', 'Feedback never follows a redirect');
      assert.equal(new URL(spec.url).origin, 'https://sudotinybot.cn');
      assert.equal(new URL(spec.url).searchParams.has('token'), false);
      assert.equal(spec.headers.Cookie, undefined); assert.equal(spec.headers.Origin, undefined);
      if (spec.method === 'POST' && !spec.url.endsWith('/attachments')) assert.equal(spec.headers['Content-Type'], 'application/json');
      if (!spec.url.endsWith('/identity')) assert.equal(spec.headers.Authorization, 'Bearer ' + secure);
      const response = responses.shift(); assert.notEqual(response, undefined, 'Unexpected request');
      if (response instanceof Error) throw response;
      const value = typeof response === 'function' ? await response() : response;
      const bytes = value.result instanceof ArrayBuffer ? value.result : new ArrayBuffer(0);
      return { status: value.responseCode, header: value.header || {}, bytes,
        text: spec.dataType === 'string' ? String(value.result) : '' };
    } finally { destroyed++; }
  } };
  const { FeedbackService } = load('services/FeedbackService.ets', {
    '../model/Diagnostics': { Diagnostics: diagnostics },
    '@kit.ArkData': { preferences: { getPreferencesSync: () => store } },
    './CompatHttp': { CompatHttp: compat },
    './CredentialStore': { CredentialStore: Vault }, './FeedbackFiles': { FeedbackFiles: {
      configure() {}, read: async () => new ArrayBuffer(12), remove: async () => {}
    } }, './HostedPrivacy': { hostedPrivacy: {
      requireConsent() { if (!allowed) throw Error('Privacy consent required'); }
    } }, '../model/I18n': { t }, '../model/Feedback': model
  });
  return {
    service: new FeedbackService(), fresh: () => new FeedbackService(), disk, events, calls, diagnosticLogs,
    enqueue(body, status = 200, header = {}) { responses.push({ result: JSON.stringify(body), responseCode: status, header }); },
    fail(error = Error('timeout')) { responses.push(error); }, defer(fn) { responses.push(fn); },
    set failRead(v) { failRead = v; }, set failWrite(v) { failWrite = v; }, set failFlush(v) { failFlush = v; },
    set allowed(v) { allowed = v; }, get token() { return secure; },
    balanced() { assert.equal(destroyed, created, 'All native HTTP handles destroyed'); assert.equal(responses.length, 0); }
  };
}
async function setup(tokenValue, disk) { const h = harness(tokenValue, disk); await h.service.initialize({}); return h; }
async function checkNativeFiles() {
  const encode = text => new TextEncoder().encode(text).buffer;
  const files = new Map([['/picked/debug.log', encode('startup\nAuthorization: Bearer secret\ncontent: private chat')], ['photo://one', new ArrayBuffer(12)]]);
  let photos = ['photo://one'], sequence = 0, pixels = 12000000, releases = 0;
  const recent = new recentModel.RecentDiagnosticLogs(() => Date.parse(time));
  recent.record({ level: 'error', module: 'network', event: 'request_failed', fields: { http: 500, errorKind: 'network' } });
  const { FeedbackFiles } = load('services/FeedbackFiles.ets', {
    '@kit.CoreFileKit': { fileIo: {
      OpenMode: { READ_ONLY: 1, NOFOLLOW: 2 }, access: async name => files.has(name), mkdir: async name => files.set(name, null),
      open: async name => { assert.ok(files.has(name)); return { fd: name }; }, close: async () => {}, unlink: async name => files.delete(name)
    }, picker: { DocumentViewPicker: class { constructor() { throw Error('Feedback must not open a log picker'); } } } },
    '@kit.MediaLibraryKit': { photoAccessHelper: { PhotoViewMIMETypes: { IMAGE_TYPE: 'image/*' }, PhotoViewPicker: class {
      async select(options) { assert.ok(options.maxSelectNumber <= 3); return { photoUris: photos }; }
    } } },
    '@kit.ImageKit': { image: {
      createImageSource: () => ({ getImageInfo: async () => ({ size: { width: pixels, height: 1 } }),
        createPixelMap: async () => ({ release: async () => releases++ }), release: async () => releases++ }),
      createImagePacker: () => ({ packing: async (_, options) => { assert.equal(options.format, 'image/jpeg'); return new ArrayBuffer(12); }, release: async () => releases++ })
    } },
    '@kit.ArkTS': { util: { generateRandomUUID: () => `00000000-0000-0000-0000-${String(++sequence).padStart(12, '0')}`,
      TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } },
      TextDecoder: class { constructor(encoding, options) { this.decoder = new TextDecoder(encoding, options); } decodeToString(bytes) { return this.decoder.decode(bytes); } }
    } },
    './Attachments': {
      readBounded: async (fd, max) => { const bytes = files.get(fd); if (bytes.byteLength > max) throw Error('too large'); return bytes; },
      writeBytes: async (name, bytes) => { files.set(name, bytes); }
    }, '../model/Feedback': model, '../model/I18n': { t }, '../model/RecentDiagnosticLog': recentModel,
    './NativeDiagnosticLog': { recentDiagnosticLogs: () => recent.snapshot() },
    './AppInformation': { readAppInformation: () => ({ versionName: '1.0.5', versionCode: 1000005 }) }
  });
  FeedbackFiles.configure({ filesDir: '/private' });
  const review = FeedbackFiles.collectLog(); assert.ok(review.includes('request_failed')); assert.ok(!review.includes('secret')); assert.ok(!review.includes('private chat'));
  assert.equal(JSON.parse(review.split('\n')[0]).recordCount, 1);
  assert.equal([...files.keys()].filter(name => name.startsWith('/private/')).length, 0, 'Formatting recent logs does not write files until saved by the opt-in handler');
  const log = await FeedbackFiles.saveLog(review); const bytes = await FeedbackFiles.read(log);
  assert.ok(!new TextDecoder().decode(bytes).includes('secret')); assert.equal(log.mimeType, 'text/plain; charset=utf-8');
  const images = await FeedbackFiles.pickImages(3); assert.equal(images.length, 1); assert.equal(images[0].mimeType, 'image/jpeg'); assert.equal(releases, 3);
  pixels = 24000001; await assert.rejects(() => FeedbackFiles.pickImages(1)); assert.equal(releases, 4, 'Release image source on pixel-limit failure');
  await assert.rejects(() => FeedbackFiles.saveLog('x'.repeat(2 * 1024 * 1024 + 1)));
  await assert.rejects(() => FeedbackFiles.read({ ...log, path: '/outside/file' }));
  await assert.rejects(() => FeedbackFiles.remove('/private/feedback-files/../file'));
  await FeedbackFiles.remove(log.path); assert.equal(files.has(log.path), false);
  console.log('PASS native feedback files: automatic recent log preparation without a file picker, size/pixel bounds, private copies and image cleanup');
}
async function checkUi() {
  const file = path.join(root, '../../../build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/views/FeedbackPanel.ts');
  assert.ok(fs.statSync(file).mtimeMs >= fs.statSync(path.join(root, 'views/FeedbackPanel.ets')).mtimeMs, 'Build FeedbackPanel before --ui checks');
  const tree = ts.createSourceFile(file, fs.readFileSync(file, 'utf8'), ts.ScriptTarget.Latest, true);
  const component = tree.statements.find(node => ts.isClassDeclaration(node) && node.name.text === 'FeedbackPanel');
  const names = ['aboutToAppear', 'aboutToDisappear', 'start', 'showHistory', 'submit', 'open', 'confirmRetry', 'context', 'cleanPreview',
    'setLogAttached', 'locked', 'draftLocked'];
  const exports = {};
  const code = 'class Page {\n' + component.members.filter(node => names.includes(node.name?.getText(tree))).map(node => node.getText(tree)).join('\n') + '\n} exports.Page = Page;';
  vm.runInNewContext(ts.transpileModule(code, { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText, { exports, t,
    FeedbackFiles: { collectLog: () => 'redacted log for review', saveLog: async () => upload('log'), remove: async () => {} } });
  const h = await setup(token), dialogs = [];
  const panel = Object.assign(new exports.Page(), { service: h.service, history: false, visible: true, appearance: {},
    getUIContext: () => ({ getHostContext: () => ({}), getFocusController: () => ({ clearFocus() {} }), showAlertDialog: dialog => dialogs.push(dialog) }) });
  h.service.body = 'UI submit'; h.enqueue(receipt, 201); h.enqueue(page([item()]));
  await panel.submit(); assert.equal(panel.history, true); assert.equal(h.service.items.length, 1);
  h.enqueue({ schemaVersion: 1, feedback: item({ reply }) }); await panel.open(id);
  assert.equal(h.service.hasNewReply(h.service.detail), false, 'Visible detail marks reply read');
  const editedReply = { ...reply, updatedAt: '2026-10-24T06:01:00.000Z' }; let finish;
  h.defer(() => new Promise(resolve => { finish = resolve; }));
  const inflight = panel.open(id); panel.aboutToDisappear();
  finish({ responseCode: 200, result: JSON.stringify({ schemaVersion: 1, feedback: item({ reply: editedReply }) }), header: {} });
  await inflight; assert.equal(h.service.hasNewReply(h.service.detail), true, 'Leaving during fetch must not consume an unseen reply');
  h.service.body = 'timed out'; h.fail(); await h.service.submit();
  panel.confirmRetry(); assert.equal(h.service.uncertain, true, 'Opening confirmation cannot enable a retry');
  dialogs.at(-1).primaryButton.action(); assert.equal(h.service.uncertain, true, 'Cancel keeps duplicate guard');
  dialogs.at(-1).secondaryButton.action(); assert.equal(h.service.uncertain, false); assert.equal(panel.history, false);
  assert.equal(h.service.body, 'timed out'); h.balanced();
  panel.visible = true; panel.fileBusy = false;
  await panel.setLogAttached(false); assert.equal(h.service.uploads.length, 0, 'Logs are not attached by default');
  await panel.setLogAttached(true); assert.equal(h.service.uploads.length, 1); assert.equal(h.service.uploads[0].kind, 'log');
  assert.equal(dialogs.length, 1, 'Checking logs must not add a confirmation or review dialog');
  await panel.setLogAttached(true); assert.equal(h.service.uploads.length, 1, 'Programmatic checked-state synchronization cannot toggle the attachment off');
  await panel.setLogAttached(false); assert.equal(h.service.uploads.length, 0, 'Unchecking removes the prepared attachment');
  assert.ok(!component.members.some(node => ['logReview', 'confirmLog', 'pickLog'].includes(node.name?.getText(tree))), 'No log review or file-picker flow remains');
  console.log('PASS emitted feedback callbacks: direct opt-in recent logs, state synchronization, unchecking cleanup, no review dialog, history and visible reply reads');
}
async function main() {
  let clock = Date.parse(time);
  const buffer = new recentModel.RecentDiagnosticLogs(() => clock);
  const entry = count => ({ level: 'warn', module: 'diagnostics', event: 'marker', fields: { count } });
  buffer.record(entry(-1)); clock += 15 * 60 * 1000 + 1; buffer.record(entry(0));
  assert.equal(buffer.snapshot().records.length, 1, 'Only the most recent 15 minutes are retained');
  for (let index = 1; index <= 1100; index++) buffer.record(entry(index));
  let recent = buffer.snapshot(); assert.equal(recent.records.length, 1000); assert.equal(recent.records[0].data.fields.count, 101);
  assert.equal(recent.overwritten, 101);
  recent.records[0].data.fields.count = 'mutated'; assert.equal(buffer.snapshot().records[0].data.fields.count, 101, 'Snapshots cannot mutate retained data');
  const packaged = recentModel.formatFeedbackLog(buffer.snapshot(), { versionName: '1.0.5', versionCode: 1000005 });
  assert.equal(JSON.parse(packaged.split('\n')[0]).scope, 'current-process'); assert.ok(Buffer.byteLength(packaged) < 2 * 1024 * 1024);
  assert.equal(JSON.parse(packaged.trim().split('\n').at(-1)).data.fields.count, 1100);
  const large = buffer.snapshot(); large.records = Array.from({ length: 1000 }, (_, index) => ({ timestamp: time, data: { ...entry(index), fields: { count: index, text: '大'.repeat(2000) } } }));
  const bounded = recentModel.formatFeedbackLog(large, { versionName: '1.0.5', versionCode: 1000005 });
  assert.ok(Buffer.byteLength(bounded) < 2 * 1024 * 1024); assert.ok(JSON.parse(bounded.split('\n')[0]).omittedForSize > 0);
  assert.equal(JSON.parse(bounded.trim().split('\n').at(-1)).data.fields.count, 999, 'Size limits keep the newest records');
  buffer.clear(); assert.equal(buffer.snapshot().records.length, 0);
  assert.equal(model.feedbackInput('  🙂  ', ' a ').body.length, 2);
  assert.equal(model.feedbackInput('🙂'.repeat(2500), '').body.length, 5000);
  for (const [body, contact] of [[' ', ''], ['🙂'.repeat(2501), ''], ['ok', '🙂'.repeat(101)]]) assert.throws(() => model.feedbackInput(body, contact));
  for (const source of ['null', '{', '{}', JSON.stringify({ ...identity, token: 'fi_invalid' })]) assert.throws(() => model.parseFeedbackIdentity(source));
  for (const value of [page([item({ status: 'read' })]), page([item({ reply: {} })]), page([item({ createdAt: 'yesterday' })]), page([], 123), { ...page(), counts: { new: -1, handled: 0 } }]) {
    assert.throws(() => model.parseFeedbackPage(JSON.stringify(value)));
  }
  assert.equal(model.parseFeedbackDetail(JSON.stringify({ schemaVersion: 1, feedback: item({ reply }) })).reply.body, reply.body);
  assert.throws(() => model.feedbackInput('ok', '', 'invalid'));
  assert.throws(() => model.parseFeedbackPage(JSON.stringify(page([item({ type: 'invalid' })]))));
  assert.throws(() => model.parseFeedbackPage(JSON.stringify(page([item({ attachments: [attachment(), attachment(), attachment(), attachment()] })]))));
  assert.throws(() => model.parseFeedbackAttachment(JSON.stringify({ schemaVersion: 1, attachment: { ...attachment(), filename: '../bad.webp' } })));
  const redacted = model.redactFeedbackLog('Startup OK\nAuthorization: Bearer SECRET\nCookie: SID=PRIVATE\napi_key=SECRET_KEY\naccount=PRIVATE_ACCOUNT\ncontent: PRIVATE_CHAT\nuser@example.com\n13812345678\n' + token);
  assert.ok(redacted.includes('Startup OK'));
  for (const value of ['SECRET', 'PRIVATE', 'user@example.com', '13812345678', token]) assert.ok(!redacted.includes(value), value);
  assert.throws(() => model.redactFeedbackLog('bad\u0000log'));
  const longLine = 'x'.repeat(2 * 1024 * 1024);
  assert.equal(model.redactFeedbackLog(longLine), longLine, 'Large log lines without emails must not trigger unbounded email scans');
  assert.equal(model.redactFeedbackLog('x'.repeat(200000) + ' user@example.com').endsWith('[REDACTED EMAIL]'), true);

  const h = await setup(); const s = h.service;
  assert.equal(h.calls.length, 0, 'Opening feedback performs no identity creation');
  await s.load(); assert.equal(h.calls.length, 0, 'Empty installation needs no query or identity');
  s.body = '  建议  '; s.contact = ' user@example.com ';
  h.enqueue(identity, 201); h.enqueue(receipt, 201);
  assert.equal(await s.submit(), true);
  assert.deepEqual(h.events, ['identity', 'save-token', 'POST'], 'Persist identity before feedback');
  assert.deepEqual(JSON.parse(h.calls[0].extraData), { schemaVersion: 1 });
  assert.equal(h.calls[0].header.Authorization, undefined);
  assert.deepEqual(JSON.parse(h.calls[1].extraData), { schemaVersion: 1, type: 'other', body: '建议', contact: 'user@example.com' });
  assert.equal(s.body, ''); assert.equal(h.disk.get('pendingSubmission'), '');
  const restarted = h.fresh(); await restarted.initialize({}); restarted.body = 'another';
  h.enqueue(receipt, 201); assert.equal(await restarted.submit(), true);
  assert.equal(h.calls.filter(call => call.url.endsWith('/identity')).length, 1, 'Reuse persisted token after restart');

  h.enqueue(page([item({ reply })], 'opaque+/= cursor')); await s.load('handled', false, 'suggestion');
  assert.equal(s.filter, 'handled'); assert.equal(s.counts.new, 24); assert.equal(s.hasNewReply(s.items[0]), true);
  h.enqueue(page([item(), item({ id: '6c5f0c81-f428-44d5-a5ab-7acd507bd013', status: 'handled' })]));
  await s.load('handled', true);
  assert.equal(new URL(h.calls.at(-1).url).searchParams.get('before'), 'opaque+/= cursor');
  assert.equal(new URL(h.calls.at(-1).url).searchParams.get('status'), 'handled'); assert.equal(s.items.length, 2);
  assert.equal(new URL(h.calls.at(-1).url).searchParams.get('type'), 'suggestion', 'Pagination preserves both filters');
  h.enqueue({ schemaVersion: 1, feedback: item({ reply }) }); await s.open(id);
  assert.equal(s.hasNewReply(s.detail), true, 'Fetching alone must not mark an unseen reply as read');
  s.markViewed(s.detail); assert.equal(s.hasNewReply(s.detail), false);
  const readRestored = h.fresh(); await readRestored.initialize({}); assert.equal(readRestored.hasNewReply(s.detail), false);
  assert.equal(readRestored.hasNewReply(item({ reply: { ...reply, updatedAt: '2026-10-24T05:01:00.000Z' } })), true);
  assert.equal(s.detail.status, 'new', 'Reply does not imply handled');
  h.enqueue({ error: 'ignored' }, 404); await s.open(id); assert.match(s.error, /不存在/);
  h.enqueue({ error: 'ignored' }, 401); await s.load(); assert.match(s.error, /凭证无效/); assert.equal(h.token, token);
  const httpFailure = h.diagnosticLogs.findLast(data => data.event === 'request_failed');
  assert.equal(httpFailure.fields.http, 401); assert.equal(httpFailure.fields.phase, 'query');
  assert.ok(!JSON.stringify(h.diagnosticLogs).includes(token));
  h.balanced();

  const storage = await setup(); storage.service.body = '建议'; storage.failWrite = true; storage.enqueue(identity, 201);
  assert.equal(await storage.service.submit(), false); assert.equal(storage.calls.length, 1); assert.match(storage.service.error, /尚未提交/);
  storage.failWrite = false; storage.enqueue(receipt, 201); assert.equal(await storage.service.submit(), true);
  assert.equal(storage.calls.length, 2, 'Retry saving the same token rather than creating another identity'); storage.balanced();
  const locked = harness(token); locked.failRead = true; await locked.service.initialize({});
  assert.equal(locked.diagnosticLogs.at(-1).event, 'initialize_failed');
  assert.equal(locked.diagnosticLogs.at(-1).fields.phase, 'credential');
  locked.service.body = '建议'; assert.equal(await locked.service.submit(), false); assert.equal(locked.calls.length, 0);
  const corrupt = await setup('broken-token'); assert.equal(corrupt.service.ready, false); assert.equal(corrupt.calls.length, 0);
  const noDisk = await setup(token); noDisk.failFlush = true; noDisk.service.body = '建议';
  assert.equal(await noDisk.service.submit(), false); assert.equal(noDisk.calls.length, 0, 'No POST before pending record flush');

  const timeout = await setup(token); timeout.service.body = 'uncertain text';
  timeout.fail(Object.assign(Error('timeout PRIVATE_FEEDBACK_BODY'), { code: 2300056 }));
  assert.equal(await timeout.service.submit(), false); assert.equal(timeout.service.uncertain, true);
  const transportFailure = timeout.diagnosticLogs.find(data => data.event === 'request_failed');
  assert.equal(transportFailure.fields.errorCode, 2300056); assert.equal(transportFailure.fields.phase, 'submit');
  assert.ok(!JSON.stringify(timeout.diagnosticLogs).includes('PRIVATE_FEEDBACK_BODY'));
  assert.equal(timeout.service.body, 'uncertain text');
  assert.equal(await timeout.service.submit(), false); assert.equal(timeout.calls.length, 1, 'No automatic duplicate submission');
  const crash = timeout.fresh(); await crash.initialize({}); assert.equal(crash.uncertain, true); assert.equal(crash.body, 'uncertain text');
  timeout.enqueue(page([item({ body: 'uncertain text' })])); await crash.load('all');
  assert.equal(crash.items[0].body, 'uncertain text'); crash.resolveUncertain(); assert.equal(crash.uncertain, false);
  timeout.enqueue(receipt, 201); assert.equal(await crash.submit(), true); timeout.balanced();

  for (const status of [400, 401, 403, 404, 405, 413, 415, 429, 500]) {
    const failure = await setup(token); failure.service.body = 'retain draft'; failure.enqueue({ error: 'untrusted server message' }, status, { 'Retry-After': '120' });
    assert.equal(await failure.service.submit(), false); assert.equal(failure.service.uncertain, status === 500);
    assert.equal(failure.service.body, 'retain draft'); assert.equal(failure.token, token); assert.ok(!failure.service.error.includes('untrusted'));
    if (status === 429) {
      assert.match(failure.service.error, /120/); assert.equal(await failure.service.submit(), false);
      assert.equal(failure.calls.length, 1, 'Retry-After prevents transport requests');
    }
    failure.balanced();
  }
  const throttled = await setup(token); throttled.enqueue({}, 429, { 'retry-after': '120' }); await throttled.service.load();
  await throttled.service.open(id); assert.equal(throttled.calls.length, 1, 'Lists and details share a query cooldown'); throttled.balanced();
  const identityLimit = await setup(); identityLimit.service.body = 'draft'; identityLimit.enqueue({}, 429, { 'Retry-After': '3600' });
  await identityLimit.service.submit(); await identityLimit.service.submit(); assert.equal(identityLimit.calls.length, 1);
  assert.equal(identityLimit.token, undefined); identityLimit.balanced();
  const malformed = await setup(token); malformed.service.body = 'retain'; malformed.enqueue({}, 201);
  assert.equal(await malformed.service.submit(), false); assert.equal(malformed.service.uncertain, true); malformed.balanced();
  const denied = await setup(token); denied.allowed = false; denied.service.body = 'retain';
  assert.equal(await denied.service.submit(), false); await denied.service.load(); assert.equal(denied.calls.length, 0, 'Privacy consent gates network');
  const concurrent = await setup(token); concurrent.service.body = 'one'; let finish;
  concurrent.defer(() => new Promise(resolve => { finish = resolve; }));
  const pending = concurrent.service.submit(); await new Promise(resolve => setImmediate(resolve));
  assert.equal(await concurrent.service.submit(), false); await concurrent.service.load(); assert.equal(concurrent.calls.length, 1);
  finish({ responseCode: 201, result: JSON.stringify(receipt), header: {} }); assert.equal(await pending, true); concurrent.balanced();
  const uploads = await setup(token); uploads.service.body = 'with files'; uploads.service.type = 'bug';
  uploads.service.addUploads([upload(), upload('log')]);
  uploads.enqueue(receipt, 201); uploads.enqueue({ schemaVersion: 1, feedback: item({ type: 'bug' }) });
  uploads.enqueue({ schemaVersion: 1, attachment: attachment() }, 201); uploads.enqueue({ schemaVersion: 1, attachment: attachment('log') }, 201);
  assert.equal(await uploads.service.submit(), true); assert.equal(uploads.service.uploads.length, 0);
  assert.equal(JSON.parse(uploads.calls[0].extraData).type, 'bug');
  const binary = uploads.calls.filter(call => call.url.endsWith('/attachments'));
  assert.equal(binary.length, 2); assert.ok(binary.every(call => call.extraData instanceof ArrayBuffer), 'Upload raw bytes, never JSON/base64/multipart');
  assert.equal(binary[0].header['Content-Type'], 'image/jpeg'); assert.equal(binary[0].header['X-Attachment-Kind'], 'image');
  assert.equal(binary[0].header['X-File-Name'], encodeURIComponent(upload().filename));
  assert.equal(binary[1].header['Content-Type'], 'text/plain; charset=utf-8'); uploads.balanced();

  const uncertainFile = await setup(token); uncertainFile.service.body = 'with image'; uncertainFile.service.addUploads([upload()]);
  uncertainFile.enqueue(receipt, 201); uncertainFile.enqueue({ schemaVersion: 1, feedback: item() }); uncertainFile.fail();
  assert.equal(await uncertainFile.service.submit(), true, 'Attachment failure must not undo a successful text submission');
  assert.equal(uncertainFile.service.uncertain, false); assert.equal(uncertainFile.service.uploads[0].state, 'uncertain');
  assert.equal(await uncertainFile.service.submit(), false, 'A saved feedback cannot be submitted again for attachment retry');
  const restoredQueue = uncertainFile.fresh(); await restoredQueue.initialize({});
  assert.equal(restoredQueue.attachmentFeedbackId, id); assert.equal(restoredQueue.uploads[0].state, 'uncertain');
  await restoredQueue.retryUploads(); assert.equal(uncertainFile.calls.length, 3, 'Uncertain uploads require a query before any retry');
  restoredQueue.resolveUploadUncertainty(); assert.equal(restoredQueue.uploads[0].state, 'uncertain');
  uncertainFile.enqueue({ schemaVersion: 1, feedback: item({ attachments: [attachment()] }) }); await restoredQueue.reconcileUploads();
  assert.equal(restoredQueue.uploads[0].state, 'uploaded', 'Find upload saved before a lost response');
  uncertainFile.enqueue({ schemaVersion: 1, feedback: item({ attachments: [attachment()] }) }); await restoredQueue.retryUploads();
  assert.equal(restoredQueue.uploads.length, 0); assert.equal(uncertainFile.calls.filter(call => call.url.endsWith('/attachments')).length, 1);
  uncertainFile.balanced();

  const missingUpload = await setup(token); missingUpload.service.body = 'with image'; missingUpload.service.addUploads([upload()]);
  missingUpload.enqueue(receipt, 201); missingUpload.enqueue({ schemaVersion: 1, feedback: item() }); missingUpload.fail();
  await missingUpload.service.submit();
  missingUpload.enqueue({ schemaVersion: 1, feedback: item() }); await missingUpload.service.reconcileUploads();
  assert.equal(missingUpload.service.uploads[0].state, 'uncertain', 'A query alone cannot enable an automatic retry');
  missingUpload.service.resolveUploadUncertainty(); assert.equal(missingUpload.service.uploads[0].state, 'failed');
  missingUpload.enqueue({ schemaVersion: 1, feedback: item() }); missingUpload.enqueue({ schemaVersion: 1, attachment: attachment() }, 201);
  await missingUpload.service.retryUploads(); assert.equal(missingUpload.service.uploads.length, 0); missingUpload.balanced();
  for (const code of [400, 401, 404, 409, 413, 415, 429, 500, 507]) {
    const failure = await setup(token); failure.service.body = 'saved'; failure.service.addUploads([upload()]);
    failure.enqueue(receipt, 201); failure.enqueue({ schemaVersion: 1, feedback: item() }); failure.enqueue({}, code, { 'Retry-After': '300' });
    assert.equal(await failure.service.submit(), true); assert.equal(failure.service.uploads[0].state, code === 500 ? 'uncertain' : 'failed');
    assert.equal(failure.service.body, ''); assert.equal(failure.service.attachmentFeedbackId, id); assert.equal(failure.token, token);
    if (code === 429) {
      failure.enqueue({ schemaVersion: 1, feedback: item() }); await failure.service.retryUploads();
      assert.equal(failure.calls.filter(call => call.url.endsWith('/attachments')).length, 1, 'Uploads honor their independent cooldown');
    }
    failure.balanced();
  }
  const download = await setup(token), own = item({ attachments: [attachment()] });
  download.defer(() => ({ responseCode: 200, result: new ArrayBuffer(12), header: {} }));
  assert.equal((await download.service.attachmentBytes(own, attachment())).byteLength, 12);
  assert.equal(download.calls[0].expectDataType, 'ARRAY_BUFFER'); assert.equal(download.calls[0].extraData, undefined);
  download.service.detail = own; download.enqueue({ deleted: true }); await download.service.deleteAttachment(own, attachment());
  assert.equal(download.calls.at(-1).method, 'DELETE'); assert.equal(download.service.detail.attachments.length, 0); download.balanced();
  const recovery = await setup(token); recovery.service.body = 'lost receipt'; recovery.service.type = 'suggestion'; recovery.service.addUploads([upload()]);
  recovery.fail(); await recovery.service.submit();
  await recovery.service.attachToRecoveredFeedback(item({ body: 'different', type: 'suggestion' })); assert.equal(recovery.service.uncertain, true);
  recovery.enqueue({ schemaVersion: 1, feedback: item({ body: 'lost receipt', type: 'suggestion' }) });
  recovery.enqueue({ schemaVersion: 1, attachment: attachment() }, 201);
  await recovery.service.attachToRecoveredFeedback(item({ body: 'lost receipt', type: 'suggestion' }));
  assert.equal(recovery.service.uncertain, false); assert.equal(recovery.calls.filter(call => call.method === 'POST' && !call.url.endsWith('/attachments')).length, 1);
  recovery.balanced();
  console.log('PASS feedback: identity persistence, UTF-16 validation, HTTP contract, pagination/filter/counts, reply read state, failure retention, cooldowns, crash recovery and duplicate prevention');
  console.log('PASS feedback v2: types, binary sequential uploads, partial success, durable upload queue, timeout reconciliation, authenticated downloads/deletion and log redaction');
  await checkNativeFiles();
  if (process.argv.includes('--ui')) await checkUi();
}
main().catch(error => { console.error(error); process.exitCode = 1; });
