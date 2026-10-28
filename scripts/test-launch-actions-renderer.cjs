// Run after devecocli build: exercise the emitted page/controller methods at the navigation seam.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || 'C:/Program Files/Huawei/DevEco Studio';
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '..');
let intent, notificationThreadId, sharedInput, foreground = true;
const launch = { take: () => { const result = intent; intent = undefined; return result; }, isForeground: () => foreground,
  takeThreadId: () => { const id = notificationThreadId; notificationThreadId = undefined; return id; } };
function controller(file, name, methods, extra = {}) {
  const source = path.join(root, 'entry/src/main/ets', file + '.ets');
  const emitted = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets', file + '.ts');
  assert.ok(fs.statSync(emitted).mtimeMs >= fs.statSync(source).mtimeMs, 'Rebuild ' + file);
  const tree = ts.createSourceFile(emitted, fs.readFileSync(emitted, 'utf8'), ts.ScriptTarget.Latest, true);
  const component = tree.statements.find(node => ts.isClassDeclaration(node) && node.name.text === name);
  const body = methods.map(method => component.members.find(node => node.name?.getText(tree) === method).getText(tree)).join('\n');
  const globals = { exports: {}, LaunchActions: launch, AppMaterials: { surface: {} }, t: text => text, Error, ...extra };
  vm.runInNewContext(ts.transpileModule(`class Probe { ${body} } exports.Probe = Probe;`, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
  }).outputText, globals);
  return new globals.exports.Probe();
}
function page() {
  const page = controller('pages/Index', 'Index', ['receiveLaunch', 'receiveShare', 'revealChat'], {
    ShareInbox: { peek: () => sharedInput, take: () => { sharedInput = undefined; } }
  });
  page.events = []; page.voiceRequest = ''; page.appearance = { surface: {} };
  page.privacy = { allowed: true };
  page.app = { busy: false, canNavigate: true, saveError: '', error: '', active: { id: 'old', projectId: 'project' },
    flushDraft: async () => page.events.push('saved'),
    newThread: async project => { page.events.push(['new', project]); page.app.active.id = 'new'; return true; }
  };
  page.paths = { clear: () => page.events.push('navigation') };
  page.setDrawer = value => page.events.push(['drawer', value]);
  page.detailPaneOpen = true; page.workspaceOpen = true; page.editorDraft = 'Unsaved text';
  page.workbench = () => ({ docked: false });
  page.setDetailPane = value => { page.detailPaneOpen = value; };
  page.getUIContext = () => ({ getPromptAction: () => ({ showToast: value => page.events.push(['toast', value.message]) }) });
  return page;
}
function card(wide) {
  const nodes = [], stack = [];
  const containers = new Set(['Stack', 'Row', 'Column', 'If', 'FormLink']);
  let current;
  const element = type => new Proxy({}, { get: (_, key) => (...args) => {
    if (key === 'create') {
      current = { type, value: args[0], props: {}, parent: stack.at(-1) }; nodes.push(current);
      if (containers.has(type)) stack.push(current);
    } else if (key === 'pop') {
      if (containers.has(type)) assert.equal(stack.pop().type, type);
    } else { current.props[key] = args[0]; }
  } });
  const view = controller('widget/pages/WidgetCard', 'WidgetCard', ['initialRender', 'mascot', 'actions'], {
    ...Object.fromEntries(['Stack', 'Row', 'Column', 'If', 'FormLink', 'Circle', 'Image', 'Text', 'SymbolGlyph'].map(type => [type, element(type)])),
    Alignment: { TopStart: 'top-start' }, Color: { Transparent: 'transparent' }, LineCapStyle: { Round: 'round' },
    FontWeight: { Bold: 'bold', Medium: 'medium' }, TextOverflow: { Ellipsis: 'ellipsis' },
    FlexAlign: { Center: 'center' }, TextAlign: { Start: 'start' }
  });
  Object.assign(view, { wide,
    observeComponentCreation2: fn => fn(1, true), ifElseBranchUpdateFunction: (_branch, fn) => fn() });
  view.initialRender(); assert.equal(stack.length, 0);
  return nodes;
}
(async () => {
  let view = page(); intent = 'voice-input'; await view.receiveLaunch();
  assert.deepEqual(view.events.slice(0, 2), ['saved', ['new', '']]);
  assert.equal(view.voiceRequest, 'new'); await view.receiveLaunch(); assert.equal(view.events.length, 4);
  console.log('PASS shortcut preserves old draft, creates a standalone chat and dispatches voice exactly once');

  view = page(); view.app.canNavigate = false; intent = 'new-chat'; await view.receiveLaunch();
  assert.equal(view.events.length, 1); assert.equal(view.events[0][0], 'toast');
  view.app.canNavigate = true; await view.receiveLaunch(); assert.equal(view.events.length, 1);
  view = page(); view.app.flushDraft = async () => { view.app.saveError = 'save failed'; };
  intent = 'voice-input'; await view.receiveLaunch();
  assert.deepEqual(view.events, [['toast', 'save failed']]); assert.equal(view.voiceRequest, '');
  console.log('PASS busy shortcuts do not run later; save failures do not create chats or open the microphone');

  view = page(); view.app.flushDraft = async () => { foreground = false; };
  intent = 'voice-input'; await view.receiveLaunch(); assert.equal(view.events.length, 0); foreground = true;
  console.log('PASS backgrounding during draft save cancels shortcut activation');

  view = page(); view.app.draft = 'Keep this draft'; view.app.busy = true;
  view.app.saveError = 'unsaved changes'; view.voiceRequest = 'old';
  intent = 'continue-chat'; await view.receiveLaunch();
  assert.deepEqual(view.events, ['navigation', ['drawer', false]]);
  assert.equal(view.app.active.id, 'old'); assert.equal(view.app.active.projectId, 'project');
  assert.equal(view.app.draft, 'Keep this draft'); assert.equal(view.app.saveError, 'unsaved changes');
  assert.equal(view.voiceRequest, ''); await view.receiveLaunch(); assert.equal(view.events.length, 2);
  for (const blocking of ['launching', 'receiving', 'onboardingActive']) {
    view = page(); view[blocking] = true; intent = 'continue-chat'; await view.receiveLaunch();
    assert.deepEqual(view.events, []);
  }
  view = page(); view.privacy.allowed = false; intent = 'continue-chat'; await view.receiveLaunch();
  assert.equal(intent, 'continue-chat'); assert.deepEqual(view.events, []);
  view.privacy.allowed = true; await view.receiveLaunch(); assert.equal(view.events.length, 2);
  console.log('PASS continue-chat preserves the active conversation and unsaved draft, including busy answers and consent gating');

  view = page(); intent = 'continue-chat'; notificationThreadId = 'completed';
  view.app.busy = true;
  view.session = { waitForIdle: async () => { throw Error('Navigation must not wait for other conversations'); } };
  view.app.selectThread = async id => { view.events.push(['selected', id]); view.app.active.id = id; return true; };
  await view.receiveLaunch();
  assert.deepEqual(view.events, ['saved', ['selected', 'completed'], 'navigation', ['drawer', false]]);
  assert.equal(view.app.active.id, 'completed'); assert.equal(view.launching, false);
  assert.equal(view.detailPaneOpen, false); assert.equal(view.workspaceOpen, true); assert.equal(view.editorDraft, 'Unsaved text');
  view = page(); intent = 'continue-chat'; notificationThreadId = 'deleted';
  view.app.selectThread = async () => { view.app.error = 'Conversation deleted'; return false; };
  await view.receiveLaunch(); assert.deepEqual(view.events, ['saved', ['toast', 'Conversation deleted']]);
  console.log('PASS notification click saves the draft and opens its conversation while another runs; missing conversations report failure');

  for (const docked of [false, true]) {
    view = page(); view.app.ready = true; view.app.busy = true;
    view.workbench = () => ({ docked });
    view.session = { canNavigate: true, waitForIdle: () => { throw Error('Share must not wait for background chats'); } };
    view.app.setDraft = value => { view.app.draft = value; };
    view.app.setAttachments = async items => { view.app.attachments = items; return true; };
    sharedInput = { text: '', attachments: [{ id: 'shared-file', original: true }] };
    await view.receiveShare();
    assert.equal(sharedInput, undefined); assert.equal(view.app.draft, '');
    assert.equal(view.app.attachments[0].id, 'shared-file'); assert.equal(view.app.active.id, 'new');
    assert.equal(view.detailPaneOpen, docked); assert.equal(view.workspaceOpen, true); assert.equal(view.editorDraft, 'Unsaved text');
  }
  console.log('PASS shared files reveal the phone chat, preserve editor drafts and retain docked tablet panes while other chats run');

  const panel = controller('views/ChatPanel', 'ChatPanel', ['receiveVoiceShortcut', 'speechAvailabilityChanged', 'speechThreadChanged']);
  let starts = 0, stops = 0, consumed = 0;
  panel.reading = { stop: () => stops++ }; panel.endSpeech = () => {}; panel.onHeaderProgress = () => {};
  panel.cancelAttachmentDrop = () => {};
  panel.enterVoiceMode = () => starts++; panel.onVoiceShortcutConsumed = () => consumed++;
  panel.voiceRequest = 'new'; panel.activeThreadId = 'old'; panel.thread = { id: 'old' }; panel.speechEnabled = false;
  panel.receiveVoiceShortcut(); assert.equal(starts, 0);
  panel.activeThreadId = 'new'; panel.thread.id = 'new'; panel.speechThreadChanged(); assert.equal(starts, 0);
  panel.speechEnabled = true; panel.speechAvailabilityChanged(); assert.equal(starts, 1); assert.equal(consumed, 1);
  panel.receiveVoiceShortcut(); panel.speechAvailabilityChanged(); assert.equal(starts, 1);
  panel.speechEnabled = false; panel.speechAvailabilityChanged(); assert.ok(stops >= 2);
  foreground = false; panel.voiceRequest = 'next'; panel.activeThreadId = 'next'; panel.thread.id = 'next';
  panel.speechEnabled = true; panel.receiveVoiceShortcut(); foreground = true; panel.receiveVoiceShortcut();
  assert.equal(starts, 1);
  console.log('PASS voice waits for the target chat and visible page; consumed or background requests cannot record again');

  const providerExports = {}, launchExports = {};
  const compile = source => ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 } }).outputText;
  vm.runInNewContext(compile(fs.readFileSync(path.join(root, 'entry/src/main/ets/entryformability/TinybotFormAbility.ets'), 'utf8')), {
    exports: providerExports, require: id => {
      assert.equal(id, '@kit.FormKit', 'Card provider must not load application services');
      return { FormExtensionAbility: class {}, formBindingData: { createFormBindingData: data => data },
        formInfo: { FormParam: { DIMENSION_KEY: 'ohos.extra.param.key.form_dimension' }, FormDimension: { Dimension_2_4: 3 }, FormState: { READY: 0 } } };
    }
  });
  vm.runInNewContext(compile(fs.readFileSync(path.join(root, 'entry/src/main/ets/services/LaunchActions.ets'), 'utf8')), { exports: launchExports });
  const actualLaunch = launchExports.LaunchActions, provider = new providerExports.default();
  for (const dimension of [2, 3]) {
    const data = provider.onAddForm({ parameters: { 'ohos.extra.param.key.form_dimension': dimension } });
    assert.equal(data.wide, dimension === 3);
    const links = card(data.wide).filter(node => node.type === 'FormLink');
    assert.deepEqual(links.map(node => node.value.params.tinybotAction),
      dimension === 3 ? ['new-chat', 'voice-input', 'continue-chat'] : ['new-chat', 'voice-input']);
    for (const link of links) {
      assert.equal(link.value.action, 'router'); assert.equal(link.value.abilityName, 'EntryAbility');
      assert.equal(link.props.height, 44); assert.ok(link.props.accessibilityText);
      actualLaunch.setForeground(false); actualLaunch.receive({ parameters: link.value.params });
      assert.equal(actualLaunch.take(), undefined);
      actualLaunch.setForeground(true); assert.equal(actualLaunch.take(), link.value.params.tinybotAction);
      assert.equal(actualLaunch.take(), undefined);
    }
  }
  const formConfig = JSON.parse(fs.readFileSync(path.join(root, 'entry/src/main/resources/base/profile/form_config.json'), 'utf8'));
  actualLaunch.setForeground(false);
  actualLaunch.receive({ parameters: { tinybotAction: 'continue-chat', tinybotThreadId: 'notification-chat' } });
  assert.equal(actualLaunch.take(), undefined);
  actualLaunch.setForeground(true); assert.equal(actualLaunch.take(), 'continue-chat');
  assert.equal(actualLaunch.takeThreadId(), 'notification-chat'); assert.equal(actualLaunch.takeThreadId(), undefined);
  actualLaunch.receive({ parameters: { tinybotAction: 'continue-chat', tinybotThreadId: 'stale' } });
  actualLaunch.receive({ parameters: { tinybotAction: 'continue-chat' } });
  assert.equal(actualLaunch.take(), 'continue-chat'); assert.equal(actualLaunch.takeThreadId(), undefined);
  assert.deepEqual(formConfig.forms[0].supportDimensions, ['2*2', '2*4']);
  assert.equal(formConfig.forms[0].isDynamic, false); assert.equal(formConfig.forms[0].updateEnabled, false);
  assert.equal(formConfig.forms[0].colorMode, 'auto');
  console.log('PASS real card provider dimensions, compiled static FormLink controls and cold/warm launch delivery');
})().catch(error => { console.error(error); process.exitCode = 1; });
