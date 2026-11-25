const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const loader = path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader');
const ts = require(path.join(loader, 'node_modules/typescript'));
const Ajv = require(require.resolve('ajv', { paths: [loader] }));
const root = path.resolve(__dirname, '../entry/src/main/ets');
const cache = new Map(), assets = new Map(), requests = [];
const response = data => ({ status: 200, text: JSON.stringify({ code: 0, data }) });
let respond = () => response({ info_list: [], is_end: true });
let failWrite = false;
let failFlush = false;
const prefs = new Map();
const adapters = {
  './CompatHttp': { CompatHttp: { async request(spec, registerAbort) {
    requests.push(spec);
    return respond(spec, registerAbort);
  } } },
  './CredentialStore': { CredentialStore: class {
    async readOptional(alias) { return assets.get(alias); }
    async write(alias, value) {
      if (failWrite) throw new Error('Asset store unavailable');
      assets.set(alias, value);
    }
    async update(alias, value) { return this.write(alias, value); }
    async remove(alias) { assets.delete(alias); }
  } },
  '@kit.ArkTS': { util: { TextEncoder: class { encodeInto(value) { return Buffer.from(value); } } } },
  '@kit.ArkData': { preferences: { getPreferencesSync: () => ({
    getSync: (key, fallback) => prefs.get(key) ?? fallback,
    putSync: (key, value) => prefs.set(key, value),
    async flush() { if (failFlush) throw new Error('Preferences unavailable'); }
  }) } }
};
function load(file) {
  file = path.resolve(file + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  const compiled = ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021
  } }).outputText;
  vm.runInNewContext(compiled, { exports, setTimeout, clearTimeout, console,
    require: id => adapters[id] || load(path.resolve(path.dirname(file), id)) }, { filename: file });
  return exports;
}

