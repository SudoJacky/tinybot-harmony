// Native Gemini protocol integration checks. No API credentials, network, or device required.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict'), crypto = require('node:crypto');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets'), cache = new Map();
let streamScript = () => { throw Error('Unexpected stream'); }, jsonScript = () => { throw Error('Unexpected JSON request'); };
let destroyed = 0;
class Decoder { decoder = new TextDecoder(); decodeToString(bytes, options) { return this.decoder.decode(bytes, options); } }
const kits = {
  '@kit.BasicServicesKit': { deviceInfo: { sdkApiVersion: 26 } },
  '@kit.RemoteCommunicationKit': { rcp: { createSession() { throw Error('The API 20 transport must not run on API 26'); } } },
  '@kit.ArkTS': { util: { TextDecoder: Decoder, generateRandomUUID: () => crypto.randomUUID() } },
  '@kit.PerformanceAnalysisKit': { hilog: { info() {}, warn() {}, error() {} } },
  '@kit.AssetStoreKit': { asset: {} },
  '@kit.NetworkKit': { http: { RequestMethod: { POST: 'POST', GET: 'GET' }, HttpDataType: { STRING: 'string' }, createHttp() {
    const handlers = {}; let closed = false;
    return { on(name, callback) { handlers[name] = callback; }, destroy() { closed = true; destroyed++; },
      request: (url, options) => jsonScript(url, options),
      requestInStream: (url, options, callback) => streamScript({ url, options, callback,
        emit: (name, value) => { if (!closed) handlers[name]?.(value); } }) };
  } } }
};
function load(file) {
  file = path.resolve(file.endsWith('.ets') ? file : file + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true
  } }).outputText, { exports, console, setTimeout, clearTimeout, Uint8Array, Observed: cls => cls,
    require: id => { if (id.startsWith('.')) return load(path.resolve(path.dirname(file), id));
      assert.ok(kits[id], 'Unexpected import: ' + id); return kits[id]; }
  }, { filename: file });
  return exports;
}
const from = name => load(path.join(root, name));
const { geminiRequest, geminiStreamUrl } = from('services/providers/GeminiProtocol');
const { GeminiStream } = from('services/providers/GeminiStream');
const { protocolHeaders } = from('services/providers/WireProtocols');
const { protocolUrl, sameCredentialScope } = from('model/ProviderEndpoint');
const { ProtocolProvider } = from('services/providers/ProtocolProvider');
const { builtinProviderInfos } = from('model/Provider');
const { validateProfile } = from('model/ProviderProfiles');
const { stepMessages, validateSteps } = from('model/Agent');
const { UsageStream } = from('model/Usage');
const { Cancellation } = from('services/Cancellation');
const { runAgentLoop } = from('services/AgentLoop');
const { discoverModels } = from('services/ModelDiscovery');
const { CredentialStore } = from('services/CredentialStore');
const { ProviderEditorViewModel } = from('viewmodel/ProviderEditorViewModel');
const event = value => 'data: ' + JSON.stringify(value) + '\r\n\r\n';
const candidate = (parts, finishReason) => ({ candidates: [{ index: 0, content: { role: 'model', parts }, finishReason }] });
const plain = value => JSON.parse(JSON.stringify(value));
const tools = [{ type: 'function', function: { name: 'read_file', description: 'Read a file',
  parameters: { type: 'object', properties: { path: { type: 'string', description: 'Path' } }, required: ['path'], additionalProperties: false } } }];
const input = { baseUrl: 'https://fixture.invalid/v1beta', model: 'gemini-fixture', apiKey: 'fixture-secret',
  messages: [{ role: 'system', content: 'Instructions' }, { role: 'user', content: 'Read the files' }], tools };
const info = { id: 'google', name: 'Google Gemini', protocol: 'gemini', defaultBaseUrl: input.baseUrl, defaultModel: input.model };

