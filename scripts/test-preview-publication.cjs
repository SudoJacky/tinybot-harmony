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
const { UiCompiler, parseUiSurface, validateUiAnswer } = from('model/InteractiveUi');
const { stepDisplayContent } = from('model/PublishedPreview');
const { buildTimeline } = from('model/ProcessPresentation');
const { validateSteps } = from('model/Agent');
const { parseAppData, requestHistory } = from('model/Conversation');
const { AgentStepViewModel } = from('viewmodel/SessionViewModels');
const { Fixture, seed } = load(path.join(root, 'test/SessionService.test'));
const { savePreviewRepair } = from('services/PreviewRecovery');
const { WorkspaceTools } = from('services/WorkspaceTools');
const { ToolSet } = from('services/ToolSet');
const { ToolFailure } = from('model/ToolFailure');
const { UiDiagnosticError, uiFailureReport } = from('model/UiRepair');
const { applyTextEdits } = from('model/WorkspaceEdit');
const jsonl = records => records.map(r => JSON.stringify(r)).join('\n');
const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><text x="1" y="20">Pelican</text></svg>`;
const files = new Map([['pelican.svg', svg], ['page.html', '<h1>Preview</h1><script>throw Error("broken startup")</script>']]);
let reads = 0, serial = 0;
const storage = { read: async name => { reads++; if (!files.has(name)) throw Error('File missing'); return { path: name, content: files.get(name), version: 'v1' }; } };
const tools = new PreviewTools(storage, (c, s) => WebUiPreflight.validate(c, s));
const call = (name, args) => ({ id: 'call-' + ++serial, type: 'function', function: { name, arguments: JSON.stringify(args) } });
async function run(args, signal = new Cancellation()) {
  const inputs = [], checkpoints = [], turn = { content: '', steps: [] };
  await runAgentLoop({ turn, tools, maxSteps: 3, messages: [], model: { stream: async messages => {
    inputs.push(clone(messages)); return inputs.length === 1 ? { content: '', toolCalls: [call('publish_preview', args)] } : { content: 'Ready.', toolCalls: [] };
  } } }, signal, { event: () => {}, checkpoint: async () => checkpoints.push(clone(turn)) });
  return { turn, inputs, checkpoints, receipt: turn.steps[0].tools[0] };
}
async function main() {
  const records = [ { op: 'begin', version: 1, title: 'Pelican', state: {} },
    { op: 'node', node: { id: 'art', kind: 'web', data: JSON.stringify({ version: 1, html: svg, css: '', js: '', library: 'none', height: 400 }) } }, { op: 'end' } ];
  const wire = jsonl(records);
  // The actual incident: the independently serialized file was valid; retyping its nested quotes broke the response.
  const broken = wire.replace('\\"css\\":\\"\\"', '"css":""');
  assert.throws(() => validateUiAnswer('```tinybot-ui\n' + broken + '\n```'), /surface=0: Interactive UI JSONL line 2: UI JSON syntax error at record/);
  assert.throws(() => new UiCompiler().update(broken.replace('"state":{}', '"state":{"spin":true}'), true), /line 2/);
  assert.equal(new UiCompiler().update(wire, true).complete, true);
  const nested = clone(records); nested[1].node.data = '{"html":';
  assert.throws(() => new UiCompiler().update('\n' + jsonl(nested), true), /line 3: node=art field=node.data: UI JSON syntax error/);
  const compiler = new UiCompiler(); compiler.update(wire.slice(0, 30), false); compiler.update(wire, true);
  assert.equal(compiler.document.complete, true);
  console.log('PASS exact outer/inner record diagnostics, blank and streamed lines, valid empty state');

  let probes = 0;
  const detach = WebUiPreflight.subscribe(items => { if (items.length) {
    probes++; const probe = items[0]; setTimeout(() => WebUiPreflight.complete(probe.id,
      probe.content.includes('broken startup') ? 'Error: broken startup at preview script' : ''), 0);
  } });
  const published = await run({ path: 'pelican.svg' });
  assert.equal(reads, 1); assert.equal(probes, 1); assert.equal(published.receipt.status, 'complete');
  assert.equal(JSON.parse(published.receipt.output).published, true);
  assert.ok(published.receipt.output.length < 200); assert.ok(!JSON.stringify(published.inputs).includes('<svg'));
  const content = stepDisplayContent(published.turn.steps[0]);
  assert.equal(JSON.parse(parseUiSurface(content, '0').nodes[0].data).html, svg);
  assert.equal(JSON.parse(parseUiSurface(content, '0').nodes[0].data).autoHeight, true);
  assert.ok(buildTimeline(published.turn.steps).some(x => x.kind === 'text' && x.step === 0));
  assert.ok(published.checkpoints.some(x => x.steps[0].tools[0]?.previewContent === content));
  files.set('pelican.svg', '<svg>changed</svg>');
  assert.equal(stepDisplayContent(published.turn.steps[0]), content);
  const view = new AgentStepViewModel({ content: '', tools: [{ ...published.receipt, status: 'running', previewContent: undefined }] });
  const retained = view.tools[0]; view.update(published.turn.steps[0]);
  assert.equal(view.tools[0], retained); assert.equal(stepDisplayContent(view), content);
  // ArkUI can synchronously render when an observed tool changes to complete.
  // Exercise that callback during the real projection, before update() returns.
  const { stepPreviews } = from('model/PublishedPreview');
  const live = new AgentStepViewModel({ content: '', tools: [{ ...published.receipt,
    status: 'running', output: '', previewContent: undefined }] });
  const liveTool = live.tools[0]; let liveStatus = liveTool.status, rendered = 0;
  Object.defineProperty(liveTool, 'status', { configurable: true,
    get: () => liveStatus,
    set: value => { liveStatus = value; if (value === 'complete') {
      const cards = stepPreviews('live', live, 0, ['live:' + liveTool.call.id]);
      assert.equal(cards.length, 1); assert.equal(cards[0].path, 'pelican.svg'); rendered++;
    } }
  });
  live.update(published.turn.steps[0]);
  assert.equal(rendered, 1); assert.equal(live.tools[0], liveTool);
  validateSteps(published.turn.steps);
  console.log('PASS source read once, exact snapshot published and checkpointed, no preview JSON replay, live view retained');

  files.set('bad.jsonl', broken);
  const bad = await run({ path: 'bad.jsonl' });
  assert.equal(bad.receipt.status, 'failed'); assert.equal(bad.receipt.previewContent, undefined);
  const diagnostic = JSON.parse(bad.receipt.output);
  assert.equal(diagnostic.code, 'PREVIEW_INVALID'); assert.match(diagnostic.error, /bad.jsonl.*line 2/);
  assert.equal(diagnostic.details.category, 'JSON_SYNTAX'); assert.equal(diagnostic.details.location.line, 2);
  assert.equal(diagnostic.details.locationScope, 'jsonl_source');
  assert.deepEqual(diagnostic.details.repair.retry, { tool: 'publish_preview', arguments: { path: 'bad.jsonl' } });
  assert.match(diagnostic.details.repair.instruction, /empty state object is valid/);
  assert.match(diagnostic.details.repair.instruction, /edit_file/);
  assert.equal(probes, 1); assert.ok(JSON.stringify(bad.inputs[1]).includes('fix_preview_file'));
  const startup = await run({ path: 'page.html' });
  assert.equal(startup.receipt.status, 'failed'); assert.match(startup.receipt.output, /node=preview/);
  const startupError = JSON.parse(startup.receipt.output);
  assert.equal(startupError.details.category, 'WEB_STARTUP_FAILED');
  assert.equal(startupError.details.locationScope, 'generated_wrapper');
  assert.equal(startupError.details.location.line, undefined);
  assert.match(startupError.details.repair.instruction, /host or device capability is unavailable/);
  assert.equal(startup.receipt.previewContent, undefined);
  const badField = clone(records); const spec = JSON.parse(badField[1].node.data); spec.height = 'tall'; badField[1].node.data = JSON.stringify(spec);
  files.set('field.jsonl', jsonl(badField));
  const field = JSON.parse((await run({ path: 'field.jsonl', title: 'Retained title' })).receipt.output);
  assert.equal(field.details.category, 'INVALID_FIELD'); assert.equal(field.details.location.field, 'node.data.height');
  assert.equal(field.details.location.node, 'art'); assert.equal(field.details.location.line, 2);
  assert.match(field.error, /expected a number in 200\.\.800/);
  assert.equal(field.details.repair.retry.arguments.title, 'Retained title');
  const before = reads; const invalid = await run({ path: '../pelican.svg' });
  assert.equal(invalid.receipt.status, 'failed'); assert.equal(reads, before);
  detach();
  let pending; const stopProbe = WebUiPreflight.subscribe(items => { pending = items[0]; });
  const signal = new Cancellation(), cancelled = run({ path: 'pelican.svg' }, signal);
  while (!pending) await new Promise(resolve => setTimeout(resolve, 0));
  const cancelledCheck = assert.rejects(cancelled, /已停止/); signal.cancel(); await cancelledCheck; stopProbe();
  const unavailable = await run({ path: 'pelican.svg' });
  assert.equal(unavailable.receipt.previewContent, undefined); assert.match(unavailable.receipt.output, /unavailable/);
  console.log('PASS syntax/startup failures reach model as tool errors; invalid paths, cancellation and unavailable host never publish');

  const controls = jsonl([{ op: 'begin', version: 1, title: 'Counter', state: { count: 1 } },
    { op: 'node', node: { id: 'count', kind: 'stepper', text: 'Count', bind: 'count', min: 0, max: 10 } }, { op: 'end' }]);
  files.set('controls.jsonl', controls);
  const native = await run({ path: 'controls.jsonl' }); // Native-only previews do not require an attached Web host.
  assert.equal(native.receipt.status, 'complete');
  const data = seed(); data.threads[0].messages = [
    { id: 'u', role: 'user', content: 'Preview', status: 'complete', error: '' },
    { id: 'a', role: 'assistant', content: 'Ready.', status: 'complete', error: '', steps: native.turn.steps } ];
  const restored = parseAppData(JSON.stringify(data));
  assert.equal(stepDisplayContent(restored.threads[0].messages[1].steps[0]), native.receipt.previewContent);
  assert.ok(!JSON.stringify(requestHistory(restored.threads[0].messages, '')).includes('```tinybot-ui'));
  const fixture = new Fixture(restored); await fixture.session.initialize();
  await fixture.session.interactUi('thread-1', 'a', '0:0', { count: 3 });
  assert.equal(fixture.session.snapshot().threads[0].messages[1].uiStates[0].values.count, 3);
  const reboot = new Fixture(parseAppData(fixture.repository.saved)); await reboot.session.initialize();
  await reboot.session.interactUi('thread-1', 'a', '0:0', { count: 4 });
  const branch = new Fixture(parseAppData(reboot.repository.saved)); await branch.session.initialize();
  assert.equal(await branch.session.forkThread('a'), true);
  const branchId = branch.session.snapshot().activeThreadId;
  await branch.session.interactUi(branchId, 'a', '0:0', { count: 5 });
  const snapshot = branch.session.snapshot();
  assert.equal(snapshot.threads.find(t => t.id === branchId).messages[1].uiStates[0].values.count, 5);
  assert.equal(snapshot.threads.find(t => t.id === 'thread-1').messages[1].uiStates[0].values.count, 4);
  console.log('PASS saved snapshots, real session state updates, restart and independent branch state');

  // Full user-facing recovery path through SessionService and the runtime, using real file tools.
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
  const recoveryData = seed(); recoveryData.providerProfiles[0].contextWindow = 128000; recoveryData.config.contextWindow = 128000;
  const recoveryFixture = new Fixture(recoveryData); const workspace = new WorkspaceTools(repairStorage);
  recoveryFixture.resources.agentTools = new ToolSet([workspace, new PreviewTools(repairStorage, (c, s) => WebUiPreflight.validate(c, s))]);
  recoveryFixture.resources.recoverUi = async (threadId, content, error, signal) => {
    assert.equal(threadId, 'thread-1'); return savePreviewRepair(repairStorage, 'fixture', content, error, signal);
  };
  const large = clone(records); const largeSpec = JSON.parse(large[1].node.data);
  largeSpec.html += '<!--' + 'unchanged artwork '.repeat(1400) + '-->'; large[1].node.data = JSON.stringify(largeSpec);
  const correct = '\n' + jsonl(large).replace(/\n/g, '\r\n') + '\r\n';
  const failed = correct.replace('\\"css\\":\\"\\"', '"css":""');
  const sourcePath = 'preview-repairs/fixture-0.jsonl';
  const releaseHost = WebUiPreflight.subscribe(items => { if (items[0]) setTimeout(() => WebUiPreflight.complete(items[0].id), 0); });
  recoveryFixture.provider.respond = async index => {
    if (index === 0) return { content: '```tinybot-ui\n' + failed + '```', toolCalls: [call('write_file', { path: 'must-not-write.txt', content: 'bad' })] };
    if (index === 1) {
      const saved = parseAppData(recoveryFixture.repository.saved).threads[0].messages[1].steps[0];
      const report = JSON.parse(saved.uiValidation);
      assert.equal(report.category, 'JSON_SYNTAX'); assert.equal(report.location.line, 3);
      assert.equal(report.sources[0].path, sourcePath); assert.equal(report.sources[0].version, version(failed));
      assert.equal(report.sources[0].retry.arguments.path, sourcePath);
      assert.equal(saved.tools[0].status, 'cancelled'); assert.equal(repairFiles.has('must-not-write.txt'), false);
      assert.equal(repairFiles.get(sourcePath), failed); assert.ok(saved.uiValidation.length < 4000);
      assert.ok(!saved.uiValidation.includes('unchanged artwork '.repeat(20)));
      assert.ok(JSON.stringify(recoveryFixture.provider.requests[index].messages).includes(sourcePath));
      return { content: '', toolCalls: [call('read_file', { path: sourcePath, offset: 3, limit: 1 })] };
    }
    if (index === 2) return { content: '', toolCalls: [call('edit_file', { path: sourcePath, edits: [{ oldText: '"css":""', newText: '\\"css\\":\\"\\"' }] })] };
    if (index === 3) return { content: '', toolCalls: [call('publish_preview', { path: sourcePath })] };
    return { content: 'Ready.', toolCalls: [] };
  };
  await recoveryFixture.session.initialize(); recoveryFixture.session.setDraft('Publish the illustration'); await recoveryFixture.session.send(); releaseHost();
  const recovered = parseAppData(recoveryFixture.repository.saved).threads[0].messages[1];
  assert.equal(recovered.status, 'complete', recovered.error); assert.equal(recovered.steps.length, 5);
  assert.equal(writes, 2); assert.equal(repairFiles.get(sourcePath), correct);
  assert.equal(recovered.steps[3].tools[0].status, 'complete'); assert.ok(recovered.steps[3].tools[0].previewContent);
  assert.ok(JSON.stringify(requestHistory(parseAppData(recoveryFixture.repository.saved).threads[0].messages, '')).includes(sourcePath));
  console.log('PASS large failed answer -> durable exact source -> read_file -> tiny edit_file patch -> publish_preview via real session');

  // A stale or non-unique edit must explain recovery and preserve the current file.
  const signal2 = new Cancellation();
  await workspace.execute(call('read_file', { path: sourcePath }), signal2);
  repairFiles.set(sourcePath, correct + '\n');
  await assert.rejects(workspace.execute(call('edit_file', { path: sourcePath, oldText: 'Pelican', newText: 'Bird' }), signal2), error => {
    assert.equal(error.code, 'FS_STALE_VERSION'); assert.equal(error.details.path, sourcePath);
    assert.match(error.details.repair.instruction, /Read the current file again/); return true;
  });
  await workspace.execute(call('read_file', { path: sourcePath }), signal2);
  for (const [oldText, code] of [['missing text', 'FS_MATCH_NOT_FOUND'], ['unchanged artwork', 'FS_AMBIGUOUS_MATCH']]) {
    await assert.rejects(workspace.execute(call('edit_file', { path: sourcePath, oldText, newText: 'replacement' }), signal2), error => {
      assert.equal(error.code, code); assert.equal(error.details.editIndex, 1); assert.match(error.details.repair.instruction, /uniquely matching oldText/); return true;
    });
  }
  assert.equal(repairFiles.get(sourcePath), correct + '\n'); assert.equal(writes, 2);
  console.log('PASS stale, missing and ambiguous edit recovery preserves source and existing structured error fields');

  const readonlyData = seed(); readonlyData.productivity.options.readOnly = true;
  const readonlyFixture = new Fixture(readonlyData); let savedReadonly = false;
  readonlyFixture.resources.recoverUi = async () => { savedReadonly = true; throw Error('Read-only bypass'); };
  readonlyFixture.provider.respond = async i => ({ content: i === 0 ? '```tinybot-ui\n' + broken + '\n```' : 'Unable to publish.', toolCalls: [] });
  await readonlyFixture.session.initialize(); readonlyFixture.session.setDraft('Preview'); await readonlyFixture.session.send();
  assert.equal(savedReadonly, false);
  const readonlyReport = JSON.parse(parseAppData(readonlyFixture.repository.saved).threads[0].messages[1].steps[0].uiValidation);
  assert.deepEqual(readonlyReport.sources, []); assert.match(readonlyReport.publication, /No editable source was saved/);
  const failureReport = JSON.parse(await savePreviewRepair({ write: async () => { throw Error('disk full'); } }, 'failed', '```tinybot-ui\n' + broken + '\n```',
    new UiDiagnosticError('JSON_SYNTAX', 'Different localized wording'), signal2));
  assert.equal(failureReport.storageError, 'disk full'); assert.deepEqual(failureReport.sources, []);
  assert.match(failureReport.repair.instruction, /Inspect the reported syntax location/);
  const cancelledSignal = new Cancellation(); cancelledSignal.cancel();
  await assert.rejects(savePreviewRepair(repairStorage, 'cancel', '```tinybot-ui\n' + broken + '\n```', Error('bad'), cancelledSignal), /已停止/);
  const maximalReport = uiFailureReport(new UiDiagnosticError('JSON_SYNTAX', '\u0000'.repeat(8000)), Array.from({ length: 8 }, (_, i) => ({
    surface: String(i), path: 'preview-repairs/12345678-1234-1234-1234-123456789012-' + i + '.jsonl', version: 'v'.repeat(44),
    retry: { tool: 'publish_preview', arguments: { path: 'preview-repairs/12345678-1234-1234-1234-123456789012-' + i + '.jsonl' } }
  })), '\u0000'.repeat(8000));
  assert.ok(maximalReport.length <= 8000); JSON.parse(maximalReport);
  console.log('PASS read-only, storage failure and cancellation; templates selected by code and persisted reports remain bounded JSON');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
