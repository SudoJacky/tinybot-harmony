// Run after devecocli build --build-mode release. Exercise the actual obfuscated output.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '..');
const emitted = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/release');
const names = JSON.parse(fs.readFileSync(path.join(emitted, 'obfuscation/nameCache.json'), 'utf8'));
const cache = new Map();
function load(file) {
  file = path.resolve(file);
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  const code = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true }
  }).outputText;
  vm.runInNewContext(code, { exports, Observed: value => value, console, setTimeout, clearTimeout,
    require: id => {
      const normalized = /^@normalized:N&&&(.+)&$/.exec(id);
      if (normalized) return load(path.join(emitted, normalized[1] + '.ts'));
      if (id.startsWith('.')) return load(path.resolve(path.dirname(file), id + '.ts'));
      throw new Error('Unexpected release dependency: ' + id);
    }
  }, { filename: file });
  return exports;
}
function release(file, symbol) {
  const source = 'entry/src/main/ets/' + file + '.ets';
  const mapping = names[source];
  assert.ok(mapping, 'Missing release name mapping: ' + source);
  assert.ok(fs.statSync(path.join(emitted, mapping.obfName.replace(/\.ets$/, '.ts'))).mtimeMs >=
    fs.statSync(path.join(root, source)).mtimeMs, 'Rebuild release before testing: ' + source);
  const exported = names.PropertyCache[symbol];
  assert.ok(exported && exported !== symbol, 'Expected an obfuscated export: ' + symbol);
  const value = load(path.join(emitted, mapping.obfName.replace(/\.ets$/, '.ts')))[exported];
  assert.equal(typeof value, 'function', 'Missing release export: ' + symbol);
  return value;
}
const plain = value => JSON.parse(JSON.stringify(value));
const emptyData = release('model/Conversation', 'emptyData');
const parseAppData = release('model/Conversation', 'parseAppData');
const requestHistory = release('model/Conversation', 'requestHistory');
const data = plain(emptyData());
assert.deepEqual(Object.keys(data).sort(), ['activeThreadId', 'config', 'projects', 'threads', 'version']);
assert.equal(data.config.configured, false);
assert.equal(typeof data.config.credentialAlias, 'string');
data.config.userDocument = 'Keep my saved preferences.';
data.activeThreadId = 'saved-chat';
data.threads.push({ id: 'saved-chat', title: 'Saved conversation', updatedAt: 1, draft: 'Unsent text', messages: [
  { id: 'user-1', role: 'user', content: 'Saved question', status: 'complete', error: '' },
  { id: 'answer-1', role: 'assistant', content: 'Saved answer', status: 'complete', error: '' }
] });
const restored = plain(parseAppData(JSON.stringify(data)));
assert.deepEqual(restored, data);
assert.throws(() => parseAppData(JSON.stringify({ ...data, activeThreadId: 'missing' })));
assert.deepEqual(plain(requestHistory(restored.threads[0].messages, 'System instructions')), [
  { role: 'system', content: 'System instructions' }, { role: 'user', content: 'Saved question' },
  { role: 'assistant', content: 'Saved answer' }
]);
console.log('PASS obfuscated release reads existing conversation JSON, preserves drafts and settings, rejects invalid data and replays history');

const chatRequest = release('services/providers/ChatCompletionsProtocol', 'chatRequest');
const responsesRequest = release('services/providers/WireProtocols', 'responsesRequest');
const anthropicRequest = release('services/providers/WireProtocols', 'anthropicRequest');
const tools = [{ type: 'function', function: { name: 'read_file', description: 'Read text',
  parameters: { type: 'object', properties: { path: { type: 'string' } }, required: ['path'] } } }];
