// Run directly with an optional screenshot directory, or through the browser suite.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { chromium } = require('playwright');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const ets = path.resolve(__dirname, '../entry/src/main/ets');
const raw = path.resolve(ets, '../resources/rawfile');
const accounts = [{ id: 'browser-fixture', name: 'Test account' }];
const modules = new Map([
  ['services/ProviderBalanceSource', { ProviderBalanceSource: { accounts: () => accounts } }],
  ['model/WorkspaceStore', {}], ['services/LifePanels', {}], ['services/WebUiPreflight', {}]
]);

function load(name) {
  name = path.posix.normalize(name);
  if (modules.has(name)) return modules.get(name);
  const exports = {};
  modules.set(name, exports);
  const file = path.join(ets, name + '.ets');
  const code = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
  }).outputText;
  vm.runInNewContext(code, { exports, require(id) {
    if (id === '@kit.ArkTS') return { util: { TextDecoder: { create: () => ({
      decodeToString: bytes => new TextDecoder().decode(bytes)
    }) } } };
    if (id.startsWith('.')) return load(path.posix.join(path.posix.dirname(name), id));
    throw Error('Unexpected widget dependency: ' + id);
  } }, { filename: file });
  return exports;
}

function browserFixture(name) {
  const file = path.join(__dirname, name + '.browser.js');
  return vm.runInThisContext(fs.readFileSync(file, 'utf8'), { filename: file });
}

async function main() {
  assert.ok(process.argv.length <= 3, 'Expected at most one screenshot directory');
  const output = process.argv[2];
  if (output) fs.mkdirSync(output, { recursive: true });
  const { BuiltinWidgets } = load('services/BuiltinWidgets');
  const { builtinWidgets, guideWidgets } = load('model/BuiltinWidgets');
  const { webUiHost } = load('model/WebUi');
  const service = new BuiltinWidgets({ resourceManager: {
    getRawFileContent: async name => new Uint8Array(fs.readFileSync(path.join(raw, name)))
  } });
  const definitions = {};
  for (const { id } of builtinWidgets().concat(guideWidgets())) definitions[id] = await service.definition(id);
  const host = webUiHost(fs.readFileSync(path.join(raw, 'interactive-web/host.js'), 'utf8'), '');
  const runWidgets = browserFixture('test-builtin-widgets');
  const balanceMotion = browserFixture('test-balance-panel-motion');
  const browser = await chromium.launch({ channel: 'msedge', headless: true });
  let watchdog;
  try {
    const page = await browser.newPage({ viewport: { width: 344, height: 600 } });
    const deadline = new Promise((_, reject) => {
      watchdog = setTimeout(() => reject(Error('Built-in widget browser tests did not finish')), 90000);
    });
    const start = performance.now();
    const checked = await Promise.race([runWidgets(page, host, definitions, output, balanceMotion), deadline]);
    console.log('PASS packaged widget and guide browser fixtures in ' + Math.round(performance.now() - start) + ' ms', checked);
  } finally {
    clearTimeout(watchdog);
    await browser.close();
  }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