async function main() {
  const { ImaClient } = load(path.join(root, 'services/ImaClient'));
  const { ImaTools } = load(path.join(root, 'services/ImaTools'));
  const { Cancellation } = load(path.join(root, 'services/Cancellation'));
  const { ToolSet } = load(path.join(root, 'services/ToolSet'));
  const { KnowledgeBaseAccess, knowledgeBaseAccess } = load(path.join(root, 'services/KnowledgeBaseAccess'));
  knowledgeBaseAccess.initialize({});
  let client = new ImaClient();
  const settings = { clientId: 'test-client-A', enabled: true };
  const apiKey = 'test-key-A';
  const list = 'list_ima_knowledge_bases', browse = 'browse_ima_knowledge', search = 'search_ima_knowledge';
  let tools = new ToolSet([new ImaTools(client)]);
  const call = (name, args, signal = new Cancellation()) =>
    tools.execute({ id: name, type: 'function', function: { name, arguments: JSON.stringify(args) } }, signal).then(JSON.parse);

  assert.equal(await client.load(), undefined);
  assert.equal(tools.definitions().length, 0);
  await assert.rejects(call(list, {}), { code: 'TOOL_UNAVAILABLE' });
  await client.test(settings, apiKey, new Cancellation());
  assert.equal(assets.size, 0);
  assert.deepEqual(JSON.parse(requests.at(-1).body), { query: '', cursor: '', limit: 1 });

  const saved = await client.save(settings, apiKey);
  assert.equal(Object.hasOwn(saved, 'apiKey'), false);
  assert.equal(knowledgeBaseAccess.enabled, false);
  assert.equal(tools.definitions().length, 0);
  await knowledgeBaseAccess.setEnabled(true);
  const reopenedAccess = new KnowledgeBaseAccess();
  reopenedAccess.initialize({});
  assert.equal(reopenedAccess.enabled, true);
  failFlush = true;
  await assert.rejects(knowledgeBaseAccess.setEnabled(false), /Preferences unavailable/);
  failFlush = false;
  assert.equal(knowledgeBaseAccess.enabled, true);
  assert.equal(prefs.get('knowledgeBasesEnabled'), true);
  await assert.rejects(client.save({ ...settings, clientId: 'test-client-B' }, ''), /Client ID/);
  await assert.rejects(client.save(settings, 'injected\nheader'), /Client ID/);
  failWrite = true;
  await assert.rejects(client.save({ ...settings, enabled: false }, ''), /Asset store unavailable/);
  failWrite = false;
  assert.equal(client.enabled, true);

  client = new ImaClient();
  assert.equal((await client.load()).enabled, true);
  tools = new ToolSet([new ImaTools(client)]);
  const ajv = new Ajv({ strict: true });
  assert.equal(tools.definitions().length, 3);
  for (const tool of tools.definitions()) ajv.compile(tool.function.parameters);
  assert.equal((await call(list, { query: '  工作  ', cursor: 'next', limit: 3 })).is_end, true);
  assert.equal(requests.at(-1).url, 'https://ima.qq.com/openapi/wiki/v1/search_knowledge_base');
  assert.deepEqual(JSON.parse(requests.at(-1).body), { query: '工作', cursor: 'next', limit: 3 });
  assert.equal(requests.at(-1).headers['ima-openapi-clientid'], settings.clientId);
  assert.equal(requests.at(-1).headers['ima-openapi-apikey'], apiKey);
  assert.equal(requests.at(-1).redirect, 'refuse');
  assert.equal(requests.at(-1).method, 'POST');
  await call(browse, { knowledgeBaseId: 'kb', folderId: 'docs', limit: 50 });
  assert.deepEqual(JSON.parse(requests.at(-1).body), { cursor: '', knowledge_base_id: 'kb', folder_id: 'docs', limit: 50 });
  assert.match(requests.at(-1).url, /\/get_knowledge_list$/);
  await call(search, { knowledgeBaseId: 'kb', query: '会议纪要', cursor: 'next' });
  assert.deepEqual(JSON.parse(requests.at(-1).body), { cursor: 'next', knowledge_base_id: 'kb', query: '会议纪要' });
  assert.match(requests.at(-1).url, /\/search_knowledge$/);
  const count = requests.length;
  await assert.rejects(call(browse, { knowledgeBaseId: 'kb', limit: 51 }), { code: 'INVALID_ARGUMENTS' });
  await assert.rejects(call(search, { knowledgeBaseId: 'kb', query: ' ' }), { code: 'INVALID_ARGUMENTS' });
  await assert.rejects(call(list, { url: 'https://example.com' }), { code: 'INVALID_ARGUMENTS' });
  assert.equal(requests.length, count);

  respond = () => ({ status: 401, text: apiKey });
  await assert.rejects(call(list, {}), error => error.code === 'AUTH_REQUIRED' && !error.message.includes(apiKey));
  respond = () => ({ status: 200, text: JSON.stringify({ code: 110030, msg: 'denied ' + apiKey }) });
  await assert.rejects(call(list, {}), error => error.code === 'PERMISSION_DENIED' && !error.message.includes(apiKey));
  respond = () => ({ status: 200, text: '{"code":0}' });
  await assert.rejects(call(list, {}), { code: 'INVALID_RESPONSE' });

  let aborted = false;
  const signal = new Cancellation();
  respond = (_spec, abort) => new Promise(resolve => {
    abort(() => { aborted = true; resolve(response({})); });
    signal.cancel();
  });
  await assert.rejects(call(list, {}, signal), { code: 'CANCELLED' });
  assert.equal(aborted, true);

  let complete;
  let start;
  const started = new Promise(resolve => { start = resolve; });
  respond = () => new Promise(resolve => { complete = resolve; start(); });
  const running = call(list, {});
  await started;
  await knowledgeBaseAccess.setEnabled(false);
  assert.equal(tools.definitions().length, 0);
  await assert.rejects(call(list, {}), { code: 'TOOL_UNAVAILABLE' });
  assert.equal((await client.load()).enabled, true);
  assert.equal(assets.size, 1);
  await knowledgeBaseAccess.setEnabled(true);
  assert.equal(tools.definitions().length, 3);
  complete(response({ info_list: [{ name: 'private result' }], is_end: true }));
  await assert.rejects(running, { code: 'NOT_CONFIGURED' });
  await client.save({ ...settings, enabled: false }, '');
  assert.equal(tools.definitions().length, 0);
  await client.remove();
  assert.equal(assets.size, 0);
  console.log('PASS ima settings, request contracts, credential persistence, cancellation and both access gates');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
