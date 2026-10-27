// Real runtime/request/dispatch tests, with local tool adapters and scripted model responses.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(studio + '/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '../entry/src'), cache = new Map();
function load(file) {
  file = path.resolve(file.endsWith('.ets') ? file : file + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  let source = fs.readFileSync(file, 'utf8');
  if (file.endsWith('SessionService.test.ets')) source += '\nexport { Fixture, seed };';
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true
  } }).outputText, { exports, Observed: cls => cls, setTimeout, clearTimeout, console, require: id => {
    if (id === '@ohos/hypium') return {};
    if (!id.startsWith('.')) throw Error('Unexpected platform dependency: ' + id);
    return load(path.resolve(path.dirname(file), id));
  } }, { filename: file });
  return exports;
}
const from = name => load(path.join(root, 'main/ets', name));
const { ToolCatalog, orderedToolDefinitions } = from('services/ToolCatalog');
const { ToolSet } = from('services/ToolSet');
const { OrchestrationTools } = from('services/OrchestrationTools');
const { AgentRuntime } = from('services/AgentRuntime');
const { ProviderRegistry } = from('services/providers/ProviderRegistry');
const { SelectedTools } = from('services/SelectedTools');
const { RuleTools } = from('services/RuleTools');
const { Cancellation } = from('services/Cancellation');
const { WorkspaceTools } = from('services/WorkspaceTools');
const { InteractionTools } = from('services/InteractionTools');
const { CodeExecutionTools } = from('services/CodeExecutionTools');
const { PreviewTools } = from('services/PreviewTools');
const { PresentTools } = from('services/PresentTools');
const { ResourceTools } = from('services/ResourceTools');
const { MemoryTools } = from('services/MemoryTools');
const { McpTools } = from('services/McpTools');
const { WebTools } = from('services/WebTools');
const { ToolApproval } = from('services/ToolApproval');
const { RequestContext } = from('services/RequestContext');
const { sessionPromptSections } = from('services/SessionContext');
const { INTERACTIVE_UI_INSTRUCTIONS } = from('model/InteractiveUiInstructions');
const { defaultConfig } = from('model/Conversation');
const { defaultExtensions } = from('model/Skills');
const { toolSchemas } = from('model/Agent');
const { runAgentLoop } = from('services/AgentLoop');
const { Fixture } = load(root + '/test/SessionService.test');
const plain = value => JSON.parse(JSON.stringify(value));
const names = tools => Array.from(tools.definitions(), item => item.function.name);
let sequence = 0;
const call = (name, args = {}) => ({ id: 'tool-' + ++sequence, type: 'function', function: { name, arguments: JSON.stringify(args) } });
const reply = (...calls) => ({ content: calls.length ? '' : 'Done', toolCalls: calls });
const invoke = async (tools, name, args, cancellation = new Cancellation()) => JSON.parse(await tools.execute(call(name, args), cancellation));
const definition = (name, executionMode) => ({ type: 'function', executionMode, function: { name, description: name,
  parameters: { type: 'object', properties: {}, required: [], additionalProperties: false } } });
