// Exercise annotation geometry, raster export and real session/runtime delivery without native UI.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src'), cache = new Map();
const compile = source => ts.transpileModule(source, { compilerOptions: {
  module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true
} }).outputText;
const raster = { effects: [], released: 0, fail: false };
// Empty canvases come from image.createPixelMapSync(), the overload that exists on API 12+.
const image = { PixelMapFormat: {}, AlphaType: {}, createPixelMapSync(options) {
  raster.size = options.size; return { release: async () => { raster.released++; } };
} };
const drawing = { CapStyle: { ROUND_CAP: 2 }, Canvas: class {
  drawColor() {} drawImageRect(source, rect) { raster.effects.push(['image', source, rect]); }
  attachPen(pen) { this.pen = pen; } detachPen() {}
  drawPath(p) { if (raster.fail) throw Error('raster failed'); raster.effects.push(['stroke', this.pen.width, p.points]); }
}, Pen: class { setColor() {} setAntiAlias() {} setCapStyle() {} setStrokeWidth(width) { this.width = width; } },
Path: class { points = []; moveTo(x, y) { this.points.push([x, y]); } lineTo(x, y) { this.points.push([x, y]); } } };
function load(file) {
  file = path.resolve(file.endsWith('.ets') ? file : file + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  let source = fs.readFileSync(file, 'utf8');
  if (file.endsWith('SessionService.test.ets')) source += '\nexport { Fixture, Gate };';
  vm.runInNewContext(compile(source), { exports, Observed: value => value, setTimeout, clearTimeout, console, require: id => {
    if (id === '@ohos/hypium') return {};
    if (id === '@kit.ImageKit') return { image };
    if (id === '@kit.ArkGraphics2D') return { drawing };
    if (!id.startsWith('.')) throw Error('Unexpected dependency ' + id);
    return load(path.resolve(path.dirname(file), id));
  } }, { filename: file });
  return exports;
}
const from = name => load(path.join(root, 'main/ets', name));
const { BrowserAnnotation } = from('model/BrowserAnnotation');
const { browserAnnotationContent, browserAnnotationText } = from('model/BrowserAnnotationContent');
const { attachmentContext } = from('model/AttachmentContext');
const { renderBrowserAnnotation } = from('services/BrowserAnnotationImage');
const { requestHistory } = from('model/Conversation');
const { threadEntries } = from('model/ContextProjection');
const { Fixture, Gate } = load(path.join(root, 'test/SessionService.test'));
const photo = id => ({ id, name: 'Web page annotation.jpg', mime: 'image/jpeg', path: id + '.jpg', size: 120 });
const note = 'Make this larger';
const reference = { title: 'Example', url: 'https://example.com/view', tag: 'button',
  element: { label: 'User control test', location: '#human' },
  changes: [{ property: 'border-width', before: '2px', after: '7px' }] };
const annotationPhoto = id => ({ ...photo(id), browserAnnotation: browserAnnotationContent(reference, note) });
const active = session => session.snapshot().threads.find(thread => thread.id === session.snapshot().activeThreadId);
const deadline = setTimeout(() => { console.error('Annotation test stalled'); process.exit(1); }, 30000);
(async () => {
  const draft = new BrowserAnnotation(); assert.equal(draft.dirty(), false);
  draft.begin(0.25, 0.1, 0.01); draft.move(0.75, 0.9); draft.end();
  assert.equal(draft.dirty(), true); assert.equal(draft.strokes[0].points.length, 2);
  const source = { getImageInfo: async () => ({ size: { width: 2000, height: 1000 } }) };
  const output = await renderBrowserAnnotation(source, draft.strokes);
  assert.equal(raster.size.width, 1600); assert.equal(raster.size.height, 800);
  const stroke = raster.effects.find(effect => effect[0] === 'stroke');
  assert.equal(stroke[1], 16); assert.equal(stroke[2][0][0], 400); assert.equal(stroke[2][0][1], 80);
  assert.equal(stroke[2].at(-1)[0], 1200); assert.equal(stroke[2].at(-1)[1], 720);
  assert.equal(raster.released, 0); await output.release();
  raster.fail = true; await assert.rejects(renderBrowserAnnotation(source, draft.strokes), /raster failed/);
  assert.equal(raster.released, 2); raster.fail = false;
  draft.undo(); assert.equal(draft.dirty(), false); draft.note = 'Make this larger'; assert.equal(draft.dirty(), true);
  draft.begin(0.5, 0.5, 0.01); draft.clear(); assert.equal(draft.strokes.length, 0); assert.equal(draft.note, 'Make this larger');
  const text = browserAnnotationText(annotationPhoto('reference').browserAnnotation);
  assert.match(text, /https:\/\/example.com\/view/); assert.match(text, /Make this larger/); assert.match(text, /"after":"7px"/);
  console.log('PASS normalized annotation strokes, undo/clear, note context, full-image export and failed-export cleanup');

  const f = new Fixture(); await f.session.initialize();
  const entered = new Gate(), release = new Gate();
  f.provider.respond = async index => { if (index === 0) { entered.open(); await release.promise; } return { content: 'answer-' + index, toolCalls: [] }; };
  f.session.setDraft('initial'); const running = f.session.send(); await entered.promise;
  f.session.setDraft('Existing draft');
  await f.session.appendDraftAttachment('thread-1', annotationPhoto('annotation'));
  assert.equal(f.session.state.phase, 'running'); assert.equal(f.provider.requests.length, 1);
  assert.equal(active(f.session).draft, 'Existing draft'); assert.equal(active(f.session).attachments[0].id, 'annotation');
  await f.session.editBrowserAnnotation('thread-1', 'annotation', 'Adjust the border');
  assert.equal(active(f.session).attachments[0].browserAnnotation.note, 'Adjust the border');
  await assert.rejects(f.session.appendDraftAttachment('other', annotationPhoto('wrong')), /对话已切换/);
  await f.session.enqueueInput('steer');
  assert.equal(active(f.session).pendingInputs[0].attachments[0].id, 'annotation');
  assert.equal(active(f.session).attachments.length, 0);
  await f.session.appendDraftAttachment('thread-1', annotationPhoto('queued')); await f.session.enqueueInput('followUp');
  assert.equal(active(f.session).pendingInputs.find(input => input.mode === 'followUp').text, '');
  f.session.setDraft('Keep this draft'); release.open(); await running;
  assert.equal(f.provider.requests.length, 3);
  assert.ok(f.provider.requests[1].messages.some(message => message.attachments?.[0]?.id === 'annotation'));
  assert.ok(f.provider.requests[2].messages.some(message => message.attachments?.[0]?.id === 'queued'));
  const thread = active(f.session);
  assert.equal(thread.draft, 'Keep this draft'); assert.equal(thread.messages[2].attachments[0].id, 'queued');
  assert.equal(thread.messages[2].content, ''); assert.equal(thread.messages[2].attachments[0].browserAnnotation.changes[0].after, '7px');
  assert.ok(requestHistory(thread.messages, '').some(message => message.attachments?.[0]?.id === 'annotation'));
  assert.ok(threadEntries(thread).flatMap(entry => entry.messages).some(message => message.attachments?.[0]?.id === 'annotation'));
  const saved = await f.repository.load();
  assert.ok(saved.threads[0].messages[1].steps.some(step => step.steering?.attachments?.[0]?.browserAnnotation.note === 'Adjust the border'));

  const attachmentTree = ts.createSourceFile('Attachments.ets', fs.readFileSync(path.join(root, 'main/ets/services/Attachments.ets'), 'utf8'), ts.ScriptTarget.Latest, true);
  const hydrate = attachmentTree.statements.find(node => ts.isClassDeclaration(node) && node.name.text === 'Attachments')
    .members.find(node => node.name?.getText(attachmentTree) === 'hydrate');
  const hydration = { exports: {}, attachmentContext, Attachments: { path: item => item.path },
    fs: { OpenMode: {}, open: async () => ({ fd: 1 }), close: async () => {} },
    util: { Base64Helper: class { encodeToStringSync() { return 'AQ=='; } } }, readBounded: async () => new Uint8Array([1]) };
  vm.runInNewContext(compile('export class Probe {' + hydrate.getText(attachmentTree) + '}'), hydration);
  const prompt = { role: 'user', content: '', attachments: [annotationPhoto('hydrate')] };
  const [hydrated] = await hydration.exports.Probe.hydrate([prompt]);
  assert.equal(hydrated.content, '\n\n' + text);
  assert.equal(hydrated.images[0], 'data:image/jpeg;base64,AQ==');
  assert.equal(prompt.content, '');
  const backupTree = ts.createSourceFile('Backup.ets', fs.readFileSync(path.join(root, 'main/ets/services/Backup.ets'), 'utf8'), ts.ScriptTarget.Latest, true);
  const collect = backupTree.statements.find(node => ts.isFunctionDeclaration(node) && node.name.text === 'threadAttachments');
  const backupScope = { exports: {}, toolReceipts: from('model/Agent').toolReceipts };
  vm.runInNewContext(compile(collect.getText(backupTree) + '\nexports.collect = threadAttachments;'), backupScope);
  thread.pendingInputs = [{ id: 'pending-image', mode: 'followUp', text, attachments: [photo('pending-backup')] }];
  thread.messages[1].steps.push({ content: '', tools: [{ call: { id: 'backup-orchestrate', type: 'function',
    function: { name: 'orchestrate', arguments: '{}' } }, status: 'failed', output: '{}', children: [{
      call: { id: 'backup-preview', type: 'function', function: { name: 'publish_preview', arguments: '{}' } },
      status: 'complete', output: '{}', previewScreenshot: { image: photo('nested-preview'), width: 360, height: 240, viewportWidth: 360 }
    }] }] });
  const backupImages = backupScope.exports.collect(thread).map(item => item.id);
  assert.ok(backupImages.includes('annotation')); assert.ok(backupImages.includes('pending-backup')); assert.ok(backupImages.includes('queued'));
  assert.ok(backupImages.includes('nested-preview'), 'Committed child screenshots are included even if their orchestration failed');
  console.log('PASS running-session annotation staging preserves drafts, requires explicit submission and delivers images in steering, follow-ups, replay and persisted history');

  const edit = new Fixture(); await edit.session.initialize();
  await edit.session.appendDraftAttachment('thread-1', annotationPhoto('edit')); await edit.session.enqueueInput('followUp');
  const id = active(edit.session).pendingInputs[0].id;
  await edit.session.setAttachments([photo('unsent')]); await edit.session.removePendingInput(id, true);
  assert.equal(active(edit.session).pendingInputs.length, 1, 'Editing cannot overwrite an existing attachment draft');
  await edit.session.setAttachments([]); await edit.session.removePendingInput(id, true);
  assert.equal(active(edit.session).attachments[0].id, 'edit'); assert.equal(active(edit.session).draft, '');
  edit.session.setDraft('x'.repeat(24000));
  const invalid = annotationPhoto('invalid'); invalid.browserAnnotation.note = 'x'.repeat(4001);
  await assert.rejects(edit.session.appendDraftAttachment('thread-1', invalid), /附件记录无效/);
  assert.equal(active(edit.session).attachments.length, 1);
  await edit.session.appendDraftAttachment('thread-1', annotationPhoto('extra'));
  assert.equal(active(edit.session).draft.length, 24000);
  await edit.session.editBrowserAnnotation('thread-1', 'extra');
  assert.equal(active(edit.session).attachments.length, 1);
  edit.session.setDraft(''); edit.repository.beforeSave = async () => { throw Error('annotation disk failed'); };
  await assert.rejects(edit.session.appendDraftAttachment('thread-1', annotationPhoto('failed')), /annotation disk failed/);
  assert.match(edit.session.state.saveError, /annotation disk failed/);
  assert.equal(active(edit.session).attachments.at(-1).id, 'edit', 'A failed editor submission can retry without staging a duplicate');
  console.log('PASS queue edit preserves attachment drafts, validates limits before mutation and exposes persistence failures');

  const files = new Fixture();
  await files.session.initialize();
  const target = { kind: 'slide', slide: 2, elementId: 'metric-badge', location: 'Slide 2 / metric-badge #4', excerpt: '12' };
  const first = 'Check this total';
  const second = 'Is the currency USD?';
  files.session.setDraft('Context from the user');
  await files.session.addFileAnnotation('thread-1', 'budget.pptx', 'v1', target, first);
  await files.session.addFileAnnotation('thread-1', 'budget.pptx', 'v1', target, second);
  assert.equal(active(files.session).draft, 'Context from the user');
  assert.equal(files.provider.requests.length, 0);
  const staged = active(files.session).annotations;
  await files.session.editFileAnnotation('thread-1', staged[0].id);
  await files.session.editFileAnnotation('thread-1', staged[1].id, 'Which currency is this?');
  assert.equal((await files.repository.load()).threads[0].annotations.length, 1);
  files.session.setDraft('');
  files.resources.verifyFileAnnotations = async () => { throw Error('Stale file'); };
  await files.session.send();
  assert.match(files.session.state.error, /Stale file/);
  assert.equal(active(files.session).annotations.length, 1);
  assert.equal(files.provider.requests.length, 0);
  files.resources.verifyFileAnnotations = async () => {};
  await files.session.send();
  const savedFileTurn = (await files.repository.load()).threads[0].messages[0];
  assert.equal(savedFileTurn.content, '');
  assert.equal(savedFileTurn.annotations[0].location, target.location);
  assert.equal(savedFileTurn.annotations[0].slide, target.slide);
  assert.equal(savedFileTurn.annotations[0].elementId, target.elementId);
  assert.equal(savedFileTurn.annotations[0].comment, 'Which currency is this?');
  const input = files.provider.requests[0].messages.find(message => message.role === 'user');
  assert.equal(input.content, '');
  const { chatRequest } = from('services/providers/ChatCompletionsProtocol');
  const { responsesRequest, anthropicRequest } = from('services/providers/WireProtocols');
  const { geminiRequest } = from('services/providers/GeminiProtocol');
  const user = { ...input, content: 'Exactly what the user typed' };
  for (const blocks of [
    chatRequest('model', [user], []).messages[0].content,
    responsesRequest('model', [user], []).input[0].content,
    anthropicRequest('model', [user], []).messages[0].content,
    geminiRequest([user], []).contents[0].parts
  ]) {
    assert.equal(blocks.length, 2);
    assert.equal(blocks[0].text, user.content);
    const annotation = JSON.parse(blocks[1].text).annotations[0];
    assert.equal(annotation.comment, savedFileTurn.annotations[0].comment);
    assert.equal(annotation.slide, target.slide);
    assert.equal(annotation.elementId, target.elementId);
  }
  assert.equal(active(files.session).annotations, undefined);
  console.log('PASS file annotation drafts, stale-version rejection, annotation-only turns, and separate provider blocks');
})().catch(error => { console.error(error); process.exitCode = 1; }).finally(() => clearTimeout(deadline));
