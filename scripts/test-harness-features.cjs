// Exercise actual tools, loop, settings and native transport via deterministic I/O adapters.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(studio + '/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '../entry/src/main/ets'), cache = new Map();
let network, requests = [], destroys = 0, interceptors = [];
const kits = {
  '@kit.BasicServicesKit': { deviceInfo: { sdkApiVersion: 26 }, BusinessError: class extends Error {} },
  '@kit.RemoteCommunicationKit': { rcp: { createSession() { throw Error('The API 20 transport must not run here'); } } },
  '@kit.ArkTS': { util: { generateRandomUUID: require('node:crypto').randomUUID,
    TextEncoder: class { encodeInto(s) { return new TextEncoder().encode(s); } } } },
  '@kit.NetworkKit': { http: { RequestMethod: { POST: 'POST' }, HttpDataType: { STRING: 'string' },
    InterceptorType: { REDIRECTION: 'redirect' }, HttpInterceptorChain: class {
      addChain(items) { interceptors.push(...items); return true; } apply() { return true; }
    }, createHttp: () => ({ destroy: () => destroys++, request: (url, options, cb) => {
      requests.push({ url, options });
      // http.request offers both a callback and a promise form; the compat layer awaits it.
      return new Promise((resolve, reject) => network(url, options, (error, response) => {
        if (cb) { cb(error, response); }
        if (error) { reject(error); } else { resolve(response); }
      }));
    } }) } }
};
function load(file) {
  file = path.resolve(file.endsWith('.ets') ? file : file + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true
  } }).outputText, { exports, Error, console, Observed: cls => cls,
    // Keep real cancel/await boundaries, without slowing down retry tests.
    setTimeout: (fn, ms) => setTimeout(fn, ms === 60000 ? ms : Math.min(ms, 2)), clearTimeout,
    require: id => kits[id] || load(path.resolve(path.dirname(file), id)) }, { filename: file });
  return exports;
}
const from = name => load(root + '/' + name), plain = value => JSON.parse(JSON.stringify(value));
const { Cancellation, RunCancelledError } = from('services/Cancellation');
const { runAgentLoop } = from('services/AgentLoop');
const { TransientProviderError, httpProviderError } = from('services/providers/ProviderErrors');
const { emptyData, parseAppData, requestHistory } = from('model/Conversation');
const { validateSteps, stepMessages } = from('model/Agent');
const { PresentTools } = from('services/PresentTools');
const { deliveredFiles } = from('model/Deliverables');
const { ReferenceTools } = from('services/ReferenceTools');
const { captureThreadReference, referenceContext } = from('model/ThreadReferences');
const { defaultSearchConfig, deepSeekSearchProfiles, searchCredentialAlias, validateSearchConfig } = from('model/WebSearch');
const { saveSearchSettings } = from('services/SearchSettings');
const { WebSearchTools } = from('services/WebSearchTools');
const { NativeSearchTransport } = from('services/NativeSearchTransport');
const { DeepSeekSearchProvider } = from('services/search/DeepSeekSearchProvider');
const { TavilySearchProvider } = from('services/search/TavilySearchProvider');
const call = (name, args, id = 'call') => ({ id, type: 'function', function: { name, arguments: JSON.stringify(args) } });
const reply = (content, toolCalls = []) => ({ content, toolCalls });
const thread = () => ({ id: 'chat', title: 'test', updatedAt: 1, messages: [
  { id: 'user', role: 'user', content: 'Work', status: 'complete', error: '' },
  { id: 'answer', role: 'assistant', content: 'Done', status: 'complete', error: '' }
] });
function loop(model, tools = { definitions: () => [], execute: async () => '' }, extra = {}) {
  const turn = { content: '', steps: [] }, cancellation = new Cancellation(), saved = [], events = [];
  const observer = { checkpoint: async () => saved.push(plain(turn)), event: event => events.push(event), ...extra };
  return { turn, cancellation, saved, events, run: () => runAgentLoop({ model, tools, turn, messages: [{ role: 'user', content: 'Work' }], maxSteps: 20 }, cancellation, observer) };
}
async function main() {
  const { WebTools } = from('services/WebTools');
  const { ToolSet } = from('services/ToolSet');
  const { RuleTools } = from('services/RuleTools');
  const { TeamTools, TeamToolLane } = from('services/TeamCoordinator');
  const { AgentStepViewModel } = from('viewmodel/SessionViewModels');
  const web = new WebTools({ resolve: (reference, base) => new URL(reference, base).href,
    get: async () => ({url:'https://example.com/page',contentType:'text/html',body:
      '<head><link rel="icon" href="/site.svg"><title>Title</title></head><main>Body</main>'}) });
  const webRequests = [];
  const webRun = loop({ stream: async messages => {
    webRequests.push(plain(messages));
    return webRequests.length === 1 ? reply('', [call('read_web', {url:'https://example.com/page'})]) : reply('Title');
  } }, new TeamTools(new RuleTools(new ToolSet([web]),true), new TeamToolLane()));
  await webRun.run();
  const webReceipt = webRun.turn.steps[0].tools[0];
  assert.equal(webReceipt.websiteIcon, 'https://example.com/site.svg');
  assert.equal(JSON.parse(webReceipt.output).content,'Body');
  assert.equal(JSON.parse(webReceipt.output).favicon,undefined);
  assert.ok(!JSON.stringify(webRequests).includes('site.svg'));
  assert.ok(!JSON.stringify(webRequests).includes('favicon'));
  const webData = emptyData(), webThread = thread();
  webThread.messages[1].steps = webRun.turn.steps; webData.threads = [webThread]; webData.activeThreadId = webThread.id;
  const restoredWeb = parseAppData(JSON.stringify(webData));
  const webSteps = restoredWeb.threads[0].messages[1].steps;
  assert.equal(webSteps[0].tools[0].websiteIcon,webReceipt.websiteIcon);
  assert.ok(!JSON.stringify(requestHistory(restoredWeb.threads[0].messages,'')).includes('site.svg'));
  const webView = new AgentStepViewModel({content:'',tools:[{...webReceipt,websiteIcon:undefined}]});
  const retainedTool = webView.tools[0]; webView.update(webSteps[0]);
  assert.equal(webView.tools[0],retainedTool); assert.equal(retainedTool.websiteIcon,webReceipt.websiteIcon);
  // The previously installed build stored the icon in the result. Loading migrates it without losing page fields.
  const legacyPage = {...JSON.parse(webReceipt.output),favicon:webReceipt.websiteIcon};
  webThread.messages[1].steps[0].tools[0] = {...webReceipt,websiteIcon:undefined,output:JSON.stringify(legacyPage)};
  const migratedWeb = parseAppData(JSON.stringify(webData));
  const migrated = migratedWeb.threads[0].messages[1].steps[0].tools[0];
  assert.equal(migrated.websiteIcon,webReceipt.websiteIcon);
  assert.deepEqual(JSON.parse(migrated.output),JSON.parse(webReceipt.output));
  assert.ok(!JSON.stringify(requestHistory(migratedWeb.threads[0].messages,'')).includes('site.svg'));
  assert.equal(JSON.parse(await web.execute(call('read_web',{url:'https://example.com/page'}),new Cancellation())).favicon,undefined);
  const longBody = '<h1>Financial statement</h1><table><tr><td>Revenue 94827</td></tr></table>' +
    '<p>Definition and references '.repeat(1200) + 'TAIL_MARKER';
  const pagedWeb = new WebTools({ resolve: (reference, base) => new URL(reference, base).href,
    get: async () => ({url:'https://example.com/report',contentType:'text/html',body:longBody}) });
  const readPage = args => pagedWeb.execute(call('read_web',{url:'https://example.com/report',...args}),new Cancellation()).then(JSON.parse);
  const head = await readPage({});
  assert.equal(head.content.length,8000); assert.equal(head.nextOffset,8000); assert.equal(head.truncated,true);
  assert.ok(head.content.includes('Revenue 94827'));
  let gathered = head.content, offset = head.nextOffset, lastPage;
  while (offset !== undefined) {
    lastPage = await readPage({offset,maxChars:3000}); gathered += lastPage.content; offset = lastPage.nextOffset;
  }
  assert.equal(gathered.length,head.totalChars); assert.ok(gathered.endsWith('TAIL_MARKER'));
  assert.equal(lastPage.nextOffset,undefined); assert.equal(lastPage.truncated,true);
  assert.equal((await readPage({maxChars:20000})).content.length,20000);
  for (const contentType of ['application/atom+xml','application/rss+xml','application/ld+json']) {
    const body=contentType.endsWith('+json')?'[{"name":"Annual report"}]':'<feed><entry><title>Annual report</title></entry></feed>';
    const structuredWeb=new WebTools({get:async()=>({url:'https://example.com/feed',contentType,body}),resolve:(reference,base)=>new URL(reference,base).href});
    const page=JSON.parse(await structuredWeb.execute(call('read_web',{url:'https://example.com/feed'}),new Cancellation()));
    assert.equal(page.content,body);assert.equal(page.truncated,false);
  }
  for (const args of [{offset:-1},{offset:0.5},{maxChars:0},{maxChars:20001},{selector:'script'}]) {
    await assert.rejects(readPage(args),/read_web requires/);
  }
  console.log('PASS bounded web pages retain every character and source, expose continuation and reject invalid ranges');
  console.log('PASS favicon stays UI-only through real tool dispatch, model continuation, persistence, historical migration and retained view updates');
  const files = new Set(['report.md', 'diagram.png']);
  const present = new PresentTools(async path => { if (!files.has(path)) throw Error('File missing'); return '/workspace/' + path; });
  const result = await present.execute(call('present_files', { files: [{ path: 'report.md', description: 'Report' }] }), new Cancellation());
  const step = { content: '', tools: [{ call: call('present_files', {}), status: 'complete', output: result }] };
  assert.deepEqual(plain(deliveredFiles([step])), [{ path: 'report.md', description: 'Report' }]);
  assert.equal(deliveredFiles([{ ...step, tools: [{ ...step.tools[0], status: 'failed' }] }]).length, 0);
  await assert.rejects(present.execute(call('present_files', { files: [{ path: '../secret' }] }), new Cancellation()));
  await assert.rejects(present.execute(call('present_files', { files: [{ path: 'report.md' }, { path: 'missing' }] }), new Cancellation()), /missing/);
  const saved = emptyData(); const chat = thread(); chat.messages[1].steps = [step]; saved.threads = [chat]; saved.activeThreadId = chat.id;
  assert.equal(deliveredFiles(parseAppData(JSON.stringify(saved)).threads[0].messages[1].steps)[0].path, 'report.md');
  console.log('PASS deliverables: validation, atomic failure, successful receipts and reload');

  const source = thread(); source.messages[0].content = 'EARLY_MARKER\n' + 'old context\n'.repeat(1200);
  source.messages[1].content = 'LATEST_MARKER';
  const snapshot = captureThreadReference(source); assert.ok(snapshot.truncated && snapshot.fullContent.includes('EARLY_MARKER'));
  const prompt = referenceContext([snapshot], 'user'); assert.ok(!prompt.includes('EARLY_MARKER') && prompt.includes('read_reference') && prompt.includes('user'));
  const local = thread(); local.messages[0].references = [snapshot]; saved.threads = [local];
  const restored = parseAppData(JSON.stringify(saved)).threads[0]; source.messages[0].content = 'CHANGED';
  const references = new ReferenceTools(() => restored.messages);
  const page = JSON.parse(await references.execute(call('read_reference', { messageId: 'user', threadId: 'chat', limit: 2 }), new Cancellation()));
  assert.ok(page.content.includes('EARLY_MARKER') && !page.content.includes('CHANGED')); assert.ok(page.truncated && !page.previewOnly);
  await assert.rejects(references.execute(call('read_reference', { messageId: 'other', threadId: 'chat' }), new Cancellation()), /not found/);
  assert.ok(!requestHistory(restored.messages, '')[0].content.includes('EARLY_MARKER'));
  delete restored.messages[0].references[0].fullContent;
  assert.equal(JSON.parse(await references.execute(call('read_reference', { messageId: 'user', threadId: 'chat' }), new Cancellation())).previewOnly, true);
  console.log('PASS references: captured full text survives reload, preview budget, paging, scope and legacy snapshots');

  const toolArgs = [{ a: 1, b: 2 }, { b: 2, a: 1 }, { a: 1, b: 2 }]; let calls = 0, observedReminder;
  const repeated = loop({ stream: async messages => {
    if (calls < 3) { const index = calls++; return reply('', [call('read_file', toolArgs[index], 'read' + index)]); }
    observedReminder = messages.find(message => message.content.includes('Runtime reminder')); return reply('Changed approach');
  } }, { definitions: () => [{ type: 'function', function: { name: 'read_file' } }], execute: async () => { throw Error('Missing'); } });
  await repeated.run(); assert.ok(observedReminder); validateSteps(repeated.turn.steps);
  assert.ok(stepMessages(repeated.turn.steps[2]).some(message => message.content.includes('Runtime reminder')));
  console.log('PASS repetition: failed calls and canonical arguments produce a persisted, replayable reminder');

  let requestsMade = 0, writes = 0;
  const retry = loop({ stream: async () => {
    requestsMade++;
    if (requestsMade === 1) return reply('', [call('write_file', {}, 'write')]);
    if (requestsMade < 4) throw new TransientProviderError('Unavailable', 'http_503');
    return reply('Done');
  } }, { definitions: () => [{ type: 'function', function: { name: 'write_file' } }], execute: async () => { writes++; return 'saved'; } });
  await retry.run(); assert.equal(writes, 1); assert.equal(requestsMade, 4); assert.equal(retry.turn.steps[1].retries.length, 2);
  assert.ok(retry.saved.some(turn => turn.steps[1]?.retries?.[0].waiting)); validateSteps(retry.turn.steps);
  let attempts = 0;
  const exhausted = loop({ stream: async () => { attempts++; throw new TransientProviderError('Busy', 'http_429'); } });
  await assert.rejects(exhausted.run(), /Busy/); assert.equal(attempts, 3);
  attempts = 0;
  const partial = loop({ stream: async (_m, _t, _c, onText) => { attempts++; onText('partial'); throw new TransientProviderError('Broken', 'transport'); } });
  await assert.rejects(partial.run(), /Broken/); assert.equal(attempts, 3); assert.equal(partial.turn.content, 'partial');
  assert.equal(partial.turn.steps[0].retries.length,2);
  let recoveredRequests = 0, committedWrites = 0, lateText;
  const recoveryMessages = [];
  const recovered = loop({stream:async (messages,_tools,_cancel,onText,options) => {
    recoveredRequests++; recoveryMessages.push(plain(messages));
    if (recoveredRequests === 1) return reply('Earlier',[call('write_file',{},'committed-write')]);
    if (recoveredRequests === 2) {
      lateText = onText; onText('unfinished answer'); options.onReasoning('unfinished thought');
      throw new TransientProviderError('Receive failed','transport');
    }
    lateText('late failed-attempt delta'); onText('Done'); return reply('Done');
  }},{definitions:()=>[{type:'function',function:{name:'write_file'}}],execute:async()=>{committedWrites++;return 'saved';}});
  await recovered.run();
  assert.equal(recoveredRequests,3); assert.equal(committedWrites,1);
  assert.deepEqual(recoveryMessages[1],recoveryMessages[2],'Retry uses the same committed history');
  assert.equal(recovered.turn.content,'Earlier\n\nDone');
  assert.ok(!JSON.stringify(recovered.turn).includes('unfinished'));
  assert.ok(!JSON.stringify(recovered.turn).includes('late failed-attempt'));
  assert.ok(recovered.saved.some(turn=>turn.content==='Earlier'&&turn.steps[1]?.retries?.[0].waiting&&turn.steps[1].content===''&&turn.steps[1].reasoningContent===''));
  attempts=0;
  const fatal = loop({stream:async(_m,_t,_c,onText)=>{attempts++;onText('kept');throw Error('Invalid response');}});
  await assert.rejects(fatal.run(),/Invalid response/);assert.equal(attempts,1);assert.equal(fatal.turn.content,'kept');
  const {requestWithRetry}=from('services/RequestRetry');
  const committedStep={content:'kept',tools:[{call:call('write_file',{}),status:'complete',output:'saved'}]};
  let committedAttempts=0;
  await assert.rejects(requestWithRetry(committedStep,async()=>{committedAttempts++;throw new TransientProviderError('No replay','transport');},new Cancellation(),async()=>{},()=>{}),/No replay/);
  assert.equal(committedAttempts,1);assert.equal(committedStep.content,'kept');
  const cancelled = loop({ stream: async (_m,_t,_c,onText) => { onText('discard on cancel'); throw new TransientProviderError('Busy', 'http_503'); } });
  cancelled.events.push = event => { if (event.type === 'request_retry') cancelled.cancellation.cancel(); };
  await assert.rejects(cancelled.run(), RunCancelledError);
  let saveAttempts=0;
  const badSave = loop({ stream: async (_m,_t,_c,onText) => { saveAttempts++; onText('discard before checkpoint'); throw new TransientProviderError('Busy', 'http_503'); } }, undefined,
    { checkpoint: async () => { throw Error('Disk failure'); } });
  await assert.rejects(badSave.run(), /Disk failure/);
  assert.equal(saveAttempts,1,'A failed retry checkpoint prevents the next model request');
  assert.ok(!(httpProviderError(401, '{}') instanceof TransientProviderError));
  assert.ok(!(httpProviderError(429, '{"error":{"code":"insufficient_quota"}}') instanceof TransientProviderError));
  assert.equal(cancelled.turn.steps[0].retries[0].waiting, false);
  console.log('PASS retries: bounded attempts, durable wait, cancel/save barriers, partial output and no repeated writes');

  const profile = { id: 'deepseek', name: 'DeepSeek', presetId: 'deepseek', enabled: true, noApiKey: false,
    baseUrl: 'https://api.deepseek.com', credentialAlias: 'model-key', protocol: 'chat-completions', models: ['deepseek-flash'] };
  const data = emptyData(); data.providerProfiles = [profile];
  let writesToVault = 0, committed, deleted = [], credentialReads = [];
  const vault = { read: async alias => { assert.ok(alias); credentialReads.push(alias); return 'test-secret'; }, write: async () => writesToVault++, remove: async alias => deleted.push(alias) };
  const draft = { provider: 'deepseek', enabled: true, baseUrl: '', apiKey: '' };
  await saveSearchSettings(data, draft, vault, () => 'unique', async next => { committed = plain(next); });
  const config = committed.productivity.options.search;
  assert.equal(writesToVault, 0);
  assert.deepEqual(config, { provider: 'deepseek', enabled: true, modelProviderId: profile.id });
  assert.deepEqual(plain(parseAppData(JSON.stringify(committed)).productivity.options.search), config);
  assert.equal(searchCredentialAlias(config, [{ ...profile, credentialAlias: 'rotated' }]), 'rotated');
  assert.throws(() => searchCredentialAlias(config, [{ ...profile, baseUrl: 'https://elsewhere.example' }]));
  assert.throws(() => searchCredentialAlias(config, []));
  assert.throws(() => searchCredentialAlias(config, [{ ...profile, enabled: false }]));
  assert.equal(deepSeekSearchProfiles([{ ...profile, noApiKey: true }, { ...profile, credentialAlias: '' },
    { ...profile, baseUrl: 'https://api.deepseek.com.attacker.example' }, { ...profile, baseUrl: 'https://gateway.example' }]).length, 0);
  assert.equal(deepSeekSearchProfiles([{ ...profile, protocol: 'responses', baseUrl: 'https://api.deepseek.com:443/v1' }]).length, 1);
  await assert.rejects(saveSearchSettings({ ...data, providerProfiles: [] }, draft, vault, () => 'id', async () => {}), /请先.*DeepSeek/);
  await assert.rejects(saveSearchSettings(data, draft, { ...vault, read: async () => '' }, () => 'id', async () => {}), /API Key 为空/);
  await assert.rejects(saveSearchSettings(data, { ...draft, apiKey: 'independent' }, vault, () => 'id', async () => {}), /无需填写独立密钥/);
  await assert.rejects(saveSearchSettings({ ...data, providerProfiles: [profile, { ...profile, id: 'another' }] }, draft, vault, () => 'id', async () => {}), /请选择/);
  let selectedConfig;
  await saveSearchSettings({ ...data, providerProfiles: [profile, { ...profile, id: 'another', credentialAlias: 'second-key' }] },
    { ...draft, modelProviderId: 'another' }, vault, () => 'id', async next => { selectedConfig = next.productivity.options.search; });
  assert.equal(selectedConfig.modelProviderId, 'another');
  assert.throws(() => searchCredentialAlias(selectedConfig, [profile]), /重新选择/);
  await saveSearchSettings({ ...emptyData(), providerProfiles: [] }, { ...draft, enabled: false }, vault, () => 'id', async next => {
    validateSearchConfig(next.productivity.options.search);
    assert.equal(next.productivity.options.search.enabled, false);
  });
  const tavilyDraft = { provider: 'tavily', enabled: true, baseUrl: 'https://api.tavily.com', apiKey: 'test-search-key' };
  await saveSearchSettings(committed, tavilyDraft, vault, () => 'separate', async next => { committed = plain(next); });
  assert.equal(writesToVault, 1); assert.ok(!deleted.includes('model-key')); assert.equal(committed.productivity.options.search.provider, 'tavily');
  await saveSearchSettings(plain(committed), { ...tavilyDraft, apiKey: '' }, vault, () => 'id', async next => {
    assert.equal(next.productivity.options.search.credentialAlias, 'tinybot-search-separate');
  });
  await assert.rejects(saveSearchSettings(plain(committed), { ...tavilyDraft, apiKey: '', baseUrl: 'https://other.example' }, vault, () => 'id', async () => {}), /重新填写/);
  await assert.rejects(saveSearchSettings(committed, { ...tavilyDraft, apiKey: 'replacement' }, vault, () => 'rollback', async () => { throw Error('Save failed'); }), /Save failed/);
  assert.ok(deleted.includes('tinybot-search-rollback')); assert.ok(!deleted.includes('tinybot-search-separate'));
  console.log('PASS search settings: automatic key reuse, rotation, endpoint isolation, ambiguous selection, provider switch and rollback');

  const longSummary = 'Evidence '.repeat(300);
  const deepseekBody = JSON.stringify({ results: [
    { rerank_score: 2.4, title: 'Source', url: 'https://source.example', snippet: 'Short',
      summary: longSummary, content: '', site_name: 'Example', date: '2026-06-01T00:00:00+00:00', authority: 3 },
    { title: 'Duplicate', url: 'https://source.example', summary: 'Duplicate' },
    { title: 'Second', url: 'https://second.example', summary: 'Other' }
  ] });
  const ds = new DeepSeekSearchProvider(), tavily = new TavilySearchProvider();
  const normalized = ds.parse(deepseekBody, 1);
  assert.equal(normalized.sources.length, 1); assert.equal(normalized.sources[0].snippet, longSummary);
  assert.equal(normalized.sources[0].publishedAt, '2026-06-01T00:00:00+00:00');
  assert.ok(!('truncated' in normalized));
  assert.equal(ds.parse('{"results":[]}', 5).sources.length, 0);
  assert.throws(() => ds.parse('{"answer":"free text"}', 5), /structured results/);
  assert.throws(() => ds.parse('{"results":[{"url":"ftp://source.example"}]}', 5), /Invalid search source URL/);
  assert.throws(() => ds.parse('{"error":{"message":"bad query"}}', 5), /bad query/);
  const tavilyBody = JSON.stringify({ answer: 'Ignore me', results: [{ url: 'https://source.example', title: 'Source',
    content: longSummary, published_date: '2026-06-01T00:00:00+00:00' }] });
  assert.deepEqual(plain(tavily.parse(tavilyBody, 5).sources), plain(normalized.sources));
  let liveProfiles = [profile];
  const recorded = []; const native = new NativeSearchTransport(config, vault, 'chat', value => recorded.push(plain(value)), () => liveProfiles);
  network = (_url, options, callback) => {
    const body = JSON.parse(options.extraData);
    assert.equal(body.query, 'test'); assert.equal(body.count, 1); assert.equal(body.need_content, false);
    assert.equal(options.header.Authorization, 'Bearer test-secret');
    callback(null, { responseCode: 200, result: deepseekBody });
  };
  const tool = new WebSearchTools(native); const found = JSON.parse(await tool.execute(call('search_web', { query: 'test', maxResults: 1 }), new Cancellation()));
  assert.equal(found.sources.length, 1); assert.equal(requests.at(-1).url, 'https://api.deepseek.com/v1/tools/search');
  assert.equal(requests.at(-1).options.maxRedirects, 0, 'Search refuses redirects before sending the key');
  assert.equal(recorded.at(-1).tokens, undefined);
  assert.ok(!JSON.stringify(recorded).includes('test-secret'));
  assert.equal(recorded.at(-1).model, 'search');
  assert.equal(credentialReads.at(-1), 'model-key');
  await assert.rejects(tool.execute(call('search_web', { query: 'x'.repeat(129) }), new Cancellation()), /Invalid search query/);
  network = (_url, _options, callback) => callback(null, { responseCode: 402, result: '' });
  await assert.rejects(tool.execute(call('search_web', { query: 'test' }), new Cancellation()), /balance is insufficient/);
  const beforeMissingProfile = requests.length; liveProfiles = [];
  await assert.rejects(tool.execute(call('search_web', { query: 'test' }), new Cancellation()), /重新选择/);
  assert.equal(requests.length, beforeMissingProfile); liveProfiles = [profile];
  const tavilyConfig = { ...defaultSearchConfig('tavily'), enabled: true, credentialAlias: 'search-key' };
  network = (_url, options, cb) => { assert.equal(JSON.parse(options.extraData).include_answer, false); cb(null, { responseCode: 200, result: tavilyBody }); };
  const other = new WebSearchTools(new NativeSearchTransport(tavilyConfig, vault, 'chat', () => {}, () => []));
  assert.equal(JSON.parse(await other.execute(call('search_web', { query: 'test' }), new Cancellation())).sources[0].snippet, longSummary);
  assert.equal(requests.at(-1).url, 'https://api.tavily.com/search');
  network = (_url, _options, callback) => callback(null, { responseCode: 302, result: '' });
  await assert.rejects(tool.execute(call('search_web', { query: 'test' }), new Cancellation()), /HTTP 302/);
  const stopped = new Cancellation(); network = () => stopped.cancel();
  await assert.rejects(tool.execute(call('search_web', { query: 'test' }), stopped), RunCancelledError);
  console.log('PASS search interface: both providers, official Search contract, structured sources, deduplication, query limits, request accounting, balance/redirect refusal and cancellation');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