// Host adapter double; the native QuickJS bridge is checked by the orchestration suite/device smoke.
const executor = { async execute(code, catalog, invoke) {
  const tools = Object.fromEntries(JSON.parse(catalog).map(tool => [tool.name,
    async args => JSON.parse(await invoke(tool.name, JSON.stringify(args)))]));
  try { return JSON.stringify({ status: 'ok', result: await vm.runInNewContext('(async()=>{' + code + '})()', { tools, ALL_TOOLS: JSON.parse(catalog) }) }); }
  catch (error) { return JSON.stringify({ status: 'error', error: error.message }); }
} };
async function main() {
  const approval = new ToolApproval();
  const code = new CodeExecutionTools({ execute: async (_code, input) => JSON.stringify({ status: 'ok', result: JSON.parse(input) }) });
  const contents = new Map([['data.txt', 'needle'], ['unread.txt', 'original']]);
  const files = {
    list: async path => ({ path, entries: Array.from(contents.keys(), name => ({ name, kind: 'file' })), truncated: false }),
    read: async path => ({ path, content: contents.get(path), version: contents.get(path) })
  };
  const base = new ToolSet([new WorkspaceTools(files), new InteractionTools(approval), code,
    new PreviewTools({}, async () => {}), new PresentTools(async path => path),
    new ResourceTools(async args => JSON.stringify(args), async () => '{}'), new MemoryTools(async () => '{}'),
    new McpTools([{ id: 'remote', name: 'Remote', enabled: true, url: 'https://example.com/mcp' }], approval, () => ({})), new WebTools({})]);
  const catalog = new OrchestrationTools(base, executor), tools = new ToolCatalog(catalog);
  assert.deepEqual(names(tools), names(catalog).sort(), 'All authorized schemas are visible initially in stable name order');
  for (const name of ['list_files','find_files','search_file_content','execute_code','read_web','mcp_list_tools','mcp_call',
    'request_user_input','update_plan','publish_preview','present_files']) assert.ok(names(tools).includes(name), name);
  for (const name of ['tool_search','publish_data_view']) assert.ok(!names(tools).includes(name));
  await assert.rejects(invoke(tools, 'tool_search', {query:'execute_code'}), error=>error.code==='TOOL_UNAVAILABLE');
  const before=plain(toolSchemas(tools.definitions()));
  assert.deepEqual((await invoke(tools,'execute_code',{code:'return input;',input:[2,3]})).result,[2,3]);
  assert.deepEqual(plain(toolSchemas(tools.definitions())),before,'Calling a tool does not change the declaration set');
  const config=defaultConfig();config.contextWindow=1000000;
  const source={state:{},entries:()=>[],sections:()=>sessionPromptSections(config,defaultExtensions()),persist:async()=>{},progress(){}};
  const initial=new RequestContext(source,config).inspect(tools.definitions());
  assert.ok(initial.messages.some(m=>m.runtimeContext&&m.content.includes(INTERACTIVE_UI_INSTRUCTIONS.trim())));
  const inspector=new AgentRuntime(new ProviderRegistry(),{read:async()=>''},undefined,undefined,executor).inspectContext(source,config,base);
  assert.equal(inspector.context.toolTokens,initial.context.toolTokens,'Context inspector counts the same full catalog');
  assert.deepEqual(plain(orderedToolDefinitions(catalog.definitions())), plain(tools.definitions()));
  const reserved = { ...definition('tool_search') };
  assert.throws(() => orderedToolDefinitions([reserved]), error => error.code === 'INTERNAL_ERROR');
  console.log('PASS full initial schemas/guidelines, stable calls, matching context inspector and retired-search rejection');

  const restricted=new ToolCatalog(new RuleTools(new SelectedTools(catalog,{agentMode:'custom',disabledTools:['publish_preview','execute_code']}),true));
  for(const name of ['publish_preview','execute_code','memory','skill_manage','mcp_call','write_file','edit_file'])assert.ok(!names(restricted).includes(name),name);
  for(const name of ['list_files','find_files','read_file','search_file_content','present_files'])assert.ok(names(restricted).includes(name),name);
  await assert.rejects(invoke(restricted,'publish_preview',{path:'a.js'}),error=>error.code==='PERMISSION_DENIED');
  let enabled=true;
  const live=new ToolCatalog({definitions:()=>enabled?[definition('read_web')]:[],execute:async()=>{if(!enabled)throw Error('disabled');return '{}';}});
  enabled=false;assert.ok(!names(live).includes('read_web'));await assert.rejects(invoke(live,'read_web',{}));
  let finished=false;
  await new ToolCatalog({definitions:()=>[],execute:async()=>'{}',beforeFinish:async()=>{finished=true;return 'handoff required';}}).beforeFinish(new Cancellation());
  assert.ok(finished);
  console.log('PASS custom/readonly policy, mandatory files, independent delivery, live revocation and completion guards');

  const f=new Fixture();
  f.resources.agentTools={definitions:()=>base.definitions().filter(t=>!['skill_manage','mcp_manage','memory'].includes(t.function.name)),
    execute:(incoming,cancellation,context)=>base.execute(incoming,cancellation,context)};
  const registry=new ProviderRegistry();registry.register(f.provider);
  f.session.runtime=new AgentRuntime(registry,f.keys,undefined,undefined,executor);
  await f.session.initialize();
  f.provider.respond=async index=>index===0?reply(call('execute_code',{code:'return input;',input:{values:[1,2]}})):reply();
  f.session.setDraft('Compute directly');await f.session.send();
  assert.equal(f.session.active.messages.at(-1).status,'complete');
  const first=f.provider.requests[0];assert.ok(first.tools.some(t=>t.function.name==='execute_code'));
  assert.ok(first.tools.some(t=>t.function.name==='read_web'));assert.ok(!first.tools.some(t=>t.function.name==='tool_search'));
  assert.deepEqual(plain(first.tools),plain(f.provider.requests[1].tools));
  assert.ok(first.messages.some(m=>m.runtimeContext&&m.content.includes(INTERACTIVE_UI_INSTRUCTIONS.trim())));
  assert.deepEqual(JSON.parse(f.session.active.messages.at(-1).steps[0].tools[0].output).result,{values:[1,2]});
  assert.equal(JSON.parse(f.repository.saved).threads[0].messages.at(-1).steps[0].tools[0].call.function.name,'execute_code');
  // An old completed discovery receipt remains readable history, without influencing the next catalog.
  const old=f.session.active.messages.at(-1).steps[0].tools[0];
  old.call.function.name='tool_search';old.call.function.arguments='{"query":"execute_code"}';old.output='{"loaded":["execute_code","publish_data_view"]}';
  f.provider.respond=async()=>reply();f.session.setDraft('Continue an old discovered session');await f.session.send();
  assert.deepEqual(plain(f.provider.requests.at(-1).tools),plain(first.tools));
  assert.equal(f.session.active.messages.at(-1).status,'complete');
  console.log('PASS real SessionService first direct call -> unchanged second request -> persistence -> legacy discovery history continuation');

  const start=f.provider.requests.length;
  f.provider.respond=async index=>index===start?reply(call('orchestrate',{code:`
    const listing=await tools.list_files({path:'.'});
    const found=await tools.find_files({path:'.',glob:'data.*'});
    const matches=await tools.search_file_content({path:'.',query:'needle'});
    const data=await tools.read_file({path:'data.txt'});return {listing,found,matches,data};` })):reply();
  f.session.setDraft('Read through orchestration');await f.session.send();
  const receipt=f.session.active.messages.at(-1).steps[0].tools[0];assert.equal(receipt.status,'complete');
  assert.deepEqual(JSON.parse(receipt.output).result.found.paths,['data.txt']);
  assert.deepEqual(Array.from(receipt.children,c=>c.call.function.name),['list_files','find_files','search_file_content','read_file']);
  assert.ok(f.provider.requests[start].tools.some(t=>t.function.name==='list_files'),'Direct and orchestrated access coexist');
  assert.deepEqual(plain(f.provider.requests[start].tools),plain(f.provider.requests[start+1].tools));
  for(const args of [{path:'../outside',edits:[{oldText:'original',newText:'changed'}]},
    {path:'unread.txt',edits:[{oldText:'original',newText:'changed'}]}]){
    const next=f.provider.requests.length;f.provider.respond=async index=>index===next?reply(call('orchestrate',{code:'return await tools.edit_file('+JSON.stringify(args)+');'})):reply();
    f.session.setDraft('Check mutation guards');await f.session.send();
    const failed=f.session.active.messages.at(-1).steps[0].tools[0];assert.equal(failed.status,'failed');
    assert.equal(JSON.parse(failed.children[0].output).code,args.path.startsWith('..')?'FS_INVALID_PATH':'FS_NOT_OBSERVED');
    assert.equal(contents.get('unread.txt'),'original');
  }
  console.log('PASS direct schemas retain orchestration, durable children and path/read-before-edit protection');

  let exclusive = false, active = 0, overlapped = false, rounds = 0;
  const changing = new ToolCatalog({
    definitions: () => [definition('changing', exclusive ? 'sequential' : 'parallel')],
    execute: async () => {
      if (++active > 1) overlapped = true;
      await new Promise(resolve => setTimeout(resolve, 0)); active--; return '{}';
    }
  });
  await runAgentLoop({ tools: changing, messages: [], turn: { content: '', steps: [] }, maxSteps: 3,
    model: { stream: async () => {
      exclusive = true; return rounds++ === 0 ? reply(call('changing'), call('changing')) : reply();
    } } }, new Cancellation(), { event() {}, checkpoint: async () => {} });
  assert.equal(overlapped, false, 'Execution uses current catalog metadata after the model returns');
  console.log('PASS live execution metadata retains sequential barriers without deferred discovery');
}
main().catch(error=>{console.error(error);process.exitCode=1;});
