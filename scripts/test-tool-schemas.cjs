// Validate the schemas sent to providers and execute the same native parameter shapes.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const loader = path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader');
const ts = require(path.join(loader, 'node_modules/typescript'));
const Ajv = require(require.resolve('ajv', { paths: [loader] }));
const ajv = new Ajv({ strict: true });
const root = path.resolve(__dirname, '../entry/src/main/ets'), cache = new Map();
function load(file) {
  file = path.resolve(file.endsWith('.ets') ? file : file + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true
  } }).outputText, { exports, Observed: cls => cls, console, setTimeout, clearTimeout, require: id => {
    if (id.endsWith('/I18n')) return { t: (key, values = []) => key.replace(/\{(\d+)\}/g, (_, n) => values[n]) };
    if (!id.startsWith('.')) throw Error('Unexpected native dependency: ' + id);
    return load(path.resolve(path.dirname(file), id));
  } }, { filename: file });
  return exports;
}
const from = name => load(path.join(root, name));
const { InteractionTools } = from('services/InteractionTools');
const { MemoryTools } = from('services/MemoryTools');
const { ResourceTools } = from('services/ResourceTools');
const { CodeExecutionTools } = from('services/CodeExecutionTools');
const { WorkspaceTools } = from('services/WorkspaceTools');
const { McpTools } = from('services/McpTools');
const { ToolApproval } = from('services/ToolApproval');
const { Cancellation } = from('services/Cancellation');
const { chatRequest } = from('services/providers/ChatCompletionsProtocol');
const { responsesRequest, anthropicRequest } = from('services/providers/WireProtocols');
const { toolDetailContent } = from('model/ToolDetailContent');
const { parseSkillRequest } = from('model/ResourceManagement');
const call = (name, args) => ({ id: 'call', type: 'function', function: { name, arguments: JSON.stringify(args) } });
const invoke = (tools, name, args, signal = new Cancellation()) => tools.execute(call(name, args), signal);
const plain = value => JSON.parse(JSON.stringify(value));
async function main() {
  const approval = new ToolApproval(), interaction = new InteractionTools(approval);
  const memory = new MemoryTools(async ops => JSON.stringify(ops));
  const resources = new ResourceTools(async request => JSON.stringify(request), async () => '{}');
  const codeInputs = [];
  const code = new CodeExecutionTools({ execute: async (_source, input) => {
    codeInputs.push(JSON.parse(input)); return JSON.stringify({ status: 'ok', result: JSON.parse(input) });
  } });
  const remoteCalls = [];
  const mcp = new McpTools([{ id: 'remote', name: 'Remote', enabled: true, url: 'https://example.com/mcp' }], approval,
    () => ({ list: async () => [{ name: 'echo', inputSchema: { type: 'object' } }],
      call: async (name, args) => { remoteCalls.push({ name, args: plain(args) }); return { content: [] }; } }));
  const workspace = new WorkspaceTools({});
  const definitions = [interaction, memory, resources, code, mcp, workspace].flatMap(group => group.definitions());
  const schemas = new Map(definitions.map(tool => [tool.function.name, tool.function.parameters]));
  const validators = new Map([...schemas].map(([name, schema]) => [name, ajv.compile(plain(schema))]));
  const check = (name, args, valid = true) => {
    const validate = validators.get(name);
    assert.equal(validate(args), valid, name + ': ' + JSON.stringify(validate.errors));
  };
  const form = { title: 'Choose', fields: [{ name: 'mode', label: 'Mode', type: 'select', required: true, options: ['A', 'B'] }] };
  const plan = { explanation: 'Working', steps: [{ step: 'Read', status: 'in_progress' }, { step: 'Write', status: 'pending' }] };
  const view = { title: 'Values', kind: 'table', source: 'User data',
    columns: [{ key: 'name', label: 'Name', type: 'string' }, { key: 'amount', label: 'Amount', type: 'number' }, { key: 'ok', label: 'OK', type: 'boolean' }],
    rows: [{ values: ['A', 2, true] }] };
  const operations = [{ action: 'add', scope: 'thread', content: 'Keep it short' }];
  const files = [{ path: 'references/a.md', content: 'Reference' }];
  const nativeArgs = new Map([
    ['request_user_input', form], ['update_plan', plan], ['publish_data_view', view],
    ['memory', { operations }], ['skill_manage', { action: 'create', document: 'SKILL', files }],
    ['mcp_call', { server: 'remote', tool: 'echo', arguments: { nested: { values: [1, true, null] } } }],
    ['execute_code', { code: 'return input;', input: { values: [1, 2] } }],
    ['edit_file', { path: 'a.txt', edits: [{ oldText: 'a', newText: 'b' }] }]
  ]);
  for (const [name, args] of nativeArgs) check(name, args);
  for (const name of ['request_user_input', 'update_plan', 'publish_data_view']) check(name, { data: JSON.stringify(nativeArgs.get(name)) }, false);
  check('memory', { operations: JSON.stringify(operations) }, false);
  check('skill_manage', { action: 'create', files: JSON.stringify(files) }, false);
  check('skill_manage', { action: 'install', paths: ['a.md'] });
  check('skill_manage', { action: 'install', paths: '["a.md"]' }, false);
  check('mcp_call', { server: 'remote', tool: 'echo', arguments: '{}' }, false);
  for (const edits of [[], Array(33).fill({ oldText: 'a', newText: 'b' }), [{ oldText: '', newText: 'b' }]]) check('edit_file', { path: 'a', edits }, false);
  check('edit_file', { path: 'a', oldText: 'a', newText: 'b' }, false);
  check('edit_file', { path: 'a' }, false);
  assert.deepEqual(Object.keys(schemas.get('edit_file').properties), ['path', 'edits']);
  const chat = plain(chatRequest('test', [], definitions));
  const responses = plain(responsesRequest('test', [], definitions));
  const anthropic = plain(anthropicRequest('test', [], definitions));
  for (let i = 0; i < definitions.length; i++) {
    const expected = plain(definitions[i].function.parameters);
    assert.deepEqual(chat.tools[i].function.parameters, expected);
    assert.deepEqual(responses.tools[i].parameters, expected);
    assert.deepEqual(anthropic.tools[i].input_schema, expected);
    assert.equal(responses.tools[i].strict, false);
    assert.equal(chat.tools[i].function.strict, undefined);
    assert.equal(anthropic.tools[i].strict, undefined);
    assert.deepEqual(Object.keys(chat.tools[i]).sort(), ['function', 'type']);
  }
  console.log('PASS native parameter schemas, invalid legacy shapes, edit bounds and all three provider formats with strict unchanged');

  assert.deepEqual(JSON.parse(await invoke(interaction, 'update_plan', plan)), plan);
  assert.deepEqual(JSON.parse(await invoke(interaction, 'publish_data_view', view)), view);
  const waiting = invoke(interaction, 'request_user_input', form);
  assert.equal(approval.form.title, 'Choose'); approval.submit(['A']);
  const submitted = await waiting;
  assert.equal(JSON.parse(submitted).values.mode, 'A');
  const detail = toolDetailContent('request_user_input', JSON.stringify(form), submitted, 'complete');
  assert.equal(detail.sections[0].rows[0].label, 'Mode');
  const legacyDetail = toolDetailContent('request_user_input', JSON.stringify({ data: JSON.stringify(form) }), submitted, 'complete');
  assert.deepEqual(plain(detail.sections), plain(legacyDetail.sections));
  const cancelled = new Cancellation(); const pending = invoke(interaction, 'request_user_input', form, cancelled);
  cancelled.cancel(); await assert.rejects(pending); assert.equal(approval.form, undefined);
  for (const name of ['request_user_input', 'update_plan', 'publish_data_view']) {
    await assert.rejects(invoke(interaction, name, { data: JSON.stringify(nativeArgs.get(name)) }));
  }
  await assert.rejects(invoke(interaction, 'update_plan', { steps: [{ step: 'No active step', status: 'pending' }] }));
  await assert.rejects(invoke(interaction, 'publish_data_view', { ...view, rows: [{ values: ['A', 'wrong', true] }] }));
  assert.deepEqual(JSON.parse(await invoke(memory, 'memory', { operations })), operations);
  await assert.rejects(invoke(memory, 'memory', { operations: JSON.stringify(operations) }));
  await assert.rejects(invoke(memory, 'memory', { operations: Array(6).fill(operations[0]) }));
  assert.deepEqual(JSON.parse(await invoke(resources, 'skill_manage', nativeArgs.get('skill_manage'))).files, files);
  for (const bad of [{ action: 'create', files: '[]' }, { action: 'install', source: 'https://x', paths: ['a', 3] },
    { action: 'create', document: 'x', files: [{ path: '../x' }] }]) assert.throws(() => parseSkillRequest(JSON.stringify(bad)));
  assert.deepEqual(plain(parseSkillRequest(JSON.stringify({ action: 'install', source: 'https://x', paths: ['a.md'] }))).paths, ['a.md']);
  for (const input of [{ values: [1, 2] }, [1, false], false, null, 'literal text', '{"literal":"string"}']) {
    await invoke(code, 'execute_code', { code: 'return input;', input }); assert.deepEqual(codeInputs.at(-1), input);
  }
  await invoke(mcp, 'mcp_search_tools', { server: 'remote', query: 'echo' });
  await assert.rejects(invoke(mcp, 'mcp_call', { server: 'remote', tool: 'echo', arguments: '{}' }));
  const remote = invoke(mcp, 'mcp_call', nativeArgs.get('mcp_call'));
  assert.match(approval.details, /"values":\[1,true,null\]/);
  assert.equal(remoteCalls.length, 0); approval.respond(true); await remote;
  assert.deepEqual(remoteCalls[0].args, nativeArgs.get('mcp_call').arguments);
  const denied = invoke(mcp, 'mcp_call', nativeArgs.get('mcp_call'));
  approval.respond(false); await assert.rejects(denied); assert.equal(remoteCalls.length, 1);
  console.log('PASS native tool execution, artifact validation, form submit/cancel/history, sandbox JSON values and MCP approval/denial');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
