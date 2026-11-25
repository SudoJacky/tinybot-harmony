const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
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
const transferred = [], temporary = new Map(), workspaceFiles = new Map(), approvals = [];
let rejectApproval = false;
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
  '@kit.ArkTS': { url: { URL: { parseURL: value => new URL(value) } },
    util: { generateRandomUUID: crypto.randomUUID, TextEncoder: class { encodeInto(value) { return Buffer.from(value); } } } },
  '@kit.CoreFileKit': { fileIo: {
    OpenMode: { READ_ONLY: 1, NOFOLLOW: 2 }, async access(file) { return temporary.has(file); },
    async unlink(file) { temporary.delete(file); }, async stat(file) { return { size: temporary.get(file).length }; },
    async open(file) { return { fd: file }; }, async close() {}
  } },
  './DocumentFiles': { readDocumentFile: async fd => temporary.get(fd).toString('utf8') },
  '@kit.CryptoArchitectureKit': { cryptoFramework: {
    createMd: algorithm => {
      const hash = crypto.createHash(algorithm);
      return { update: ({ data }) => hash.update(data), digest: () => ({ data: hash.digest() }) };
    },
    createSymKeyGenerator: () => ({ convertKey: ({ data }) => data }),
    createMac: algorithm => {
      let hmac;
      return { init: key => { hmac = crypto.createHmac(algorithm, key); },
        update: ({ data }) => hmac.update(data), doFinal: () => ({ data: hmac.digest() }) };
    }
  } },
  '@kit.RemoteCommunicationKit': { rcp: {
    UploadFromFile: class { constructor(fd) { this.fd = fd; } },
    createSession: config => ({
      async put(url, body) {
        transferred.push({ url, config, body });
        return { statusCode: 200, headers: {} };
      },
      async downloadToFile(url, { file }) {
        transferred.push({ url, config, file });
        temporary.set(file, Buffer.from('Original document'));
        return { statusCode: 200, headers: { 'content-type': 'text/plain; charset=UTF-8' } };
      },
      cancel() {}, close() {}
    })
  } },
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
  const { ImaKnowledge } = load(path.join(root, 'services/ImaKnowledge'));
  const { Cancellation } = load(path.join(root, 'services/Cancellation'));
  const { ToolSet } = load(path.join(root, 'services/ToolSet'));
  const { RuleTools } = load(path.join(root, 'services/RuleTools'));
  const { KnowledgeBaseAccess, knowledgeBaseAccess } = load(path.join(root, 'services/KnowledgeBaseAccess'));
  knowledgeBaseAccess.initialize({});
  let client = new ImaClient();
  const settings = { clientId: 'test-client-A', enabled: true };
  const apiKey = 'test-key-A';
  const list = 'list_ima_knowledge_bases', browse = 'browse_ima_knowledge', search = 'search_ima_knowledge';
  const workspace = {
    async withJobInput(path, maximum, _signal, transfer) {
      assert.equal(path, 'folder/report.pdf'); assert.equal(maximum, 200 * 1024 * 1024);
      return transfer(41, 123, 1720000000);
    },
    async importFile(source, destination) { workspaceFiles.set(destination, temporary.get(source)); },
    async createJobOutput(path, bytes) { workspaceFiles.set(path, Buffer.from(bytes)); }
  };
  const bind = () => new ToolSet([new ImaTools(client, new ImaKnowledge(client, workspace, '/cache', async (title, detail) => {
    approvals.push([title, detail]);
    if (rejectApproval) throw Object.assign(new Error('Denied'), { code: 'USER_DENIED' });
  }))]);
  let tools = bind();
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
  tools = bind();
  const ajv = new Ajv({ strict: true });
  assert.equal(tools.definitions().length, 11);
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

  await call('get_ima_knowledge_base_details', { knowledgeBaseIds: ['kb'] });
  assert.deepEqual(JSON.parse(requests.at(-1).body), { ids: ['kb'] });
  await call('list_ima_writable_knowledge_bases', {});
  assert.deepEqual(JSON.parse(requests.at(-1).body), { cursor: '', limit: 50 });
  await call('check_ima_duplicate_files', { knowledgeBaseId: 'kb', folderId: 'docs', fileNames: ['report.pdf', 'notes.md'] });
  assert.deepEqual(JSON.parse(requests.at(-1).body), { knowledge_base_id: 'kb', folder_id: 'docs',
    params: [{ name: 'report.pdf', media_type: 1 }, { name: 'notes.md', media_type: 7 }] });

  respond = spec => spec.url.endsWith('/get_media_info') ?
    response({ media_type: 11, notebook_ext_info: { notebook_id: 'note-a' } }) : response({ content: 'IMA note' });
  assert.deepEqual(await call('read_ima_knowledge', {mediaId: 'note-media'}), { mediaId: 'note-media', content: 'IMA note', truncated: false });
  assert.match(requests.at(-1).url, /\/note\/v1\/get_doc_content$/);
  assert.deepEqual(JSON.parse(requests.at(-1).body), { note_id: 'note-a', target_content_format: 0 });
  await call('download_ima_knowledge', { mediaId: 'note-media', fileName: 'note.txt' });
  assert.equal(workspaceFiles.get('ima/note.txt').toString(), 'IMA note');
  respond = () => response({ media_type: 1 });
  await assert.rejects(call('read_ima_knowledge', {mediaId: 'forbidden'}), { code: 'PERMISSION_DENIED' });
  respond = () => response({ media_type: 13, url_info: { url: 'https://files.example.com/original.txt?token=temporary',
    headers: { Authorization: 'Bearer media-scope' } } });
  const downloaded = await call('download_ima_knowledge', { mediaId: 'text', fileName: 'original.txt' });
  assert.deepEqual(downloaded, { mediaId: 'text', path: 'ima/original.txt' });
  assert.equal(workspaceFiles.get(downloaded.path).toString(), 'Original document');
  assert.equal((await call('read_ima_knowledge', { mediaId: 'text' })).content, 'Original document');
  assert.equal(temporary.size, 0, 'Originals are cleaned up after parsing and file delivery');
  assert.equal(transferred.at(-1).config.headers.Authorization, 'Bearer media-scope');
  assert.equal(transferred.at(-1).config.headers['ima-openapi-apikey'], undefined);
  assert.equal(transferred.at(-1).config.requestConfiguration.transfer.autoRedirect, false);
  await assert.rejects(call('download_ima_knowledge', { mediaId: 'text', fileName: '../secret' }), { code: 'INVALID_ARGUMENTS' });

  respond = () => response({ results: { 'https://example.com/a': { ret_code: 0, media_id: 'article' },
    'https://example.com/b': { ret_code: 110001 } } });
  const imported = await call('import_ima_links', { knowledgeBaseId: 'kb', urls: ['https://example.com/a', 'https://example.com/b'] });
  assert.equal(imported.results['https://example.com/b'].ret_code, 110001, 'Partial imports keep per-URL results');
  assert.equal(JSON.parse(requests.at(-1).body).folder_id, 'kb');
  await assert.rejects(call('import_ima_links', { knowledgeBaseId: 'kb', urls: ['https://www.youtube.com/watch?v=x'] }), { code: 'INVALID_ARGUMENTS' });
  await call('add_ima_reference', { knowledgeBaseId: 'kb', kind: 'note', referenceId: 'note-a', title: 'Note' });
  assert.deepEqual(JSON.parse(requests.at(-1).body), {
    knowledge_base_id: 'kb', title: 'Note', media_type: 11, note_info: { content_id: 'note-a' }
  });
  await call('add_ima_reference', { knowledgeBaseId: 'kb', kind: 'session', referenceId: 'chat-a', title: 'Chat' });
  assert.deepEqual(JSON.parse(requests.at(-1).body).session_info, { content_id: 'chat-a' });
  const beforeDenied = requests.length;
  rejectApproval = true;
  await assert.rejects(call('upload_ima_file', { knowledgeBaseId: 'kb', path: 'folder/report.pdf' }), { code: 'USER_DENIED' });
  rejectApproval = false;
  assert.equal(requests.length, beforeDenied, 'Approval precedes all traffic for an upload');
  const readOnlyTools = new RuleTools(tools, true);
  assert.ok(readOnlyTools.definitions().some(def => def.function.name === 'read_ima_knowledge'));
  await assert.rejects(readOnlyTools.execute({ id: 'write', function: { name: 'import_ima_links', arguments: '{}' } },
    new Cancellation()), { code: 'PERMISSION_DENIED' });

  let sameName = true;
  respond = spec => {
    if (spec.url.endsWith('/check_repeated_names')) return response({ results: [{ name: 'report.pdf', is_repeated: sameName }] });
    if (spec.url.endsWith('/create_media')) return response({ media_id: 'pending', cos_credential: {
      token: 'cos-token', secret_id: 'cos-id', secret_key: 'cos-secret', bucket_name: 'ima-100', region: 'ap-guangzhou',
      cos_key: 'key/report.pdf', start_time: 1720000000, expired_time: 1720000100
    } });
    return response({ media_id: 'uploaded' });
  };
  await assert.rejects(call('upload_ima_file', { knowledgeBaseId: 'kb', path: 'folder/report.pdf' }), { code: 'ALREADY_EXISTS' });
  assert.match(requests.at(-1).url, /check_repeated_names$/);
  sameName = false;
  const uploaded = await call('upload_ima_file', { knowledgeBaseId: 'kb', path: 'folder/report.pdf', folderId: 'docs' });
  assert.deepEqual(uploaded, { mediaId: 'uploaded', fileName: 'report.pdf' });
  assert.deepEqual(requests.slice(-3).map(spec => spec.url.split('/').at(-1)), ['check_repeated_names', 'create_media', 'add_knowledge']);
  assert.equal(JSON.parse(requests.at(-1).body).file_info.cos_key, 'key/report.pdf');
  assert.equal(JSON.parse(requests.at(-1).body).title, 'report.pdf');
  assert.equal(transferred.at(-1).url, 'https://ima-100.cos.ap-guangzhou.myqcloud.com/key/report.pdf');
  assert.equal(transferred.at(-1).body.fd, 41);
  assert.equal(transferred.at(-1).config.headers['ima-openapi-clientid'], undefined);
  assert.match(transferred.at(-1).config.headers.Authorization, /q-signature=cc106e7afcf11a402b251339b86cecb3a1f04eb2$/);
  assert.ok(approvals.length >= 5);
  console.log('PASS ima details, writable folders, originals, download, imports, approval, read-only and signed file upload');

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
  assert.equal(tools.definitions().length, 11);
  complete(response({ info_list: [{ name: 'private result' }], is_end: true }));
  await assert.rejects(running, { code: 'NOT_CONFIGURED' });
  await client.save({ ...settings, enabled: false }, '');
  assert.equal(tools.definitions().length, 0);
  await client.remove();
  assert.equal(assets.size, 0);
  console.log('PASS ima settings, request contracts, credential persistence, cancellation and both access gates');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
