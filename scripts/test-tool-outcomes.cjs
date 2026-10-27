// Real source modules and model/tool continuations; no device, emulator or model service.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve('entry/src/main/ets'), cache = new Map();
function load(file) {
  file = path.resolve(file.endsWith('.ets') ? file : file + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true
  } }).outputText, { exports, Error, console, setTimeout, clearTimeout, Observed: cls => cls,
    require: id => id === '@kit.ArkTS' ? { util: { generateRandomUUID: require('node:crypto').randomUUID,
      TextDecoder: class { decoder = new TextDecoder(); decodeToString(bytes, options) { return this.decoder.decode(bytes, options); } }
    } } : load(path.resolve(path.dirname(file), id)) }, { filename: file });
  return exports;
}
const from = name => load(path.join(root, name));
const { Cancellation } = from('services/Cancellation');
const { runAgentLoop } = from('services/AgentLoop');
const { executeToolBatch } = from('services/ToolExecution');
const { validateToolCalls, validateSteps, toolError } = from('model/Agent');
const { ToolFailure, ToolResultError } = from('model/ToolFailure');
const { toolOutcome } = from('model/ToolOutcome');
const { textPage } = from('model/TextPage');
const { parseAppData, emptyData } = from('model/Conversation');
const { parseUiSurface } = from('model/InteractiveUi');
const { PreviewTools } = from('services/PreviewTools');
const { WorkspaceTools } = from('services/WorkspaceTools');
const { ToolSet } = from('services/ToolSet');
const call = (name, args) => ({ id: name, type: 'function', function: { name, arguments: JSON.stringify(args) } });
const wire = value => 'data: ' + JSON.stringify(value) + '\n\n';
async function batch(base, signal = new Cancellation(), args = {}) {
  const step = { content: '', tools: [{ call: call('fixture', args), status: 'pending', output: '' }] };
  try { await executeToolBatch(step, 0, { execute: base }, [], signal, { event() {}, checkpoint: async () => {} }); }
  catch (error) { if (!signal.cancelled) throw error; }
  return step.tools[0];
}
async function main() {
  const large = '中文🙂 "\\\n'.repeat(150000), args = { path: 'large.js', content: large };
  validateToolCalls([call('write_file', args)]);
  const { ChatStream } = from('services/ChatStream');
  const { ResponsesStream, AnthropicStream } = from('services/providers/EventStreams');
  const { GeminiStream } = from('services/providers/GeminiStream');
  const chat = new ChatStream(() => {});
  chat.push(wire({ choices: [{ index: 0, delta: { tool_calls: [{ index: 0, ...call('write_file', args) }] } }] }));
  chat.push(wire({ choices: [{ index: 0, delta: {}, finish_reason: 'tool_calls' }] }) + 'data: [DONE]\n\n');
  const responses = new ResponsesStream(() => {});
  responses.push(wire({ type: 'response.completed', response: { status: 'completed', output: [
    { type: 'function_call', call_id: 'large', name: 'write_file', arguments: JSON.stringify(args) }
  ] } }));
  const anthropic = new AnthropicStream(() => {});
  for (const event of [ { type: 'message_start' },
    { type: 'content_block_start', index: 0, content_block: { type: 'tool_use', id: 'large', name: 'write_file', input: {} } },
    { type: 'content_block_delta', index: 0, delta: { type: 'input_json_delta', partial_json: JSON.stringify(args) } },
    { type: 'content_block_stop', index: 0 }, { type: 'message_delta', delta: { stop_reason: 'tool_use' } }, { type: 'message_stop' }
  ]) anthropic.push(wire(event));
  const gemini = new GeminiStream(() => {});
  gemini.push(wire({ candidates: [{ content: { role: 'model', parts: [{ functionCall: { name: 'write_file', args } }] }, finishReason: 'STOP' }] }));
  for (const parser of [chat, responses, anthropic, gemini]) {
    assert.equal(JSON.parse(parser.finish().toolCalls[0].function.arguments).content, large);
  }
  console.log('PASS multi-megabyte tool arguments cross all four protocols and retained provider content unchanged');

  const source = '/*' + large.replaceAll('*/', '* /') + '*/\ndocument.body.textContent="Large page";';
  const files = new Map();
  const storage = { read: async p => ({ path: p, content: files.get(p), version: 'v1' }),
    write: async (p, content) => { files.set(p, content); return { path: p, bytes: Buffer.byteLength(content), written: true, version: 'v1' }; } };
  let preflight = 0;
  const publisher = new PreviewTools(storage, async content => {
    assert.equal(JSON.parse(parseUiSurface(content, '0').nodes[0].data).js, source); preflight++;
  });
  const tools = new ToolSet([new WorkspaceTools(storage), publisher]);
  const turn = { content: '', steps: [] }; let round = 0;
  await runAgentLoop({ tools, turn, messages: [], maxSteps: 4, model: { stream: async messages => {
    if (round++ === 0) return { content: '', toolCalls: [call('write_file', { path: 'large.js', content: source })] };
    if (round === 2) return { content: '', toolCalls: [call('publish_preview', { path: 'large.js' })] };
    const receipt = JSON.parse(messages.filter(m => m.role === 'tool').at(-1).content);
    return { content: receipt.reference, toolCalls: [] };
  } } }, new Cancellation(), { event() {}, checkpoint: async () => validateSteps(turn.steps) });
  assert.equal(preflight, 1); assert.equal(files.get('large.js'), source);
  const data = emptyData(); data.activeThreadId = 'large'; data.threads = [{ id: 'large', title: 'Large', updatedAt: 1, messages: [
    { id: 'u', role: 'user', content: 'Build a complex page', status: 'complete', error: '' },
    { id: 'a', role: 'assistant', content: turn.content, status: 'complete', error: '', steps: turn.steps }
  ] }];
  const restored = parseAppData(JSON.stringify(data));
  const saved = restored.threads[0].messages[1].steps[1].tools[0].previewContent;
  assert.equal(JSON.parse(parseUiSurface(saved, '0').nodes[0].data).js, source);
  const page = textPage(source, 1, 200000, 1, Buffer.byteLength(source) + 1);
  assert.equal(page.content, source); assert.equal(page.truncated, false);
  const defaultPage = textPage(source); assert.equal(defaultPage.truncated, true);
  assert.ok(defaultPage.nextOffset && defaultPage.nextColumn);
  console.log('PASS AgentLoop large write -> publish -> exact snapshot -> session reload; configurable lossless read pages');

  const original = 'failure detail '.repeat(800);
  for (const error of [new ToolFailure('FS_STALE_VERSION', original, 'read_file', { path: 'a.js', version: 'v2' }),
    Object.assign(new Error(original), { code: 1234 }), original,
    new ToolResultError(JSON.stringify({ error: original, completed: true, captured: 2 }), 'TIMEOUT', 'inspect_result_before_retry')]) {
    const receipt = await batch(async () => { throw error; });
    const result = JSON.parse(receipt.output);
    assert.equal(receipt.status, 'failed'); assert.equal(result.error, original);
    assert.equal(result.conclusion.status, 'failed'); assert.ok(result.conclusion.recovery);
    if (result.code === 'TIMEOUT') { assert.equal(result.completed, true); assert.equal(result.captured, 2); }
  }
  const plain = await batch(async () => '{This is plain text, not JSON}');
  assert.equal(plain.status, 'complete'); assert.equal(plain.output, '{This is plain text, not JSON}');
  const invalid = await batch(async () => { throw Error('must not dispatch'); }, new Cancellation(), 0);
  assert.equal(JSON.parse(invalid.output).code, 'INVALID_ARGUMENTS');
  const returned = await batch(async () => JSON.stringify({ error: original, code: 'REMOTE_TOOL_ERROR', completed: false }));
  assert.equal(returned.status, 'failed'); assert.equal(JSON.parse(returned.output).error, original);
  const partial = await batch(async () => JSON.stringify({ completed: true, logsTruncated: true, page: {
    text: 'excerpt', truncated: true, reductions: ['Input value shortened to 1000 characters.'], errors: [original]
  } }));
  const result = JSON.parse(partial.output);
  assert.equal(partial.status, 'complete'); assert.equal(result.completed, true);
  assert.equal(result.conclusion.status, 'partial'); assert.ok(result.conclusion.notices.some(n => n.includes('32 KiB')));
  assert.equal(result.page.errors[0],original);
  assert.ok(result.conclusion.notices.some(n => n.includes('complete diagnostics')));
  const cancelled = new Cancellation();
  const committed = await batch(async () => { cancelled.cancel(); return '{"written":true}'; }, cancelled);
  assert.equal(committed.status, 'complete'); assert.equal(JSON.parse(committed.output).written, true);
  const { PreviewBrowserRuntime } = from('services/PreviewBrowserRuntime');
  const runtime = new PreviewBrowserRuntime();
  for (let i = 0; i < 30; i++) runtime.recordError(i + ':' + original);
  assert.equal(runtime.errors.length, 16); assert.ok(runtime.errors[0].includes('15 page errors were omitted'));
  assert.ok(runtime.errors.at(-1).endsWith(original));
  assert.equal(toolOutcome(JSON.stringify({ skipped: ['a.js'], skippedDetails: [{ path: 'a.js', reason: JSON.parse(toolError(new Error(original))) }] })).partial, true);
  console.log('PASS complete tool failures, malformed args, returned errors, reduction conclusions and committed effects on cancellation');

  const mcpText='m'.repeat(1200000), rpcError='remote diagnostic '.repeat(500);
  cache.set(path.join(root,'services/McpOAuth.ets'), { McpOAuth: { bearer: async () => '' } });
  cache.set(path.join(root,'services/CompatHttp.ets'), { CompatHttp: { stream(spec, handlers) {
    assert.equal(spec.maxBytes,undefined);
    const request=JSON.parse(spec.body);handlers.onStatus(200);
    if(request.id!==undefined) {
      const response={jsonrpc:'2.0',id:request.id};
      if(request.method==='initialize') response.result={protocolVersion:'2025-06-18'};
      else if(request.params.name==='fail') response.error={code:-32000,message:rpcError};
      else response.result={content:[{type:'text',text:mcpText}]};
      handlers.onData(new TextEncoder().encode(JSON.stringify(response)).buffer);
    }
    handlers.onEnd();return ()=>{};
  } } });
  const {McpClient}=from('services/McpClient');
  const mcp=new McpClient({id:'s',name:'Service',url:'https://example.com/mcp',auth:'none',enabled:true});
  assert.equal((await mcp.call('big',{},new Cancellation())).content[0].text,mcpText);
  await assert.rejects(mcp.call('fail',{},new Cancellation()), error=>error.message.endsWith(rpcError)&&error.details.remoteCode===-32000);
  const {McpTools}=from('services/McpTools');
  let catalog=[{name:'big',description:'schema '.repeat(10000),inputSchema:{type:'object',properties:{}}}];
  const remote=new McpTools([{id:'s',name:'Service',url:'https://example.com/mcp',enabled:true}],{request:async()=>{}},()=>({list:async()=>catalog}));
  assert.equal(JSON.parse(await remote.execute(call('mcp_list_tools',{server:'s'}),new Cancellation()))[0].description,catalog[0].description);
  catalog=Array.from({length:13},(_,i)=>({name:'match'+i,description:'match',inputSchema:{type:'object'}}));
  const schemas=toolOutcome(await remote.execute(call('mcp_search_tools',{server:'s',query:'match'}),new Cancellation()));
  assert.equal(schemas.partial,true);assert.equal(JSON.parse(schemas.output).totalMatches,13);
  assert.equal(JSON.parse(schemas.output).conclusion.recovery,'refine_query');
  console.log('PASS MCP accepts large responses and schemas, retains full RPC errors, and explicitly reports narrowed discovery');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