const messages = [{ role: 'user', content: 'Describe this', images: ['data:image/jpeg;base64,aGVsbG8='] }];
const chat = plain(chatRequest('test-model', messages, tools));
assert.equal(chat.model, 'test-model'); assert.equal(chat.stream, true);
assert.deepEqual(chat.messages[0].content[1], { type: 'image_url', image_url: { url: messages[0].images[0] } });
assert.deepEqual(chat.tools, tools); assert.equal(chat.tool_choice, 'auto');
const responses = plain(responsesRequest('test-model', messages, tools, 1024));
assert.equal(responses.max_output_tokens, 1024); assert.equal(responses.tools[0].name, 'read_file');
assert.equal(responses.input[0].content[1].image_url, messages[0].images[0]);
const anthropic = plain(anthropicRequest('test-model', messages, tools, 1024));
assert.equal(anthropic.max_tokens, 1024);
assert.deepEqual(anthropic.messages[0].content[1].source, { type: 'base64', media_type: 'image/jpeg', data: 'aGVsbG8=' });
assert.deepEqual(anthropic.tools[0].input_schema, tools[0].function.parameters);
console.log('PASS obfuscated release preserves all three model request schemas, tool parameters and image fields');

const Annotation = release('model/BrowserAnnotation', 'BrowserAnnotation');
const draft = new Annotation(); draft.begin(0.25, 0.5, 0.01); draft.move(0.75, 0.5); draft.end();
assert.deepEqual(plain(draft.strokes), [{ points: [{ x: 0.25, y: 0.5 }, { x: 0.75, y: 0.5 }], width: 0.01 }]);
draft.undo(); assert.equal(draft.dirty(), false);
console.log('PASS obfuscated release keeps annotation model properties and callbacks usable');

// Run the emitted ability startup: ambient global declarations must still resolve
// to the platform global object after top-level name obfuscation.
const initialized = [];
let privacyChanged;
const startupScope = { exports: {}, Date, AppStorage: { setOrCreate() {} }, require: id => {
  if (id === '@ohos:app.ability.UIAbility') return { default: class {} };
  if (id === '@ohos:web.webview') return { default: { WebviewController: {
    initializeWebEngine() { initialized.push('web'); }
  } } };
  const normalized = /^@normalized:N&&&(.+)&$/.exec(id);
  assert.ok(normalized, 'Unexpected ability dependency: ' + id);
  const dependency = Object.entries(names).find(([, mapping]) => mapping?.obfName?.replace(/\.ets$/, '') === normalized[1]);
  assert.ok(dependency, 'Missing ability dependency mapping: ' + id);
  const moduleName = path.basename(dependency[0], '.ets');
  const symbol = { NativeActions: 'ShareInbox', HostedPrivacy: 'hostedPrivacy', HuaweiAccount: 'huaweiAccount' }[moduleName] || moduleName;
  if (symbol === 'hostedPrivacy') {
    return { [names.PropertyCache[symbol] || symbol]: {
      initialize(_context, onChange) { privacyChanged = onChange; }
    } };
  }
  const implementation = symbol === 'Diagnostics' ? { log() {}, acceptsLog: () => false } : {
    initialize() { initialized.push(symbol); }, receive() {}, setForeground() {}, refresh() {}, activate() {}
  };
  return { [names.PropertyCache[symbol] || symbol]: implementation };
} };
const abilityMapping = names['entry/src/main/ets/entryability/EntryAbility.ets'];
const abilityFile = path.join(emitted, abilityMapping.obfName.replace(/\.ets$/, '.ts'));
vm.runInNewContext(ts.transpileModule(fs.readFileSync(abilityFile, 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, startupScope, { filename: abilityFile });
const ability = new startupScope.exports.default();
ability.context = { getApplicationContext: () => ({ filesDir: '/test/files' }) };
ability.onCreate({}, {});
assert.equal(startupScope._brushEngineContext, ability.context, 'Pen Kit receives the real global context');
assert.deepEqual(initialized, ['LanguagePreferences', 'AppearancePreferences']);
privacyChanged(true);
assert.deepEqual(initialized, ['LanguagePreferences', 'AppearancePreferences', 'DeveloperDiagnostics', 'web']);
privacyChanged(true);
assert.equal(initialized.filter(item => item === 'web').length, 1);
console.log('PASS obfuscated release initializes global Pen Kit context and preferences, defers business until consent, and starts Web only once');
