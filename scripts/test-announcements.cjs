// Exercise the real feed parser, native transport/preferences adapter and startup dialog handler.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets');
const compile = source => ts.transpileModule(source, { compilerOptions: {
  target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS, experimentalDecorators: true
} }).outputText;
function load(file, imports = {}) {
  const exports = {};
  vm.runInNewContext(compile(fs.readFileSync(path.join(root, file), 'utf8')), { exports, Observed: value => value,
    require: id => { if (!(id in imports)) throw Error('Unexpected dependency: ' + id); return imports[id]; }
  });
  return exports;
}
const model = load('model/Announcement.ets');
const { WorkbenchLayout } = load('model/WorkbenchLayout.ets');
const notice = (id = 'notice-1', body = 'Maintenance tonight') => ({ id, title: 'Service notice', body });
const feed = item => JSON.stringify({ schemaVersion: 1, announcement: item });
assert.equal(model.parseAnnouncement(feed(null)), null);
assert.equal(model.parseAnnouncement(feed(notice())).id, 'notice-1');
assert.equal(model.parseAnnouncement(feed(notice('long', '长'.repeat(20000)))).body.length, 20000);
for (const source of ['{', '{}', 'null', feed({ ...notice(), id: '' }), feed({ ...notice(), body: ' ' }),
  feed({ ...notice(), title: 3 }), feed({ ...notice(), body: 'x'.repeat(20001) }), '{"schemaVersion":2,"announcement":null}']) {
  assert.throws(() => model.parseAnnouncement(source));
}
let disk = new Map(), working = new Map(), failFlush = false, requests = 0, destroyed = 0, pendingResponse;
let result = { responseCode: 200, result: feed(notice()) };
const privacy = { allowed: false }, logs = [];
const diagnostics = { log: (...args) => logs.push(args) };
const store = {
  getSync: (key, fallback) => working.has(key) ? working.get(key) : fallback,
  putSync: (key, value) => working.set(key, value.slice()),
  flushSync() { if (failFlush) throw Error('disk failure'); disk = new Map(working); }
};
// The transport itself is covered by test-compat-http.cjs. Here the feed logic only needs the
// contract it depends on: one redirect-refusing GET with the 256 KiB ceiling and a text body.
const compatHttp = { request: async spec => {
  requests++;
  assert.equal(spec.url, 'https://notices.example/feed.json');
  assert.equal(spec.method, 'GET'); assert.equal(spec.redirect, 'refuse');
  assert.equal(spec.connectTimeout, 5000); assert.equal(spec.readTimeout, 5000);
  assert.equal(spec.maxBytes, 262144); assert.equal(spec.dataType, 'string');
  destroyed++;
  const response = pendingResponse ? await pendingResponse : result;
  return { status: response.responseCode, header: {}, text: response.result, bytes: new ArrayBuffer(0) };
} };
const { Announcements } = load('services/Announcements.ets', {
  '@kit.ArkData': { preferences: { getPreferencesSync: () => store } },
  '../model/Announcement': model, '../model/Diagnostics': { Diagnostics: diagnostics },
  '../model/I18n': { t: key => key }, './HostedPrivacy': { hostedPrivacy: privacy },
  './CompatHttp': { CompatHttp: compatHttp }
});
const fresh = () => new Announcements('https://notices.example/feed.json');
const tick = () => new Promise(resolve => setImmediate(resolve));
(async () => {
  const service = fresh(); await service.checkOnStartup({}); assert.equal(requests, 0, 'Consent precedes network');
  privacy.allowed = true;
  await new Announcements('').checkOnStartup({}); assert.equal(requests, 0, 'Unconfigured endpoint performs no I/O');
  const invalidEndpoint = new Announcements('http://notices.example/feed.json'); await invalidEndpoint.checkOnStartup({});
  assert.ok(invalidEndpoint.error); assert.equal(requests, 0);
  await Promise.all([service.checkOnStartup({}), service.checkOnStartup({})]);
  await service.checkOnStartup({}); assert.equal(requests, 1, 'One attempt per process, including foreground callbacks');
  assert.equal(destroyed, 1); assert.equal(service.pending().id, 'notice-1');
  service.didOffer(); assert.equal(service.pending(), null); assert.equal(disk.size, 0, 'Display alone does not persist acknowledgement');
  const interrupted = fresh(); await interrupted.checkOnStartup({}); assert.equal(interrupted.pending().id, 'notice-1');
  failFlush = true; assert.throws(() => interrupted.acknowledge('notice-1'), /无法保存/);
  assert.equal(interrupted.pending().id, 'notice-1'); assert.equal(working.get('seenAnnouncementIds').length, 0);
  failFlush = false; interrupted.acknowledge('notice-1'); working = new Map(disk);
  result.result = feed(notice('notice-1', 'Corrected copy'));
  const reread = fresh(); await reread.checkOnStartup({}); assert.equal(reread.pending(), null, 'Same ID stays read after editing');
  assert.equal(reread.current.body, 'Corrected copy');
  result.result = feed(notice('notice-2'));
  const next = fresh(); await next.checkOnStartup({}); assert.equal(next.pending().id, 'notice-2'); next.acknowledge('notice-2');
  result.result = feed(notice('notice-1'));
  const rollback = fresh(); await rollback.checkOnStartup({}); assert.equal(rollback.pending(), null, 'Republished old IDs stay read');
  result.result = feed(null); const withdrawn = fresh(); await withdrawn.checkOnStartup({}); assert.equal(withdrawn.current, null); assert.equal(withdrawn.error, '');
  for (const bad of [{ responseCode: 503, result: '' }, { responseCode: 200, result: '{' }]) {
    result = bad; const failed = fresh(); await failed.checkOnStartup({}); const count = requests;
    await failed.checkOnStartup({}); assert.equal(requests, count); assert.ok(failed.error); assert.equal(failed.pending(), null);
  }
  let reject; pendingResponse = new Promise((_, fail) => { reject = fail; });
  const timeout = fresh(), timeoutCheck = timeout.checkOnStartup({}); reject(Error('network timeout')); await timeoutCheck;
  assert.ok(timeout.error); pendingResponse = undefined;
  assert.equal(destroyed, requests, 'Every success and failure destroys its request');
  let resolve; pendingResponse = new Promise(done => { resolve = done; });
  const revoked = fresh(), check = revoked.checkOnStartup({}); privacy.allowed = false;
  resolve({ responseCode: 200, result: feed(notice('notice-3')) }); await check;
  assert.equal(revoked.current, null, 'Late completion cannot publish after consent withdrawal'); pendingResponse = undefined;
  assert.ok(logs.some(log => log[2] === 'fetch_failed' && log[3].http === 503));
  assert.ok(logs.some(log => log[2] === 'save_failed'));
  console.log('PASS feed validation, startup deduplication, persistent IDs, failed saves, withdrawal, HTTP/parse/timeout failures and resource cleanup');

  privacy.allowed = true; result = { responseCode: 200, result: feed(notice('notice-ui')) };
  const uiService = fresh(); await uiService.checkOnStartup({});
  const source = fs.readFileSync(path.join(root, 'pages/Index.ets'), 'utf8').replace(/\r\n/g, '\n');
  const method = source.slice(source.indexOf('  private offerAnnouncement('), source.indexOf('  private onboardingPreferences('));
  const exports = {}, dialogs = [];
  let depth = 0, failDialog = false, dark = false;
  class Controller {
    constructor(options) { this.options = options; this.closed = false; }
    open() { if (failDialog) throw Error('No window'); dialogs.push(this); }
    close() { this.closed = true; this.options.onDidDisappear(); }
  }
  const uiGlobals = {
    exports, announcements: uiService, Diagnostics: diagnostics, CustomDialogController: Controller,
    AnnouncementDialog: props => props, DialogAlignment: { Center: 'center' }, WorkbenchLayout,
    BlurStyle: { COMPONENT_ULTRA_THICK: 'ultra-thick' }, ThemeColorMode: { DARK: 'dark', LIGHT: 'light' },
    AppStorage: { get: key => { assert.equal(key, 'tinybot.appearance.dark'); return dark; } }
  };
  vm.runInNewContext(compile('export class Probe {\n' + method + '\n}'), uiGlobals);
  const probe = Object.assign(new exports.Probe(), { privacy, foreground: true, app: { ready: true }, onboardingChecked: true,
    paths: { size: () => depth }, appearance: { surface: 0, noMaterial: 'empty-material' }, windowWidth: 390 });
  for (const field of ['foreground', 'onboardingChecked']) {
    probe[field] = false; probe.offerAnnouncement(); probe[field] = true;
  }
  probe.app.ready = false; probe.offerAnnouncement(); probe.app.ready = true;
  privacy.allowed = false; probe.offerAnnouncement(); privacy.allowed = true;
  depth = 1; probe.offerAnnouncement(); depth = 0;
  assert.equal(dialogs.length, 0, 'Wait for consent, foreground, local data and onboarding/navigation');
  failDialog = true; probe.offerAnnouncement(); assert.ok(uiService.pending(), 'Failed presentation cannot consume an announcement');
  failDialog = false; probe.offerAnnouncement(); probe.offerAnnouncement();
  assert.equal(dialogs.length, 1, 'Do not open again while the native dialog is mounting');
  const dialog = dialogs[0];
  assert.equal(dialog.options.systemMaterial, 'empty-material');
  assert.equal(dialog.options.backgroundBlurStyle, 'ultra-thick');
  assert.equal(dialog.options.backgroundBlurStyleOptions.colorMode, 'light');
  assert.equal(dialog.options.width, undefined, 'Phone announcements retain the platform width');
  assert.equal(dialog.options.builder.announcement.body, notice().body);
  assert.ok(uiService.pending(), 'Only a visible dialog consumes the per-launch offer');
  dialog.options.onDidAppear(); assert.equal(uiService.pending(), null);
  const dialogSource = fs.readFileSync(path.join(root, 'views/AnnouncementDialog.ets'), 'utf8');
  const confirm = dialogSource.slice(dialogSource.indexOf('  private confirm('), dialogSource.indexOf('  build()'));
  const componentExports = {};
  vm.runInNewContext(compile('export class Probe {\n' + confirm + '\n}'), { exports: componentExports });
  const content = Object.assign(new componentExports.Probe(), { onConfirm: dialog.options.builder.onConfirm, error: '' });
  failFlush = true; content.confirm(); assert.match(content.error, /无法保存/);
  assert.equal(dialog.closed, false, 'Failed acknowledgement leaves the dialog open for retry');
  failFlush = false; content.confirm(); assert.equal(content.error, ''); assert.equal(dialog.closed, true);
  assert.equal(probe.announcementDialog, undefined);
  const restart = fresh(); await restart.checkOnStartup({}); assert.equal(restart.pending(), null);
  for (const [windowWidth, expectedWidth] of [[1024, 717], [1440, 800]]) {
    dark = windowWidth === 1440;
    result.result = feed(notice('notice-tablet-' + windowWidth));
    const tabletService = fresh();
    await tabletService.checkOnStartup({});
    uiGlobals.announcements = tabletService;
    probe.windowWidth = windowWidth;
    probe.offerAnnouncement();
    const tabletDialog = dialogs.at(-1);
    assert.equal(tabletDialog.options.backgroundBlurStyleOptions.colorMode, dark ? 'dark' : 'light');
    assert.equal(tabletDialog.options.width, expectedWidth, 'Announcement controller receives the tablet width');
    tabletDialog.options.onDidAppear();
    tabletDialog.options.builder.onConfirm();
  }
  probe.announcementDialog = new Controller({ onDidDisappear: () => { probe.announcementDialog = undefined; } });
  const abandoned = probe.announcementDialog; probe.closeAnnouncement(); assert.equal(abandoned.closed, true);
  assert.match(source.slice(source.indexOf('  private privacyChanged('), source.indexOf('  private offerOnboarding(')),
    /this\.closeAnnouncement\(\);/, 'Privacy withdrawal closes the dialog');
  assert.match(source.slice(source.indexOf('  aboutToDisappear('), source.indexOf('  private setDrawer(')),
    /this\.closeAnnouncement\(\);/, 'Page teardown closes the dialog');
  console.log('PASS custom dialog startup gating, mounting deduplication, actual appearance, failed-save retry and lifecycle cleanup');

  // Inspect the actual ArkUI-emitted tree: the action must remain outside the scrolling content.
  const emitted = path.resolve(__dirname, '../entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/views/AnnouncementDialog.ts');
  assert.ok(fs.statSync(emitted).mtimeMs >= fs.statSync(path.join(root, 'views/AnnouncementDialog.ets')).mtimeMs, 'Build before testing the dialog renderer');
  const tree = ts.createSourceFile(emitted, fs.readFileSync(emitted, 'utf8'), ts.ScriptTarget.Latest, true);
  const component = tree.statements.find(node => ts.isClassDeclaration(node) && node.name.text === 'AnnouncementDialog');
  const methods = component.members.filter(node => ['initialRender', 'confirm'].includes(node.name?.getText(tree))).map(node => node.getText(tree)).join('\n');
  const nodes = [], stack = [], rendererExports = {};
  const element = type => new Proxy({}, { get: (_, key) => (...args) => {
    if (key === 'create' || key === 'createWithLabel') {
      const node = { type, value: args[0], parent: stack.at(-1), props: {} }; nodes.push(node); stack.push(node);
    } else if (key === 'pop') { assert.equal(stack.pop().type, type); }
    else { stack.at(-1).props[key] = args[0]; }
  } });
  class Markdown { constructor(_parent, params) { this.type = 'Markdown'; this.params = params; } }
  class ErrorBanner { constructor(_parent, params) { this.type = 'Banner'; this.params = params; } }
  vm.runInNewContext(compile('export class Renderer {\n' + methods + '\n}'), { exports: rendererExports,
    ...Object.fromEntries(['Flex', 'Text', 'Scroll', 'Column', 'Row', 'If', 'Button'].map(type => [type, element(type)])),
    Image: new Proxy({}, { get: (_, key) => (...args) => {
      if (key === 'create') nodes.push({ type: 'Image', value: args[0], parent: stack.at(-1), props: {} });
      else nodes.at(-1).props[key] = args[0];
    } }),
    TextAlign: { Center: 'center' }, VerticalAlign: { Center: 'center' },
    FlexDirection: { Column: 'column' }, FontWeight: { Bold: 'bold' }, TextOverflow: { Ellipsis: 'ellipsis' },
    Alignment: { TopStart: 'top-start' }, BarState: { Auto: 'auto' }, EdgeEffect: { None: 'none' },
    Space: { xl: 24, lg: 16, sm: 8 }, Font: { title: 17, body: 16 }, Btn: { primary: 'primary' }, t: key => key,
    MarkdownView: Markdown, Banner: ErrorBanner, ViewPU: { create: view => nodes.push({ ...view, parent: stack.at(-1) }) }
  });
  const longBody = '# Maintenance\n\n' + 'Long **announcement** paragraph.\n\n'.repeat(500) + '## Final section\n\nLast line.';
  let clicks = 0;
  const renderer = Object.assign(new rendererExports.Renderer(), { announcement: notice('long-ui', longBody), error: '',
    titleHeight: 0, bodyHeight: 0, footerHeight: 0,
    appearance: { fontFamily: 'system' }, onConfirm: () => clicks++,
    observeComponentCreation2: callback => callback(1, true), ifElseBranchUpdateFunction: (_branch, callback) => callback() });
  renderer.initialRender(); assert.equal(stack.length, 0);
  const nodeById = id => nodes.find(node => node.props?.id === id);
  const scroll = nodeById('announcement-body'), button = nodeById('announcement-confirm');
  assert.equal(nodeById('announcement-dialog').props.constraintSize.maxHeight, '80%');
  assert.equal(nodeById('announcement-dialog').type, 'Column');
  assert.equal(nodeById('announcement-dialog').props.height, 240, 'Short content has a minimum desired height');
  assert.equal(scroll.props.layoutWeight, 1);
  assert.equal(button.parent.parent, scroll.parent, 'Footer is a sibling of the body, never scrolled away');
  assert.equal(button.parent.props.layoutWeight, undefined, 'Only the body takes remaining space');
  nodeById('announcement-header').props.onAreaChange({}, { height: 26 });
  nodeById('announcement-content').props.onAreaChange({}, { height: 480 });
  nodeById('announcement-footer').props.onAreaChange({}, { height: 48 });
  nodes.length = 0; renderer.initialRender();
  assert.equal(nodeById('announcement-dialog').props.height, 634, 'Desired height follows measured Markdown and fixed controls');
  assert.equal(nodeById('announcement-dialog').props.constraintSize.maxHeight, '80%', 'Long content remains capped by the viewport');
  assert.equal(nodes.find(node => node.type === 'Markdown').params.content, longBody, 'Long Markdown reaches the renderer without truncation');
  button.props.onClick(); assert.equal(clicks, 1);
  nodes.length = 0; renderer.error = 'Save failed'; renderer.initialRender();
  assert.equal(nodes.find(node => node.type === 'Banner').params.text, 'Save failed');
  const markdown = load('model/Markdown.ets');
  const blocks = markdown.markdownBlocks(longBody);
  assert.equal(blocks.at(-1).text, 'Last line.', 'The final paragraph survives Markdown parsing');
  assert.ok(blocks.some(block => block.kind === 'heading'));
  console.log('PASS emitted bounded dialog, independent Markdown scroll, fixed action, visible errors and complete long content');
})().catch(error => { console.error(error); process.exitCode = 1; });
