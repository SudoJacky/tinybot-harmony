// Deterministic provider clocks: no network, device, or build required.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets'), cache = new Map();
let now = 0, frames = [];
class Clock extends Date { static now() { return now; } }
const kits = {
  '@kit.ArkTS': { util: { generateRandomUUID: () => 'request', TextDecoder: class {
    decoder = new TextDecoder(); decodeToString(bytes, options) { return this.decoder.decode(bytes, options); }
  } } },
  '@kit.BasicServicesKit': {},
  '@kit.NetworkKit': { http: { RequestMethod: { POST: 'POST' }, createHttp() {
    const handlers = {};
    return { on(name, fn) { handlers[name] = fn; }, destroy() {}, requestInStream(url, options, callback) {
      callback(undefined, 200);
      for (const [time, data] of frames) {
        now = time;
        handlers.dataReceive(new TextEncoder().encode('data: ' + (typeof data === 'string' ? data : JSON.stringify(data)) + '\n\n').buffer);
      }
      now = 5000; handlers.dataEnd();
    } };
  } } }
};
function load(name) {
  const file = path.resolve(root, name.endsWith('.ets') ? name : name + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true
  } }).outputText, { exports, Date: Clock, setTimeout, clearTimeout, Observed: cls => cls,
    require: id => {
      if (id.startsWith('.')) return load(path.resolve(path.dirname(file), id));
      assert.ok(kits[id], 'Unexpected import: ' + id); return kits[id];
    }
  }, { filename: file });
  return exports;
}
const { ProtocolProvider } = load('services/providers/ProtocolProvider');
const { Cancellation } = load('services/Cancellation');
const { outputTokensPerSecond, summarizeUsage } = load('model/MessageUsage');
const { MessageViewModel } = load('viewmodel/SessionViewModels');
const { Diagnostics } = load('model/Diagnostics');
const logs = []; Diagnostics.configureLogSink(log => logs.push(log)); Diagnostics.start();
const chat = delta => ({ choices: [{ index: 0, delta }] });
const gemini = parts => ({ candidates: [{ content: { role: 'model', parts } }] });
const call = { type: 'function_call', call_id: 'tool', name: 'read_file', arguments: '{}' };
const cases = [
  ['chat-completions', [
    [1100, chat({ role: 'assistant', content: '' })],
    [2000, chat({ reasoning_content: 'Thinking' })], [4000, chat({ content: 'Done' })],
    [4900, { choices: [{ index: 0, finish_reason: 'stop' }], usage: { prompt_tokens: 10, completion_tokens: 60 } }], [4900, '[DONE]']
  ]],
  ['chat-completions', [
    [1100, chat({ role: 'assistant' })],
    [2000, chat({ tool_calls: [{ index: 0, id: 'tool', type: 'function', function: { name: 'read_file', arguments: '{' } }] })],
    [4000, chat({ tool_calls: [{ index: 0, function: { arguments: '}' } }] })],
    [4900, { choices: [{ index: 0, finish_reason: 'tool_calls' }], usage: { prompt_tokens: 10, completion_tokens: 60 } }], [4900, '[DONE]']
  ]],
  ['responses', [
    [1100, { type: 'response.created' }],
    [2000, { type: 'response.reasoning_summary_text.delta', delta: 'Thinking' }],
    [4000, { type: 'response.output_text.delta', delta: 'Done' }],
    [4900, { type: 'response.completed', response: { status: 'completed', output: [{ type: 'message', content: [{ type: 'output_text', text: 'Done' }] }], usage: { input_tokens: 10, output_tokens: 60 } } }]
  ]],
  ['responses', [
    [1100, { type: 'response.created' }], [2000, { type: 'response.output_item.added', item: call }],
    [4000, { type: 'response.function_call_arguments.delta', delta: '{}' }],
    [4900, { type: 'response.completed', response: { status: 'completed', output: [call], usage: { input_tokens: 10, output_tokens: 60 } } }]
  ]],
  ['anthropic-messages', [
    [1100, { type: 'message_start', message: { usage: { input_tokens: 10 } } }],
    [1200, { type: 'content_block_start', index: 0, content_block: { type: 'thinking', thinking: '', signature: 'sig' } }],
    [2000, { type: 'content_block_delta', index: 0, delta: { type: 'thinking_delta', thinking: 'Thinking' } }],
    [3000, { type: 'content_block_stop', index: 0 }],
    [4000, { type: 'content_block_start', index: 1, content_block: { type: 'text', text: 'Done' } }],
    [4500, { type: 'content_block_stop', index: 1 }],
    [4900, { type: 'message_delta', delta: { stop_reason: 'end_turn' }, usage: { output_tokens: 60 } }], [4900, { type: 'message_stop' }]
  ]],
  ['anthropic-messages', [
    [1100, { type: 'message_start', message: { usage: { input_tokens: 10 } } }],
    [2000, { type: 'content_block_start', index: 0, content_block: { type: 'tool_use', id: 'tool', name: 'read_file', input: {} } }],
    [4000, { type: 'content_block_delta', index: 0, delta: { type: 'input_json_delta', partial_json: '{}' } }],
    [4500, { type: 'content_block_stop', index: 0 }],
    [4900, { type: 'message_delta', delta: { stop_reason: 'tool_use' }, usage: { output_tokens: 60 } }], [4900, { type: 'message_stop' }]
  ]],
  ['gemini', [
    [1100, { candidates: [] }], [2000, gemini([{ thought: true, text: 'Thinking' }])],
    [4000, gemini([{ text: 'Done' }])],
    [4900, { candidates: [{ finishReason: 'STOP' }], usageMetadata: { promptTokenCount: 10, candidatesTokenCount: 40, thoughtsTokenCount: 20 } }]
  ]],
  ['gemini', [
    [1100, { candidates: [] }], [2000, gemini([{ functionCall: { name: 'read_file', args: {} } }])],
    [4900, { candidates: [{ finishReason: 'STOP' }], usageMetadata: { promptTokenCount: 10, candidatesTokenCount: 60 } }]
  ]]
];
(async () => {
  for (const [protocol, events] of cases) {
    now = 1000; frames = events;
    const records = [];
    const provider = new ProtocolProvider({ id: protocol, name: protocol, protocol }, {
      hydrate: async value => value, recordUsage: record => records.push(record)
    });
    const result = await provider.stream({ baseUrl: 'https://fixture.invalid', model: 'model', apiKey: 'fixture',
      messages: [{ role: 'user', content: 'Test' }], tools: [] }, new Cancellation(), () => {});
    assert.equal(result.usage.firstTokenMs, 1000, protocol + ': thinking/tools start the clock; metadata does not');
    assert.equal(result.usage.durationMs, 4000);
    assert.equal(outputTokensPerSecond(result.usage), 20);
    assert.equal(logs.at(-1).fields.firstTokenMs, 1000);
    assert.equal(logs.at(-1).fields.outputTokens, 60);
    assert.equal(records.length, 2);
  }
  const record = { id: 'r', status: 'complete', durationMs: 4000, firstTokenMs: 1000, tokens: { input: 10, output: 60 } };
  for (const item of [undefined, { ...record, tokens: undefined }, { ...record, firstTokenMs: undefined },
    { ...record, firstTokenMs: 4000 }, { ...record, firstTokenMs: 5000 }, { ...record, status: 'failed' }, { ...record, status: 'cancelled' }]) {
    assert.equal(outputTokensPerSecond(item), undefined);
  }
  assert.equal(outputTokensPerSecond({ ...record, tokens: { input: 10, output: 0 } }), 0);
  const data = { id: 'm', role: 'assistant', status: 'generating', content: 'Done', error: '', steps: [{ content: 'Done', tools: [] }] };
  const message = new MessageViewModel(data), firstStep = message.stepViews[0];
  assert.equal(outputTokensPerSecond(firstStep.usage), undefined);
  data.steps[0].usage = record;
  message.update(data);
  assert.equal(message.stepViews[0], firstStep);
  assert.equal(outputTokensPerSecond(firstStep.usage), 20, 'Visible as soon as model ends, while turn/tools continue');
  data.steps.push({ content: 'Next', tools: [], usage: { ...record, id: 'r2', tokens: { input: 20, output: 120 } } });
  message.update(data);
  assert.equal(outputTokensPerSecond(message.stepViews[1].usage), 40);
  assert.equal(outputTokensPerSecond(firstStep.usage), 20, 'Later steps do not change earlier speed');
  const restored = new MessageViewModel(JSON.parse(JSON.stringify(data)));
  assert.equal(outputTokensPerSecond(restored.stepViews[0].usage), 20);
  assert.equal(summarizeUsage(restored.steps.map(step => step.usage)).output, 180, 'Turn usage remains cumulative');
  console.log('PASS per-step speed, live completion/reload, unknown usage, and first-token timing for reasoning/tool-only output across all four protocols');
})().catch(error => { console.error(error); process.exitCode = 1; });
