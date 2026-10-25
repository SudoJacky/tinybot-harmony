// Real tool dispatch, preflight queue, transcript projection and session persistence; no model/network.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src'), cache = new Map();
function load(file) {
  file = path.resolve(file + '.ets'); if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  let source = fs.readFileSync(file, 'utf8');
  if (file.endsWith('SessionService.test.ets')) source += '\nexport { Fixture, seed };';
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true
  } }).outputText, { exports, Error, setTimeout, clearTimeout, console, Observed: cls => cls,
    require: id => id === '@ohos/hypium' ? {} : load(path.resolve(path.dirname(file), id)) }, { filename: file });
  return exports;
}
const from = name => load(path.join(root, 'main/ets', name)), clone = x => JSON.parse(JSON.stringify(x));
const { PreviewTools } = from('services/PreviewTools');
const { WebUiPreflight } = from('services/WebUiPreflight');
const { Cancellation } = from('services/Cancellation');
const { runAgentLoop } = from('services/AgentLoop');
const { parseUiSurface } = from('model/InteractiveUi');
const { stepDisplayContent, publishedAnswerParts } = from('model/PublishedPreview');
const { buildTimeline } = from('model/ProcessPresentation');
const { validateSteps } = from('model/Agent');
const { parseAppData, requestHistory } = from('model/Conversation');
const { AgentStepViewModel } = from('viewmodel/SessionViewModels');
const { Fixture, seed } = load(path.join(root, 'test/SessionService.test'));
const { WorkspaceTools } = from('services/WorkspaceTools');
const { ToolSet } = from('services/ToolSet');
const { ToolFailure } = from('model/ToolFailure');
const { applyTextEdits } = from('model/WorkspaceEdit');
const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><text x="1" y="20">Pelican</text></svg>`;
const files = new Map([['pelican.svg', svg], ['page.html', '<h1>Preview</h1><script>throw Error("broken startup")</script>']]);
let reads = 0, serial = 0;
const storage = { read: async name => { reads++; if (!files.has(name)) throw Error('File missing'); return { path: name, content: files.get(name), version: 'v1' }; } };
const tools = new PreviewTools(storage, (c, s) => WebUiPreflight.validate(c, s));
const call = (name, args) => ({ id: 'call-' + ++serial, type: 'function', function: { name, arguments: JSON.stringify(args) } });
async function run(args, signal = new Cancellation()) {
  const inputs = [], checkpoints = [], turn = { content: '', steps: [] };
  await runAgentLoop({ turn, tools, maxSteps: 3, messages: [], model: { stream: async messages => {
    inputs.push(clone(messages)); const receipt=turn.steps[0]?.tools[0]; const ref=receipt?.status==='complete'?JSON.parse(receipt.output).reference:''; return inputs.length === 1 ? { content: '', toolCalls: [call('publish_preview', args)] } : { content: 'Ready.\n\n'+(ref||''), toolCalls: [] };
  } } }, signal, { event: () => {}, checkpoint: async () => checkpoints.push(clone(turn)) });
  return { turn, inputs, checkpoints, receipt: turn.steps[0].tools[0] };
}
async function main() {
  let probes = 0;
  const detach = WebUiPreflight.subscribe(items => { if (items.length) {
    probes++; const probe = items[0]; setTimeout(() => WebUiPreflight.complete(probe.id,
      probe.content.includes('broken startup') ? 'Error: broken startup at tinybot-generated.js:2' : ''), 0);
  } });
  const published = await run({ path: 'pelican.svg' });
  assert.equal(reads, 1); assert.equal(probes, 1); assert.equal(published.receipt.status, 'complete');
  assert.equal(JSON.parse(published.receipt.output).published, true);
  assert.ok(!JSON.stringify(published.inputs).includes('<svg'));
  const specOf = result => JSON.parse(parseUiSurface(result.receipt.previewContent, '0').nodes[0].data);
  assert.equal(specOf(published).html, svg); assert.equal(specOf(published).autoHeight, true);
  assert.ok(!buildTimeline(published.turn.steps).some(x => x.kind === 'text' && x.step === 0), 'Tool publication does not create a preview entry');
  assert.ok(published.checkpoints.some(x => x.steps[0].tools[0]?.previewContent === published.receipt.previewContent));
  const js = 'const text = "</script> and \\"quotes\\"";\nawait Promise.resolve();\ndocument.body.textContent = text;';
  files.set('scene.js', js);
  const args = { path: 'scene.js', title: 'A scene', library: 'three', height: 560 };
  const scene = await run(args), spec = specOf(scene);
  assert.equal(scene.receipt.status, 'complete'); assert.equal(spec.js, js); assert.equal(spec.html, '');
  assert.equal(spec.library, 'three'); assert.equal(spec.height, 560); assert.equal(spec.autoHeight, false);
  files.set('scene.js', 'changed'); files.delete('scene.js');
  assert.equal(stepDisplayContent(scene.turn.steps[0]), '');
  const content = scene.receipt.previewContent;
  assert.equal(JSON.parse(parseUiSurface(content, '0').nodes[0].data).js, js);
  const view = new AgentStepViewModel({ content: '', tools: [{ ...scene.receipt, status: 'running', previewContent: undefined }] });
  const retained = view.tools[0]; view.update(scene.turn.steps[0]);
  assert.equal(view.tools[0], retained); assert.equal(stepDisplayContent(view), '');
  // ArkUI can synchronously render when an observed tool changes to complete.
  // Exercise that callback during the real projection, before update() returns.
  const { stepPreviews } = from('model/PublishedPreview');
  const live = new AgentStepViewModel({ content: '', tools: [{ ...scene.receipt,
    status: 'running', output: '', previewContent: undefined }] });
  const liveTool = live.tools[0]; let liveStatus = liveTool.status, rendered = 0;
  Object.defineProperty(liveTool, 'status', { configurable: true,
    get: () => liveStatus,
    set: value => { liveStatus = value; if (value === 'complete') {
      const cards = stepPreviews('live', live, 0, ['live:' + liveTool.call.id]);
      assert.equal(cards.length, 0, 'Completing a tool never mounts a new preview'); rendered++;
    } }
  });
  live.update(scene.turn.steps[0]);
  assert.equal(rendered, 1); assert.equal(live.tools[0], liveTool);
  validateSteps(scene.turn.steps);
  files.set('plain.JS', 'document.body.textContent = "Hi";');
  const plain = specOf(await run({ path: 'plain.JS' }));
  assert.equal(plain.library, 'none'); assert.equal(plain.height, 400); assert.equal(plain.autoHeight, false);
  files.set('page.html', '<h1>Preview</h1>');
  const html = specOf(await run({ path: 'page.html', library: 'three', height: 300 }));
  assert.equal(html.library, 'three'); assert.equal(html.height, 300); assert.equal(html.autoHeight, false);
  assert.equal(specOf(await run({ path: 'page.html' })).autoHeight, true);
  console.log('PASS JS/Three.js, plain JS defaults, HTML library/height, SVG sizing, exact immutable source and live projection');

  const before = reads, beforeProbes = probes;
  for (const path of ['bad.jsonl', 'valid.JSONL']) {
    files.set(path, '{"op":"begin"}');
    const result = await run({ path });
    assert.equal(result.receipt.status, 'failed'); assert.equal(result.receipt.previewContent, undefined);
    assert.equal(JSON.parse(result.receipt.output).code, 'UNSUPPORTED_PREVIEW_FORMAT');
    assert.match(result.receipt.output, /library/);
  }
  for (const invalidArgs of [{ path: '../plain.JS' }, { path: 'no.txt' }, { path: 'plain.JS', library: 'cdn' },
    { path: 'plain.JS', library: null }, { path: 'plain.JS', height: '400' }, { path: 'plain.JS', height: 199 },
    { path: 'plain.JS', height: 801 }, { path: 'plain.JS', title: ' ' }, { path: 'plain.JS', extra: 1 }]) {
    const invalid = await run(invalidArgs); assert.equal(invalid.receipt.status, 'failed'); assert.equal(invalid.receipt.previewContent, undefined);
  }
  assert.equal(reads, before); assert.equal(probes, beforeProbes);
  files.set('scene.js', 'throw Error("broken startup");');
  const startup = await run(args), diagnostic = JSON.parse(startup.receipt.output);
  assert.equal(startup.receipt.status, 'failed'); assert.equal(startup.receipt.previewContent, undefined);
  assert.equal(diagnostic.code, 'PREVIEW_INVALID'); assert.equal(diagnostic.details.category, 'WEB_STARTUP_FAILED');
  assert.equal(diagnostic.details.locationScope, 'generated_wrapper'); assert.equal(diagnostic.details.location.line, undefined);
  assert.deepEqual(diagnostic.details.repair.retry, { tool: 'publish_preview', arguments: args });
  assert.match(diagnostic.details.repair.instruction, /host or device capability is unavailable/);
  files.set('scene.js', js);
  assert.equal((await run(diagnostic.details.repair.retry.arguments)).receipt.status, 'complete');
  console.log('PASS legacy format and invalid options reject before I/O; startup failures retain every retry option');

  detach();
  let pending; const stopProbe = WebUiPreflight.subscribe(items => { pending = items[0]; });
  const signal = new Cancellation(), cancelled = run(args, signal);
  while (!pending) await new Promise(resolve => setTimeout(resolve, 0));
  const cancelledCheck = assert.rejects(cancelled, /已停止/); signal.cancel(); await cancelledCheck; stopProbe();
  const unavailable = await run(args);
  assert.equal(unavailable.receipt.previewContent, undefined); assert.match(unavailable.receipt.output, /unavailable/);
  console.log('PASS cancellation and unavailable render host never publish');

  const data = seed(); data.threads[0].messages = [
    { id: 'u', role: 'user', content: 'Preview', status: 'complete', error: '' },
    { id: 'a', role: 'assistant', content: 'Ready.', status: 'complete', error: '', steps: scene.turn.steps } ];
  const restored = parseAppData(JSON.stringify(data));
  assert.equal(stepDisplayContent(restored.threads[0].messages[1].steps[0]), '');
  assert.equal(publishedAnswerParts('a',restored.threads[0].messages[1].steps,1,'complete',[]).find(p=>p.kind==='preview').preview.content,content);
  assert.ok(!JSON.stringify(requestHistory(restored.threads[0].messages, '')).includes(js));
  const fixture = new Fixture(restored); await fixture.session.initialize();
  const reboot = new Fixture(parseAppData(fixture.repository.saved)); await reboot.session.initialize();
  assert.equal(await reboot.session.forkThread('a'), true);
  const snapshot = reboot.session.snapshot(), branchId = snapshot.activeThreadId;
  assert.equal(publishedAnswerParts('a',snapshot.threads.find(t => t.id === branchId).messages[1].steps,1,'complete',[]).find(p=>p.kind==='preview').preview.content,content);
  assert.equal(publishedAnswerParts('a',snapshot.threads.find(t => t.id === 'thread-1').messages[1].steps,1,'complete',[]).find(p=>p.kind==='preview').preview.content,content);
  console.log('PASS source snapshots survive actual session restart and fork without replaying source into model history');

  // Real runtime recovery: reject inline JSONL, write JS, fail startup, read/edit that file, republish.
  const repairFiles = new Map(); let writes = 0;
  const version = text => require('node:crypto').createHash('sha256').update(text).digest('base64');
  const repairStorage = {
    read: async (name, signal) => { signal.check(); if (!repairFiles.has(name)) throw Error('File missing');
      const content = repairFiles.get(name); return { path: name, content, version: version(content) }; },
    write: async (name, content, signal, guard) => { signal.check();
      if (guard?.version === null && repairFiles.has(name)) throw new ToolFailure('FS_NOT_OBSERVED', 'Already exists', 'read_file');
      if (guard?.version && (!repairFiles.has(name) || guard.version !== version(repairFiles.get(name)))) throw new ToolFailure('FS_STALE_VERSION', 'Changed', 'read_file');
      repairFiles.set(name, content); writes++; return { path: name, bytes: Buffer.byteLength(content), written: true, version: version(content) }; },
    edit: async (name, edits, observed, signal) => { const before = await repairStorage.read(name, signal);
      if (observed !== before.version) throw new ToolFailure('FS_STALE_VERSION', 'Changed', 'read_file');
      return repairStorage.write(name, applyTextEdits(before.content, edits), signal, { version: observed }); }
  };
  const recovery = new Fixture(seed()), workspace = new WorkspaceTools(repairStorage);
  recovery.resources.agentTools = new ToolSet([workspace, new PreviewTools(repairStorage, (c, s) => WebUiPreflight.validate(c, s))]);
  recovery.resources.recoverUi = async () => { throw Error('Must not migrate legacy JSONL'); };
  const sourcePath = 'repaired.js', failed = 'throw Error("broken startup");\n// untouched artwork\n// untouched artwork';
  const correct = failed.replace('throw Error("broken startup");', 'document.body.textContent = "Ready";');
  const retryArgs = { path: sourcePath, title: 'Repaired', library: 'three', height: 450 };
  const release = WebUiPreflight.subscribe(items => { if (items[0]) {
    const probe = items[0]; setTimeout(() => WebUiPreflight.complete(probe.id, probe.content.includes('broken startup') ? 'broken startup' : ''), 0);
  } });
  recovery.provider.respond = async index => {
    if (index === 0) return { content: '\x60\x60\x60tinybot-ui\n{"op":"begin"}\n\x60\x60\x60',
      toolCalls: [call('write_file', { path: 'must-not-write.txt', content: 'bad' })] };
    if (index === 1) {
      const saved = parseAppData(recovery.repository.saved).threads[0].messages[1].steps[0];
      assert.equal(JSON.parse(saved.uiValidation).category, 'UNSUPPORTED_PREVIEW_FORMAT');
      assert.equal(saved.tools[0].status, 'cancelled'); assert.equal(repairFiles.size, 0);
      return { content: '', toolCalls: [call('write_file', { path: sourcePath, content: failed })] };
    }
    if (index === 2) return { content: '', toolCalls: [call('publish_preview', retryArgs)] };
    if (index === 3) {
      const saved = parseAppData(recovery.repository.saved).threads[0].messages[1].steps[2];
      assert.deepEqual(JSON.parse(saved.tools[0].output).details.repair.retry.arguments, retryArgs);
      return { content: '', toolCalls: [call('read_file', { path: sourcePath })] };
    }
    if (index === 4) return { content: '', toolCalls: [call('edit_file', { path: sourcePath,
      edits: [{ oldText: 'throw Error("broken startup");', newText: 'document.body.textContent = "Ready";' }] })] };
    if (index === 5) return { content: '', toolCalls: [call('publish_preview', retryArgs)] };
    const saved = parseAppData(recovery.repository.saved).threads[0].messages[1].steps[5].tools[0];
    return { content: 'Ready.\n\n'+JSON.parse(saved.output).reference, toolCalls: [] };
  };
  await recovery.session.initialize(); recovery.session.setDraft('Publish'); await recovery.session.send(); release();
  const recovered = parseAppData(recovery.repository.saved).threads[0].messages[1];
  assert.equal(recovered.status, 'complete', recovered.error); assert.equal(recovered.steps.length, 7);
  assert.equal(writes, 2); assert.equal(repairFiles.get(sourcePath), correct);
  assert.equal(recovered.steps[5].tools[0].status, 'complete'); assert.ok(recovered.steps[5].tools[0].previewContent);
  console.log('PASS real session rejects legacy inline UI, then writes, checks, reads, patches and republishes ordinary JS');

  const editSignal = new Cancellation();
  await workspace.execute(call('read_file', { path: sourcePath }), editSignal);
  repairFiles.set(sourcePath, correct + '\n');
  await assert.rejects(workspace.execute(call('edit_file', { path: sourcePath, oldText: 'Ready', newText: 'Hello' }), editSignal),
    error => error.code === 'FS_STALE_VERSION' && error.details.path === sourcePath);
  await workspace.execute(call('read_file', { path: sourcePath }), editSignal);
  for (const [oldText, code] of [['missing text', 'FS_MATCH_NOT_FOUND'], ['untouched artwork', 'FS_AMBIGUOUS_MATCH']]) {
    await assert.rejects(workspace.execute(call('edit_file', { path: sourcePath, oldText, newText: 'replacement' }), editSignal),
      error => error.code === code);
  }
  assert.equal(repairFiles.get(sourcePath), correct + '\n'); assert.equal(writes, 2);
  console.log('PASS repair edits preserve files on stale, missing and ambiguous matches');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
