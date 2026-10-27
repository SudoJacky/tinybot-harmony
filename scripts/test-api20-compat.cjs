// HarmonyOS 6 / API 20 compatibility boundaries, exercised against the real modules.
// Covers the runtime capability gate, the redirect-safe transport, empty bitmap creation,
// PDF text fallback and the validated web-reading hop loop.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets');
const t = (key, values = []) => key.replace(/\{(\d+)\}/g, (_, i) => String(values[i]));
const compile = source => ts.transpileModule(source, { compilerOptions: {
  target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS, experimentalDecorators: true
} }).outputText;

// --- fake native HTTP surface -------------------------------------------------------------
let httpCalls = [], httpResponse, httpFailure, interceptorChains = 0, aborted = 0;
const http = {
  RequestMethod: { GET: 'GET', POST: 'POST', DELETE: 'DELETE', PUT: 'PUT', HEAD: 'HEAD' },
  HttpDataType: { STRING: 'string', ARRAY_BUFFER: 'buffer' },
  InterceptorType: { REDIRECTION: 'redirect' },
  HttpInterceptorChain: class {
    addChain(items) { assert.equal(items.length, 1); return true; }
    apply() { interceptorChains++; return true; }
  },
  createHttp: () => ({ destroy() { aborted++; }, async request(url, options) {
    httpCalls.push({ url, options });
    if (httpFailure) { throw httpFailure; }
    return httpResponse;
  } })
};

let rcpCalls = [], rcpResponse, rcpFailure, rcpClosed = 0, rcpRequests = [], rcpCancelled = 0, customFetch;
const rcp = {
  Request: class { constructor(url, method, headers, content) {
    this.url = url; this.method = method; this.headers = headers; this.content = content;
  } },
  createSession: configuration => {
    rcpCalls.push(configuration);
    const session = { cancelled: false, async fetch(request) {
      rcpRequests.push(request);
      if (customFetch) return customFetch(request, configuration, session);
      if (rcpFailure) { throw rcpFailure; }
      const events = configuration.requestConfiguration.tracing?.httpEventsHandler;
      events?.onStatusCodeReceive?.(rcpResponse.statusCode);
      events?.onHeaderReceive?.(rcpResponse.headers);
      if (rcpResponse.body?.byteLength) events?.onDataReceive?.(rcpResponse.body);
      return events ? { ...rcpResponse, body: undefined } : rcpResponse;
    }, cancel() { session.cancelled = true; rcpCancelled++; session.rejectPending?.(Error('Native request cancelled')); },
    close() { rcpClosed++; } };
    return session;
  }
};

let deviceSdk = 26;
const kits = {
  '@kit.BasicServicesKit': { deviceInfo: { get sdkApiVersion() { return deviceSdk; } }, BusinessError: class extends Error {} },
  '@kit.NetworkKit': { http },
  '@kit.RemoteCommunicationKit': { rcp },
  '@kit.ArkTS': { util: {
    TextDecoder: class { constructor(encoding = 'utf-8', options) { this.decoder = new TextDecoder(encoding, options); }
      decodeToString(bytes, options) { return this.decoder.decode(bytes, options); } },
    TextEncoder: class { encodeInto(value) { return new TextEncoder().encode(value); } },
    Base64Helper: class { encodeToStringSync(value) { return Buffer.from(value).toString('base64'); } },
    generateRandomUUID: () => 'uuid-fixed'
  }, url: { URL: { parseURL: (reference, base) => new URL(reference, base) } } },
  '@kit.ImageKit': { image: {} },
  '@kit.PDFKit': { pdfService: {} },
  '@kit.CoreFileKit': { fileIo: {} }
};
const cache = new Map();
function load(name) {
  // Relative imports arrive as absolute paths without an extension; bare names resolve from the source root.
  const file = path.resolve(name.endsWith('.ets') ? name : path.resolve(root, name + '.ets'));
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  vm.runInNewContext(compile(fs.readFileSync(file, 'utf8')), { exports, Error, ArrayBuffer, Uint8Array, DataView, Promise,
    console, setTimeout, clearTimeout, Set, Map, JSON, Math, Date, RegExp, Object, String, Number, Boolean, Array,
    Observed: value => value, $r: name => name,
    require: id => {
      if (kits[id]) return kits[id];
      if (!id.startsWith('.')) { throw Error('Unexpected import: ' + id); }
      return load(path.resolve(path.dirname(file), id));
    } }, { filename: file });
  return exports;
}
// Module-level API level snapshots must be rebuilt when the simulated system changes.
const atApi = sdk => { deviceSdk = sdk; cache.clear(); };