async function main() {
  const preset = builtinProviderInfos().find(item => item.id === 'google');
  assert.equal(preset.protocol, 'gemini'); assert.equal(preset.apiKeyUrl, 'https://aistudio.google.com/apikey');
  validateProfile({ id: 'google-test', name: 'Google', presetId: 'google', protocol: 'gemini', baseUrl: preset.defaultBaseUrl,
    credentialAlias: 'saved-key', noApiKey: false, enabled: true, models: ['gemini-fixture'] });
  assert.equal(protocolUrl('gemini', 'https://generativelanguage.googleapis.com/', false), preset.defaultBaseUrl);
  assert.equal(protocolUrl('gemini', 'https://proxy.invalid/google/v1beta/', false), 'https://proxy.invalid/google/v1beta');
  assert.equal(geminiStreamUrl(input.baseUrl, 'models/gemini-fixture'), input.baseUrl + '/models/gemini-fixture:streamGenerateContent?alt=sse');
  for (const model of ['', '../secret', 'gemini?key=x', 'gemini#fragment', 'a/b']) assert.throws(() => geminiStreamUrl(input.baseUrl, model));
  for (const url of ['https://host.invalid/v1/chat/completions', 'https://host.invalid/v1/messages', 'https://host.invalid/v1/responses',
    'https://host.invalid/v1beta/models/model:generateContent', 'https://host.invalid?key=secret']) assert.throws(() => protocolUrl('gemini', url, false));
  const headers = protocolHeaders('gemini', 'fixture-secret');
  assert.equal(headers['x-goog-api-key'], 'fixture-secret'); assert.equal(headers.Authorization, undefined);
  assert.equal(protocolHeaders('gemini', '')['x-goog-api-key'], undefined);
  assert.ok(sameCredentialScope('gemini', input.baseUrl, 'gemini', input.baseUrl + '/'));
  assert.ok(!sameCredentialScope('gemini', input.baseUrl, 'gemini', 'https://other.invalid/v1beta'));
  const editor = new ProviderEditorViewModel(); editor.reset(undefined, preset);
  assert.equal(editor.protocol, 'gemini'); assert.equal(editor.baseUrl, preset.defaultBaseUrl);
  editor.reset(undefined, builtinProviderInfos().find(item => item.id === 'openai'));
  editor.baseUrl = 'https://proxy.invalid/v1/chat/completions'; editor.changeProtocol('gemini');
  assert.equal(editor.baseUrl, 'https://proxy.invalid/v1');

  const request = geminiRequest([...input.messages, { role: 'user', content: 'Image', images: ['data:image/png;base64,YQ=='] }], tools, 2048);
  assert.equal(request.systemInstruction.parts[0].text, 'Instructions');
  assert.equal(request.contents[0].role, 'user');
  assert.deepEqual(plain(request.contents[0].parts.at(-1)), { inlineData: { mimeType: 'image/png', data: 'YQ==' } });
  assert.equal(request.generationConfig.maxOutputTokens, 2048);
  assert.deepEqual(plain(request.tools[0].functionDeclarations[0].parametersJsonSchema), tools[0].function.parameters);
  assert.equal(geminiRequest(input.messages, []).tools, undefined);
  assert.throws(() => geminiRequest([{ role: 'user', content: '', images: ['https://image.invalid/a.png'] }], []));
  assert.throws(() => geminiRequest([{ role: 'tool', toolCallId: 'missing', content: 'data' }], []));

  const signedParts = [{ text: 'Checking', thought: true },
    { functionCall: { name: 'read_file', args: { path: 'a' }, id: 'upstream/id:a' }, thoughtSignature: 'opaque-signature' },
    { functionCall: { name: 'read_file', args: { path: 'b' } } }];
  let visible = '', thinking = ''; const parser = new GeminiStream(text => visible += text, text => thinking += text);
  const wire = event(candidate(signedParts)) + event(candidate([], 'STOP'));
  for (const character of wire) parser.push(character);
  const turn = parser.finish(); assert.equal(turn.toolCalls.length, 2); assert.equal(visible, ''); assert.equal(thinking, 'Checking');
  const step = { ...turn, tools: turn.toolCalls.map(call => ({ call, status: 'complete', output: 'file ' + call.function.arguments })) };
  delete step.toolCalls; validateSteps([step]);
  const restored = JSON.parse(JSON.stringify(step));
  const replay = geminiRequest([...input.messages, ...stepMessages(restored)], []);
  assert.deepEqual(plain(replay.contents[1].parts), signedParts);
  assert.deepEqual(plain(replay.contents[2].parts.map(part => part.functionResponse)), [
    { id: 'upstream/id:a', name: 'read_file', response: { output: step.tools[0].output } },
    { name: 'read_file', response: { output: step.tools[1].output } }
  ]);
  assert.equal(JSON.stringify(restored.geminiContent), JSON.stringify(signedParts));
  const noArgs = new GeminiStream(() => {}); noArgs.push(event(candidate([{ functionCall: { name: 'ping' } }], 'STOP')));
  assert.equal(noArgs.finish().toolCalls[0].function.arguments, '{}');
  const textStream = new GeminiStream(text => visible += text);
  textStream.push(event(candidate([{ text: 'Hello' }])) + event(candidate([{ text: '', thoughtSignature: 'text-signature' }], 'STOP')));
  textStream.push(event({ usageMetadata: { promptTokenCount: 10, candidatesTokenCount: 2 } }));
  assert.equal(textStream.finish().geminiContent[1].thoughtSignature, 'text-signature');
  assert.equal(visible, 'Hello');

  for (const chunks of [
    [event(candidate([{ text: 'partial' }]))],
    [event(candidate([{ text: 'partial' }], 'MAX_TOKENS'))],
    [event({ promptFeedback: { blockReason: 'SAFETY' }, candidates: [] })],
    [event(candidate([], 'SAFETY'))], [event({ error: { code: 429, message: 'private body' } })],
    ['data: {bad}\n\n'], ['data: {}'], [event(candidate([{ inlineData: { mimeType: 'image/png', data: 'YQ==' } }], 'STOP'))],
    [event(candidate([{ functionCall: { name: 'bad', args: [] } }], 'STOP'))],
    [event(candidate([{ functionCall: { name: 'bad', args: null } }], 'STOP'))],
    [event(candidate([{ text: 'first' }])), event({ candidates: [{ content: {}, finishReason: 'STOP' }] })],
    [event(candidate([{ text: 'done' }], 'STOP')), event(candidate([{ text: 'extra' }]))],
    [event(candidate([{ text: '', thought: true }], 'STOP'))]
  ]) {
    assert.throws(() => { const stream = new GeminiStream(() => {}); chunks.forEach(chunk => stream.push(chunk)); stream.finish(); });
  }
  assert.throws(() => validateSteps([{ content: '', tools: [], geminiContent: [{ thoughtSignature: 4 }] }]));
  const usage = new UsageStream();
  usage.push(event({ usageMetadata: { promptTokenCount: 100, candidatesTokenCount: 20, thoughtsTokenCount: 30, cachedContentTokenCount: 40 } }));
  assert.deepEqual(plain(usage.result()), { input: 100, output: 50, reasoning: 30, cached: 40 });

  const records = [], requests = [];
  const provider = new ProtocolProvider(info, { hydrate: async messages => messages, recordUsage: record => records.push(record) });
  const respond = (request, events) => {
    request.callback(null, 200);
    const bytes = Buffer.from(events.map(event).join(''));
    // Split inside multibyte text as the native network transport can do.
    for (let offset = 0; offset < bytes.length; offset += 7) request.emit('dataReceive', Uint8Array.from(bytes.subarray(offset, offset + 7)).buffer);
    request.emit('dataEnd');
  };
  streamScript = request => {
    requests.push({ url: request.url, options: request.options, body: JSON.parse(request.options.extraData) });
    if (requests.length === 1) respond(request, [candidate(signedParts, 'STOP')]);
    else respond(request, [candidate([{ text: '完成' }, { text: '', thoughtSignature: 'final-signature' }], 'STOP'),
      { usageMetadata: { promptTokenCount: 100, candidatesTokenCount: 20, thoughtsTokenCount: 30, cachedContentTokenCount: 40 } }]);
  };
  const loopTurn = { content: '', steps: [] };
  await runAgentLoop({ model: { stream: (messages, tools, cancellation, onText, options) => provider.stream({ ...input, messages, tools }, cancellation, onText, options?.onReasoning) },
    messages: input.messages, turn: loopTurn, maxSteps: 3, tools: { definitions: () => tools, execute: async call => 'read ' + call.function.arguments }
  }, new Cancellation(), { event() {}, checkpoint: async () => {} });
  assert.equal(loopTurn.content, '完成'); assert.equal(requests.length, 2); assert.equal(loopTurn.steps.length, 2);
  assert.deepEqual(requests[1].body.contents[1].parts, signedParts);
  assert.equal(requests[1].body.contents[2].parts.length, 2);
  assert.equal(requests[0].url, geminiStreamUrl(input.baseUrl, input.model));
  assert.equal(requests[0].options.header['x-goog-api-key'], input.apiKey);
  assert.ok(!requests[0].url.includes(input.apiKey)); assert.equal(requests[0].body.model, undefined);
  assert.deepEqual(plain(records.at(-1).tokens), { input: 100, output: 50, reasoning: 30, cached: 40 });
  const { emptyData, parseAppData } = from('model/Conversation');
  const data = emptyData(); data.threads = [{ id: 'thread', title: 'Gemini', updatedAt: 1, messages: [
    { id: 'user', role: 'user', content: 'Read files', status: 'complete', error: '' },
    { id: 'answer', role: 'assistant', content: loopTurn.content, status: 'complete', error: '', steps: loopTurn.steps }
  ] }]; data.activeThreadId = 'thread';
  const saved = parseAppData(JSON.stringify(data));
  assert.deepEqual(plain(saved.threads[0].messages[1].steps[0].geminiContent), signedParts);
  const { threadEntries } = from('model/ContextProjection');
  const savedRequest = geminiRequest(threadEntries(saved.threads[0]).flatMap(entry => entry.messages), []);
  assert.deepEqual(plain(savedRequest.contents[1].parts), signedParts);
  assert.equal(savedRequest.contents.at(-1).parts.at(-1).thoughtSignature, 'final-signature');
  assert.equal(destroyed, 2);

  let pages = 0; const draft = { id: 'google-test', protocol: 'gemini', baseUrl: input.baseUrl, apiKey: 'fixture-secret', noApiKey: false };
  jsonScript = async (url, options) => {
    assert.equal(options.header['x-goog-api-key'], 'fixture-secret'); assert.equal(options.header.Accept, 'application/json');
    pages++;
    if (pages === 1) {
      assert.equal(url, input.baseUrl + '/models?pageSize=1000');
      return { responseCode: 200, result: JSON.stringify({ models: [
        { name: 'models/gemini-a', supportedGenerationMethods: ['generateContent', 'countTokens'] },
        { name: 'models/embedding', supportedGenerationMethods: ['embedContent'] }
      ], nextPageToken: 'next+/=' }) };
    }
    assert.ok(url.endsWith('&pageToken=next%2B%2F%3D'));
    return { responseCode: 200, result: JSON.stringify({ models: [{ name: 'models/gemini-b', supportedGenerationMethods: ['generateContent'] }] }) };
  };
  CredentialStore.prototype.read = async alias => { assert.equal(alias, 'saved-key'); return 'fixture-secret'; };
  const profiles = [{ id: draft.id, protocol: 'gemini', baseUrl: draft.baseUrl, credentialAlias: 'saved-key' }];
  assert.deepEqual(plain(await discoverModels({ ...draft, apiKey: '' }, profiles)), ['gemini-a', 'gemini-b']);
  assert.equal(pages, 2);
  await assert.rejects(discoverModels({ ...draft, apiKey: '', baseUrl: 'https://other.invalid/v1beta' }, profiles), /API Key/);
  jsonScript = async () => ({ responseCode: 200, result: JSON.stringify({ models: [], nextPageToken: 'repeated' }) });
  await assert.rejects(discoverModels(draft, []));
  jsonScript = async () => ({ responseCode: 403, result: 'private error' });
  await assert.rejects(discoverModels(draft, []), /403/);
  console.log('Gemini protocol, signed tool loop, persistence, usage, model discovery, and failure checks passed.');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
