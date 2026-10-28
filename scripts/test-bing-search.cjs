// Exercise the real search transport, settings and browser ownership without a device.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets'), cache = new Map();
let clock = 0;
let nativeObservation;
const nativeWebview = { JsMessageType: { STRING: 3 }, WebviewController: class {
  getTitle() { return 'Bing'; } accessBackward() { return false; } accessForward() { return false; }
  async runJavaScriptExt() { return { getType: () => 3, getString: () => JSON.stringify(JSON.stringify(nativeObservation)) }; }
} };
class Clock extends Date { static now() { return clock; } }
function load(name) {
  const file = path.resolve(name.endsWith('.ets') ? name : name + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true
  } }).outputText, { exports, Error, Date: Clock, Observed: cls => cls, setTimeout: fn => setTimeout(fn, 1), clearTimeout,
    require: id => {
      if (id === '@kit.ArkWeb') return { webview: nativeWebview };
      if (id === '@kit.ImageKit') return {};
      assert.ok(id.startsWith('.')); return load(path.resolve(path.dirname(file), id));
    }
  }, { filename: file });
  return exports;
}
const from = name => load(path.join(root, name)), plain = value => JSON.parse(JSON.stringify(value));
const { BrowserSession } = from('services/BrowserSession');
const { BrowserSearchTransport } = from('services/BrowserSearchTransport');
const { WebSearchTools } = from('services/WebSearchTools');
const { Cancellation } = from('services/Cancellation');
const { saveSearchSettings } = from('services/SearchSettings');
const { defaultSearchConfig, validateSearchConfig, searchCredentialAlias } = from('model/WebSearch');
const { emptyData, parseAppData } = from('model/Conversation');
const { defaultProductivity } = from('model/Productivity');
const { defaultAssistantOptions } = from('model/AssistantOptions');
const { LogSanitizer, knownLogEvent } = from('model/DiagnosticLog');
const settle = () => new Promise(resolve => setImmediate(resolve));
const gate = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };
const source = { url: 'https://example.com/article', title: 'Article', snippet: 'Evidence' };
const result = (state = 'results') => ({ state, sources: state === 'results' ? [source] : [], candidates: state === 'results' ? 1 : 0, invalid: 0 });
function fixture(policy = 'enabled') {
  clock = 0;
  const browser = new BrowserSession(), cancellation = new Cancellation(), logs = [];
  const driver = {
    navigations: [], readCount: 0, observation: () => result(),
    async open(url) { this.navigations.push(url); this.url = url; },
    async snapshot(id) { return { snapshotId: id, url: this.url, title: 'Bing', text: '', elements: [], truncated: false, embeddedFrames: 0, trust: 'untrusted' }; },
    async readBingSearch(query, maximum) { this.readCount++; this.query = query; this.maximum = maximum; return this.observation(); },
    async act() {}, userBack() { return false; }, close() {}
  };
  browser.configure(async () => {}, (event, fields, error) => logs.push({ event, fields, error }));
  browser.attach(driver); browser.updatePolicy(policy);
  const transport = new BrowserSearchTransport(browser, 'thread');
  return { browser, cancellation, driver, logs, transport, search: () => transport.search('鸿蒙 & browser', 5, cancellation) };
}
(async () => {
  const draft = { provider: 'bing-browser', enabled: true, baseUrl: '', apiKey: '' };
  const data = emptyData(); let saved, removed = [];
  data.productivity = defaultProductivity(); data.productivity.options = defaultAssistantOptions();
  data.productivity.options.search = { provider: 'tavily', enabled: true, baseUrl: 'https://api.tavily.com', credentialAlias: 'old-key' };
  const vault = { read: async () => assert.fail('Built-in search must not read credentials'), write: async () => assert.fail('Must not create a key'), remove: async alias => removed.push(alias) };
  await saveSearchSettings(data, draft, vault, () => assert.fail('Must not create credential IDs'), async value => { saved = plain(value); });
  assert.deepEqual(saved.productivity.options.search, { provider: 'bing-browser', enabled: true,
    tavily: { baseUrl: 'https://api.tavily.com', credentialAlias: 'old-key' } });
  assert.deepEqual(removed, []);
  assert.deepEqual(plain(parseAppData(JSON.stringify(saved)).productivity.options.search), saved.productivity.options.search);
  assert.deepEqual(plain(defaultSearchConfig()), { provider: 'bing-browser', enabled: true });
  assert.deepEqual(plain(defaultSearchConfig('deepseek')), { provider: 'deepseek', enabled: false });
  assert.deepEqual(plain(defaultAssistantOptions().search), { provider: 'bing-browser', enabled: true });
  for (const field of ['baseUrl', 'credentialAlias', 'modelProviderId']) assert.throws(() => validateSearchConfig({ ...saved.productivity.options.search, [field]: 'invalid' }));
  assert.throws(() => searchCredentialAlias(saved.productivity.options.search, []));
  await assert.rejects(saveSearchSettings(emptyData(), { ...draft, apiKey: 'unneeded' }, vault, () => '', async () => {}));
  console.log('PASS keyless settings, persisted config validation and inactive API key retention');

  {
    const { NativeBrowserDriver } = from('services/NativeBrowserDriver');
    const browser = new BrowserSession(), driver = new NativeBrowserDriver(browser);
    browser.attach(driver); browser.updatePolicy('enabled'); browser.openForUser(); driver.pageEnd('https://www.bing.com/search?q=test');
    nativeObservation = result();
    assert.deepEqual(plain(await driver.readBingSearch('test', 5)), result());
    for (const malformed of [null, { ...result(), state: 'unknown' }, { ...result(), candidates: -1 },
      { ...result('results'), sources: [] }, { ...result('empty'), sources: [source] },
      { ...result(), sources: [{ ...source, url: 'javascript:alert(1)' }] }]) {
      nativeObservation = malformed;
      await assert.rejects(driver.readBingSearch('test', 5), error => error.code === 'INVALID_RESPONSE');
    }
    browser.close();
    console.log('PASS native ArkWeb extraction decoding and malformed response validation');
  }

  {
    const f = fixture(), tool = new WebSearchTools(f.transport, 'sequential');
    assert.equal(tool.definitions()[0].executionMode, 'sequential');
    assert.equal(new WebSearchTools(f.transport).definitions()[0].executionMode, 'parallel');
    const response = await tool.execute({ function: { name: 'search_web', arguments: JSON.stringify({ query: '鸿蒙 & browser', maxResults: 1 }) } }, f.cancellation);
    assert.deepEqual(JSON.parse(response), { sources: [source] });
    assert.equal(f.driver.navigations[0], 'https://www.bing.com/search?q=' + encodeURIComponent('鸿蒙 & browser'));
    assert.equal(f.driver.maximum, 1);
    const observed = f.logs.find(log => log.event === 'search_observed');
    assert.ok(knownLogEvent('browser', observed.event));
    assert.equal(new LogSanitizer().sanitize(observed.fields, undefined, true).status, 'results');
    f.browser.release(f.cancellation);
  }
  {
    const f = fixture(); f.driver.observation = () => result(f.driver.readCount === 1 ? 'pending' : 'empty');
    assert.deepEqual(plain(await f.search()), { sources: [] }); assert.equal(f.driver.readCount, 2);
  }
  for (const [state, code] of [['invalid_results', 'SEARCH_LAYOUT_CHANGED'], ['unexpected_page', 'SEARCH_PAGE_CHANGED'], ['pending', 'SEARCH_LAYOUT_CHANGED']]) {
    const f = fixture(); f.driver.observation = () => { clock += 11000; return { ...result(state), invalid: state === 'invalid_results' ? 1 : 0 }; };
    await assert.rejects(f.search(), error => error.code === code && error.details.version === '1');
  }
  console.log('PASS structured sources, serial tool mode, delayed results, explicit empty and layout/navigation errors');

  {
    const f = fixture('disabled'); await assert.rejects(f.search(), error => error.code === 'PERMISSION_DENIED'); assert.equal(f.driver.navigations.length, 0);
  }
  {
    const f = fixture('unset'); const pending = f.search(); await settle();
    assert.equal(f.browser.permissionPending, true); assert.equal(f.driver.navigations.length, 0);
    f.browser.cancelPermission(); await assert.rejects(pending, error => error.code === 'USER_DENIED'); f.browser.release(f.cancellation);
  }
  {
    const f = fixture(); f.browser.openForUser(); f.driver.url = 'https://example.com/user-work';
    const pending = f.search(); await settle(); assert.equal(f.driver.navigations.length, 0, 'Do not replace a user-owned page');
    f.browser.handoff(); await pending; assert.equal(f.driver.navigations.length, 1);
  }
  {
    const f = fixture(); f.driver.observation = () => result(f.driver.readCount === 1 ? 'verification' : 'results');
    const pending = f.search(); await settle();
    assert.equal(f.browser.owner, 'user'); assert.ok(f.browser.handoffReason); assert.equal(f.driver.readCount, 1);
    f.browser.handoff(); assert.equal((await pending).sources.length, 1); assert.equal(f.driver.navigations.length, 1, 'Resume the verified page without reopening it');
  }
  {
    const f = fixture(); f.driver.observation = () => result('verification');
    const pending = f.search(); await settle(); f.browser.handoff();
    await assert.rejects(pending, error => error.code === 'SEARCH_VERIFICATION_REQUIRED'); assert.equal(f.driver.readCount, 2);
  }
  {
    const f = fixture(); f.driver.observation = () => result('verification');
    const pending = f.search(); await settle(); f.cancellation.cancel();
    await assert.rejects(pending, error => error.code === 'CANCELLED'); assert.equal(f.browser.hasTask, false);
  }
  {
    const f = fixture(); f.driver.observation = () => result('pending');
    const pending = f.search(); await settle(); f.cancellation.cancel();
    await assert.rejects(pending, error => error.code === 'CANCELLED');
  }
  {
    const f = fixture(), hold = gate(); f.driver.observation = () => hold.promise;
    const pending = f.search(); await settle();
    await assert.rejects(f.search(), error => error.code === 'BROWSER_BUSY');
    const other = new BrowserSearchTransport(f.browser, 'other');
    await assert.rejects(other.search('other', 5, new Cancellation()), error => error.code === 'BROWSER_BUSY');
    f.browser.takeOver(); f.browser.handoff(); hold.resolve(result());
    await assert.rejects(pending, error => error.code === 'STALE_BROWSER_SNAPSHOT');
  }
  console.log('PASS permissions, user-owned pages, verification handoff, cancellation, concurrent ownership and stale extraction');
})().catch(error => { console.error(error); process.exitCode = 1; });