async function main() {
  // --- ApiLevel ---------------------------------------------------------------------------
  for (const [sdk, expected] of [[20, [false, false, false, false]], [22, [false, false, false, false]],
    [23, [false, true, true, false]], [26, [true, true, true, true]]]) {
    atApi(sdk);
    const { ApiLevel } = load('common/ApiLevel');
    assert.equal(ApiLevel.sdk, sdk);
    assert.deepEqual([ApiLevel.material, ApiLevel.redirectLimit, ApiLevel.pdfTextContent, ApiLevel.drawingTools], expected,
      'Capability gates at API ' + sdk);
  }

  // --- CompatHttp -------------------------------------------------------------------------
  const spec = (extra = {}) => ({ url: 'https://api.example/path', method: 'POST',
    headers: { Authorization: 'Bearer secret', Accept: 'application/json' }, body: '{"a":1}',
    connectTimeout: 1000, readTimeout: 2000, maxBytes: 1024, dataType: 'string', redirect: 'refuse', ...extra });

  // API 26 keeps the native redirect options byte for byte.
  httpCalls = []; rcpCalls = []; interceptorChains = 0;
  httpResponse = { responseCode: 200, header: { 'Content-Type': 'application/json' }, result: '{"ok":true}' };
  atApi(26);
  let CompatHttp = load('services/CompatHttp').CompatHttp;
  let response = await CompatHttp.request(spec());
  assert.equal(response.status, 200); assert.equal(response.text, '{"ok":true}');
  assert.equal(response.header['Content-Type'], 'application/json');
  assert.equal(httpCalls.length, 1); assert.equal(rcpCalls.length, 0, 'API 26 keeps http');
  assert.equal(httpCalls[0].options.maxRedirects, 0, 'Credential requests refuse redirects');
  assert.equal(httpCalls[0].options.usingCache, false);
  assert.equal(httpCalls[0].options.expectDataType, 'string');
  assert.equal(httpCalls[0].options.extraData, '{"a":1}');
  assert.equal(httpCalls[0].options.method, 'POST');
  assert.equal(interceptorChains, 0, 'Refusing a redirect needs no interceptor');
  assert.equal(aborted >= 1, true, 'Handles are destroyed');

  // 'return' keeps the 3xx response available for the caller on API 26.
  httpCalls = []; interceptorChains = 0;
  httpResponse = { responseCode: 302, header: { Location: '/next' }, result: '' };
  response = await CompatHttp.request(spec({ redirect: 'return' }));
  assert.equal(response.status, 302); assert.equal(response.header.Location, '/next');
  assert.equal(interceptorChains, 1, 'Hop validation installs the redirect interceptor');
  assert.equal(httpCalls[0].options.maxRedirects, undefined, 'The interceptor path leaves maxRedirects unset');

  // API 20 cannot stop http redirects, so rcp carries the request with autoRedirect off.
  httpCalls = []; rcpCalls = []; rcpRequests = []; rcpClosed = 0;
  rcpResponse = { statusCode: 301, headers: { location: '/moved', 'content-type': 'text/plain' },
    body: new TextEncoder().encode('moved').buffer };
  atApi(20);
  CompatHttp = load('services/CompatHttp').CompatHttp;
  response = await CompatHttp.request(spec());
  assert.equal(httpCalls.length, 0, 'API 20 never uses the redirect-following http transport');
  assert.equal(rcpCalls.length, 1);
  assert.equal(rcpCalls[0].requestConfiguration.transfer.autoRedirect, false, 'autoRedirect stays off');
  assert.equal(rcpCalls[0].requestConfiguration.transfer.maxAutoRedirects, undefined, 'maxAutoRedirects needs autoRedirect true');
  assert.equal(rcpCalls[0].requestConfiguration.transfer.timeout.connectMs, 1000);
  assert.equal(rcpRequests[0].method, 'POST'); assert.equal(rcpRequests[0].content, '{"a":1}');
  assert.deepEqual({ ...rcpRequests[0].headers }, { Authorization: 'Bearer secret', Accept: 'application/json' });
  assert.equal(response.status, 301, 'The origin 3xx response is returned, not a redirect target');
  assert.equal(response.header.location, '/moved');
  assert.equal(response.text, 'moved');
  assert.equal(rcpClosed, 1, 'The session is always closed');

  // Binary payloads, size ceiling and abort on API 20.
  rcpResponse = { statusCode: 200, headers: {}, body: new Uint8Array([1, 2, 3]).buffer };
  response = await CompatHttp.request(spec({ dataType: 'buffer', method: 'GET', body: undefined }));
  assert.deepEqual([...new Uint8Array(response.bytes)], [1, 2, 3]);
  assert.equal(response.text, '');
  rcpResponse = { statusCode: 200, headers: {}, body: new ArrayBuffer(2048) };
  await assert.rejects(CompatHttp.request(spec({ maxBytes: 1024 })), /大小上限/, 'The body ceiling is enforced before decode');
  rcpFailure = new Error('offline');
  await assert.rejects(CompatHttp.request(spec()), /offline/, 'Native failures surface unchanged');
  rcpFailure = undefined;
  let registeredAbort;
  rcpResponse = { statusCode: 200, headers: {}, body: new ArrayBuffer(0) };
  rcpClosed = 0;
  await CompatHttp.request(spec(), abort => { registeredAbort = abort; });
  assert.equal(typeof registeredAbort, 'function', 'Cancellation can end the exchange');
  assert.equal(rcpClosed, 1);

  // Completed responses keep the handler contract on API 20.
  const seen = [];
  rcpResponse = { statusCode: 200, headers: {}, body: new TextEncoder().encode('payload').buffer };
  const handle = CompatHttp.stream(spec(), {
    onStatus: value => seen.push(['status', value]),
    onHeaders: value => seen.push(['headers', Object.keys(value).length]),
    onData: value => seen.push(['data', new TextDecoder().decode(value)]),
    onEnd: () => seen.push(['end']),
    onError: error => seen.push(['error', error.message])
  });
  assert.equal(typeof handle, 'function');
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(seen, [['status', 200], ['headers', 0], ['data', 'payload'], ['end']],
    'Status, headers, chunks and end retain their order');
  seen.length = 0;
  rcpResponse = { statusCode: 500, headers: {}, body: new ArrayBuffer(0) };
  CompatHttp.stream(spec(), {
    onStatus: value => seen.push(['status', value]), onHeaders: () => seen.push(['headers']),
    onData: () => seen.push(['data']), onEnd: () => seen.push(['end']),
    onError: error => seen.push(['error', error.message])
  });
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(seen, [['status', 500], ['headers'], ['end']], 'An empty error body still completes the callbacks');

  // A complete SSE result must be delivered while fetch is still pending, without waiting for EOF.
  seen.length = 0;
  rcpCancelled = 0;
  let finishFetch;
  customFetch = (_request, configuration, session) => new Promise((resolve, reject) => {
    finishFetch = resolve; session.rejectPending = reject;
    queueMicrotask(() => {
      const events = configuration.requestConfiguration.tracing?.httpEventsHandler;
      events?.onStatusCodeReceive?.(200);
      events?.onHeaderReceive?.({ 'mcp-session-id': 'held-session' });
      events?.onDataReceive?.(new TextEncoder().encode('data: result\n\n').buffer);
    });
  });
  const stopHeld = CompatHttp.stream(spec(), {
    onStatus: value => seen.push(['status', value]), onHeaders: value => seen.push(['headers', value['mcp-session-id']]),
    onData: value => seen.push(['data', new TextDecoder().decode(value)]), onEnd: () => seen.push(['end']),
    onError: error => seen.push(['error', error.message])
  });
  await new Promise(resolve => setImmediate(resolve));
  try {
    assert.deepEqual(seen, [['status', 200], ['headers', 'held-session'], ['data', 'data: result\n\n']],
      'A held SSE connection delivers its first frame before EOF');
  } finally { stopHeld(); finishFetch({ statusCode: 200, headers: {}, body: new ArrayBuffer(0) }); }
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(rcpCancelled, 1, 'Stopping a stream cancels the native request');
  assert.equal(seen.length, 3, 'Stopping suppresses late completion/error callbacks');

  // Stop at the first chunk crossing the byte budget; never download the rest or forward that chunk.
  let chunksSent = 0;
  rcpCancelled = 0;
  customFetch = async (_request, configuration, session) => {
    const events = configuration.requestConfiguration.tracing?.httpEventsHandler;
    events?.onStatusCodeReceive?.(200); events?.onHeaderReceive?.({});
    for (let index = 0; index < 20 && !session.cancelled; index++) {
      chunksSent++; events?.onDataReceive?.(new ArrayBuffer(512));
    }
    return { statusCode: 200, headers: {}, body: new ArrayBuffer(chunksSent * 512) };
  };
  await assert.rejects(CompatHttp.request(spec({ maxBytes: 1024 })), /大小上限/);
  assert.equal(chunksSent, 3, 'Only the boundary-crossing chunk is received beyond the budget');
  assert.equal(rcpCancelled, 1, 'Oversized downloads cancel native I/O');

  // Exercise the actual MCP parser with split JSON-RPC data and a server that never closes its stream.
  atApi(20);
  cache.set(path.resolve(root, 'services/McpOAuth.ets'), { McpOAuth: { bearer: async () => 'fixture-token' } });
  const { McpClient } = load('services/McpClient');
  const { Cancellation } = load('services/Cancellation');
  const { NetworkTransfers } = load('services/NetworkTransfers');
  let activeTransfers = 0, admittedTransfers = 0;
  const unobserveTransfers = NetworkTransfers.observe(async () => {
    activeTransfers++; admittedTransfers++;
    return async () => { activeTransfers--; };
  });
  let mcpFetchEnded = false, mcpResult;
  rcpCancelled = 0;
  customFetch = (request, configuration, session) => new Promise((_resolve, reject) => {
    assert.equal(activeTransfers, 1, 'Native MCP I/O starts only inside its admitted transfer scope');
    session.rejectPending = reject;
    queueMicrotask(() => {
      const events = configuration.requestConfiguration.tracing?.httpEventsHandler;
      events?.onStatusCodeReceive?.(200); events?.onHeaderReceive?.({ 'Mcp-Session-Id': 'mcp-held' });
      const id = JSON.parse(request.content).id;
      const frame = new TextEncoder().encode('data: ' + JSON.stringify({ jsonrpc: '2.0', id, result: { tools: [] } }) + '\n\n');
      events?.onDataReceive?.(frame.slice(0, 12).buffer);
      if (!session.cancelled) events?.onDataReceive?.(frame.slice(12).buffer);
    });
  }).finally(() => { mcpFetchEnded = true; });
  const signal = new Cancellation();
  const client = new McpClient({ url: 'https://mcp.example' });
  const rpc = client.post('tools/list', {}, signal).then(result => { mcpResult = result; });
  try {
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(Array.isArray(mcpResult?.tools), true, 'MCP resolves the matching result before server EOF');
    await rpc;
    assert.equal(activeTransfers, 0, 'Native MCP result releases its transfer before returning');
    assert.equal(admittedTransfers, 1);
    assert.equal(client.session, 'mcp-held');
    assert.equal(rcpCancelled, 1, 'MCP completion aborts its held native stream');
    assert.equal(mcpFetchEnded, true, 'Cancellation settles the in-flight fetch');
  } finally { signal.cancel(); await rpc.catch(() => {}); }
  unobserveTransfers();
  customFetch = undefined;
  const webScopes = load('services/NetworkTransfers').NetworkTransfers;
  let webAdmissions = 0, webReleases = 0;
  const unobserveWeb = webScopes.observe(async () => {
    webAdmissions++; return async () => { webReleases++; };
  });
  rcpResponse = { statusCode: 200, headers: { 'content-type': 'text/html' }, body: new TextEncoder().encode('<p>scoped</p>').buffer };
  const scopedWeb = new (load('services/NativeWebTransport').NativeWebTransport)();
  assert.equal((await scopedWeb.get('https://example.com/scoped', new Cancellation())).body, '<p>scoped</p>');
  assert.equal(webAdmissions, 1); assert.equal(webReleases, 1, 'Native web reading releases before returning the document');
  unobserveWeb();

  // --- empty PixelMap ---------------------------------------------------------------------
  atApi(26);
  let createdWith, createdResult;
  kits['@kit.ImageKit'] = { image: { createPixelMapSync: options => { createdWith = options; return createdResult; } } };
  const { createEmptyPixel } = load('services/EmptyPixel');
  createdResult = { tag: 'pixel' };
  assert.equal(createEmptyPixel({ size: { width: 2, height: 3 }, editable: true }).tag, 'pixel');
  assert.equal(createdWith.size.width, 2);
  createdResult = undefined;
  assert.throws(() => createEmptyPixel({ size: { width: 1, height: 1 } }), /空白画布/, 'A missing empty bitmap is a real failure');
  assert.equal(kits['@kit.ImageKit'].image.createEmptyPixelMap, undefined, 'Only the API 12 overload is used');

  // --- PDF text ---------------------------------------------------------------------------
  class FakePage {
    constructor(page) { this.page = page; }
    getTextContent() { return this.page.content; }
    getGraphicsObjects() { return this.page.objects; }
    release() { this.page.released = (this.page.released || 0) + 1; }
  }
  const pages = [];
  kits['@kit.PDFKit'] = { pdfService: {
    PdfDocument: class {
      loadDocument() {}
      getPageCount() { return pages.length; }
      getPage(index) { return new FakePage(pages[index]); }
      releaseDocument() {}
    },
    GraphicsObjectType: { OBJECT_TEXT: 1, OBJECT_PATH: 2, OBJECT_IMAGE: 3 },
    TextObject: class {}
  } };
  kits['@kit.BasicServicesKit'] = { deviceInfo: { get sdkApiVersion() { return deviceSdk; } }, BusinessError: class extends Error {},
    zlib: { createZipSync: () => ({}) } };

  pages.length = 0;
  pages.push({ content: 'High version text', objects: [{ type: 1, text: 'object text' }], released: 0 });
  atApi(26);
  assert.match(load('services/DocumentText').pdfText('/tmp/a.pdf'), /High version text/, 'API 23+ uses getTextContent');
  assert.equal(pages[0].released, 1, 'Pages are always released');

  pages.length = 0;
  pages.push({ objects: [{ type: 1, text: '第一行' }, { type: 3, text: 'ignored' }, { type: 1, text: 'second line' }], released: 0 });
  atApi(20);
  const documentText = load('services/DocumentText');
  const pdfOut = documentText.pdfText('/tmp/a.pdf');
  assert.match(pdfOut, /第一行\nsecond line/, 'API 20 extracts text from the graphics objects');
  assert.ok(!pdfOut.includes('ignored'), 'Non-text objects contribute no text');
  assert.equal(pages[0].released, 1);

  pages.length = 0;
  pages.push({ objects: [{ type: 3, text: '' }], released: 0 });
  assert.throws(() => documentText.pdfText('/tmp/scan.pdf'), /没有可提取的文字/, 'A scan fails instead of returning empty text');

  // HarmonyOS 6.0.0(20) has no PDFKit module at all: the namespace is undefined, so no page API
  // exists. The import path must say so instead of attaching an empty text copy.
  kits['@kit.PDFKit'] = {};
  atApi(20);
  const withoutPdfKit = load('services/DocumentText');
  assert.equal(withoutPdfKit.pdfTextAvailable(), false, 'A missing PDFKit module is reported');
  assert.throws(() => withoutPdfKit.assertPdfTextAvailable(), /PDF 组件未提供文字提取/,
    'The limitation is explained before a file is read');
  assert.throws(() => withoutPdfKit.pdfText('/tmp/a.pdf'), /PDF 组件未提供文字提取/, 'No empty text is produced');
  kits['@kit.PDFKit'] = { pdfService: {
    PdfDocument: class { loadDocument() {} getPageCount() { return 0; } getPage() { throw Error('unused'); } releaseDocument() {} },
    GraphicsObjectType: { OBJECT_TEXT: 1 }, TextObject: class {}
  } };
  atApi(26);
  assert.equal(load('services/DocumentText').pdfTextAvailable(), true, 'A present module is detected once');

  // --- invalid URL resolution -------------------------------------------------------------
  atApi(20);
  const Transport = load('services/NativeWebTransport').NativeWebTransport;
  const transport = new Transport();
  assert.throws(() => transport.resolve('javascript:alert(1)', 'https://example.com/'), /./, 'Non-http schemes are rejected');
  assert.equal(transport.resolve('/a', 'https://example.com/b/c'), 'https://example.com/a', 'Relative hops resolve');

  // --- validated web reading hops ---------------------------------------------------------
  // Replace only the native exchange; the hop loop, validation and decoding stay real.
  const compatPath = path.resolve(root, 'services/CompatHttp.ets');
  let responder;
  atApi(20);
  cache.set(compatPath, { CompatHttp: { request: async request => responder(request) } });
  const hops = [];
  const cancellation = { cancelled: false, check() {}, onCancel: () => () => {} };
  const HopTransport = load('services/NativeWebTransport').NativeWebTransport;
  const hopTransport = new HopTransport();
  const page = body => ({ status: 200, header: { 'content-type': 'text/html; charset=utf-8' },
    text: '', bytes: new TextEncoder().encode(body).buffer });
  responder = request => { hops.push(request.url); return request.url === 'https://example.com/start'
    ? { status: 302, header: { location: '/next' }, text: '', bytes: new ArrayBuffer(0) } : page('<p>done</p>'); };
  let document = await hopTransport.get('https://example.com/start', cancellation);
  assert.deepEqual(hops.slice(), ['https://example.com/start', 'https://example.com/next'], 'Each hop is fetched once');
  assert.equal(document.url, 'https://example.com/next');
  assert.equal(document.body, '<p>done</p>');
  assert.equal(document.contentType, 'text/html; charset=utf-8');
  assert.equal(responder === undefined, false);
  assert.ok(!('Authorization' in {}));

  hops.length = 0;
  responder = request => ({ status: 302, header: { location: request.url.endsWith('/a') ? '/b' : '/a' }, text: '', bytes: new ArrayBuffer(0) });
  await assert.rejects(hopTransport.get('https://example.com/a', cancellation), /重定向形成循环/);

  hops.length = 0;
  responder = request => ({ status: 302, header: { location: '/hop' + (Number(request.url.split('/hop').pop() || 0) + 1) },
    text: '', bytes: new ArrayBuffer(0) });
  await assert.rejects(hopTransport.get('https://example.com/hop0', cancellation), /超过 5 次/, 'Redirect depth is capped');

  responder = () => ({ status: 302, header: {}, text: '', bytes: new ArrayBuffer(0) });
  await assert.rejects(hopTransport.get('https://example.com/x', cancellation), /缺少 Location/);

  responder = () => ({ status: 404, header: {}, text: '', bytes: new ArrayBuffer(0) });
  await assert.rejects(hopTransport.get('https://example.com/x', cancellation), /HTTP 404/);

  responder = () => ({ status: 200, header: { 'content-type': 'text/plain' }, text: '', bytes: new ArrayBuffer(2 * 1024 * 1024) });
  await assert.rejects(hopTransport.get('https://example.com/big', cancellation), /1 MiB/, 'The 1 MiB ceiling is kept');

  responder = () => page('x');
  const dead = { cancelled: false, check() { throw new Error('cancelled by user'); }, onCancel: () => () => {} };
  await assert.rejects(hopTransport.get('https://example.com/x', dead), /cancelled by user/);

  // --- search transport refuses redirects -------------------------------------------------
  atApi(26);
  const vault = { read: async alias => { assert.equal(alias, 'search-key'); return 'search-secret'; } };
  const providerProfiles = [{ id: 'deepseek-provider', name: 'DeepSeek', protocol: 'chat-completions',
    baseUrl: 'https://api.deepseek.com', credentialAlias: 'search-key', enabled: true, noApiKey: false }];
  const searchConfig = { provider: 'deepseek', enabled: true, modelProviderId: 'deepseek-provider' };
  const SearchTransport = load('services/NativeSearchTransport').NativeSearchTransport;
  const search = new SearchTransport(searchConfig, vault, 'thread', () => {}, () => providerProfiles);
  const searchTransfers = load('services/NetworkTransfers').NetworkTransfers;
  let searchAdmissions = 0, searchReleases = 0;
  const unobserveSearch = searchTransfers.observe(async () => {
    searchAdmissions++; return async () => { searchReleases++; };
  });
  httpCalls = []; rcpCalls = [];
  httpResponse = { responseCode: 302, header: { Location: 'https://evil.example' }, result: '' };
  await assert.rejects(search.search('query', 1, cancellation), error => {
    assert.equal(error.code, 'HTTP_ERROR', 'A redirect is reported as an HTTP failure');
    assert.equal(error.details.httpStatus, 302);
    assert.match(error.message, /HTTP 302/);
    return true;
  });
  assert.equal(httpCalls.length, 1);
  assert.equal(httpCalls[0].options.maxRedirects, 0, 'The search key stays on its origin');
  assert.equal(httpCalls[0].options.header.Authorization, 'Bearer search-secret');
  assert.equal(rcpCalls.length, 0);
  assert.equal(searchAdmissions, 1); assert.equal(searchReleases, 1, 'HTTP failures also end the native search scope');
  unobserveSearch();

  console.log('PASS API 20 compatibility: capability gates, redirect-safe transport (http and rcp), ' +
    'live SSE/MCP delivery, bounded native reception/cancellation, empty bitmap creation, PDF text fallback, web hop validation and search redirect refusal');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
