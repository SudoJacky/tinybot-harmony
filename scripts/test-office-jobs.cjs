const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { crc32, inflateRawSync } = require('node:zlib');
const { randomUUID, createHash } = require('node:crypto');

const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(studio + '/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '../entry/src/main');
const library = fs.readFileSync(path.join(root, 'resources/rawfile/office/office.bundle.js'), 'utf8');
const cache = new Map();

function load(name) {
  const file = name + '.ets';
  if (cache.has(file)) return cache.get(file);
  const exports = {};
  cache.set(file, exports);
  const source = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true },
  }).outputText;
  vm.runInNewContext(source, { exports, setTimeout, clearTimeout, Observed: (type) => type, require: (id) => {
    if (id === '@kit.ArkTS') return { util: { generateRandomUUID: randomUUID, TextEncoder: class {
      encodeInto(text) { return Buffer.from(text, 'utf8'); }
    }, Base64Helper: class {
      async encodeToString(bytes) { return Buffer.from(bytes).toString('base64'); }
      async decode(value) { return Buffer.from(value, 'base64'); }
    } } };
    return load(path.resolve(path.dirname(file), id));
  } }, { filename: file });
  return exports;
}

function parts(bytes, binary = false) {
  const output = new Map();
  const end = bytes.length - 22;
  assert.equal(bytes.readUInt32LE(end), 0x06054b50);
  let offset = bytes.readUInt32LE(end + 16);
  const count = bytes.readUInt16LE(end + 10);
  for (let index = 0; index < count; index++) {
    assert.equal(bytes.readUInt32LE(offset), 0x02014b50);
    const length = bytes.readUInt16LE(offset + 28);
    const name = bytes.toString('utf8', offset + 46, offset + 46 + length);
    const local = bytes.readUInt32LE(offset + 42);
    assert.equal(bytes.readUInt32LE(local), 0x04034b50);
    const start = local + 30 + bytes.readUInt16LE(local + 26) + bytes.readUInt16LE(local + 28);
    const entry = bytes.subarray(start, start + bytes.readUInt32LE(offset + 20));
    const unpacked = bytes.readUInt16LE(offset + 10) === 8 ? inflateRawSync(entry) : entry;
    output.set(name, binary ? unpacked : unpacked.toString('utf8'));
    offset += 46 + length + bytes.readUInt16LE(offset + 30) + bytes.readUInt16LE(offset + 32);
  }
  return output;
}

function storedZip(entries) {
  const local = [];
  const central = [];
  let offset = 0;
  for (const [name, data] of entries) {
    const filename = Buffer.from(name);
    const crc = crc32(data);
    const header = Buffer.alloc(30);
    header.writeUInt32LE(0x04034b50);
    header.writeUInt16LE(20, 4);
    header.writeUInt32LE(crc, 14);
    header.writeUInt32LE(data.length, 18);
    header.writeUInt32LE(data.length, 22);
    header.writeUInt16LE(filename.length, 26);
    local.push(header, filename, data);
    const directory = Buffer.alloc(46);
    directory.writeUInt32LE(0x02014b50);
    directory.writeUInt16LE(20, 4);
    header.copy(directory, 6, 4, 30);
    directory.writeUInt32LE(offset, 42);
    central.push(directory, filename);
    offset += header.length + filename.length + data.length;
  }
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50);
  end.writeUInt16LE(entries.size, 8);
  end.writeUInt16LE(entries.size, 10);
  end.writeUInt32LE(central.reduce((total, item) => total + item.length, 0), 12);
  end.writeUInt32LE(offset, 16);
  return Buffer.concat([...local, ...central, end]);
}

const call = (name, args) => ({ id: randomUUID(), type: 'function', function: { name, arguments: JSON.stringify(args) } });
const loadModule = (name) => load(path.join(root, 'ets', name));

async function main() {
  const { WorkspaceCode } = loadModule('services/WorkspaceCode');
  const { CodeExecutionTools } = loadModule('services/CodeExecutionTools');
  const { WorkspaceTools } = loadModule('services/WorkspaceTools');
  const { RuleTools } = loadModule('services/RuleTools');
  const { PresentTools } = loadModule('services/PresentTools');
  const { Cancellation } = loadModule('services/Cancellation');
  const { executeToolBatch } = loadModule('services/ToolExecution');
  const { OrchestrationTools } = loadModule('services/OrchestrationTools');
  const { toolReceipts, validateSteps } = loadModule('model/Agent');
  const { collectFileOperations } = loadModule('model/FileOperations');
  const files = new Map([['input.csv', Buffer.from('指标,数值\n中文,12')], ['notes.txt', Buffer.from('Original text')]]);
  const version = (bytes) => createHash('sha256').update(bytes).digest('hex');
  const read = (name, maximum) => {
    const bytes = files.get(name);
    if (!bytes) throw new Error('Input missing');
    if (maximum !== undefined && bytes.length > maximum) throw new Error('Input exceeds limit');
    return bytes;
  };
  const workspace = {
    async readJobInput(name, maximum) { return read(name, maximum); },
    async createJobOutput(name, bytes, cancellation) {
      cancellation.check();
      if (files.has(name)) throw new Error('Output exists');
      files.set(name, Buffer.from(bytes));
    },
    async read(name, _cancellation, maximum) {
      const bytes = read(name, maximum);
      return { path: name, content: bytes.toString('utf8'), version: version(bytes) };
    },
    async write(name, text, cancellation, guard) {
      cancellation.check();
      const existing = files.get(name);
      assert.equal(guard.version, existing ? version(existing) : null);
      const bytes = Buffer.from(text);
      files.set(name, bytes);
      return { path: name, bytes: bytes.length, written: true, version: version(bytes) };
    },
  };
  const executor = { async execute(source, catalog, invoke) {
    const tools = Object.fromEntries(JSON.parse(catalog).map(({ name }) => [name, async (args) => JSON.parse(await invoke(name, JSON.stringify(args)))]));
    try {
      // DevEco's Node may have these methods disabled. The app's vendored QuickJS includes them.
      const base64 = 'Uint8Array.fromBase64 = value => new Uint8Array(decode(value));' +
        'Uint8Array.prototype.toBase64 = function () { return encode(this); };';
      const result = await vm.runInNewContext(base64 + '(async function(){"use strict";' + source + '\n})()', {
        tools,
        decode: (value) => Buffer.from(value, 'base64'),
        encode: (value) => Buffer.from(value).toString('base64'),
      }, { timeout: 10000 });
      return JSON.stringify({ status: 'ok', result });
    } catch (error) { return JSON.stringify({ status: 'error', error: error.message }); }
  } };
  const workspaceCode = new WorkspaceCode(workspace, new WorkspaceTools(workspace), executor, async () => library);
  const codeTool = new CodeExecutionTools({ execute() { throw Error('Missing invocation context'); } }, workspaceCode);
  const readOnly = new RuleTools(codeTool, true);
  const research = {
    definitions: () => codeTool.definitions(),
    execute: (incoming, signal, context) => codeTool.execute(incoming, signal, { ...context, workspaceWrite: 'text' }),
  };
  const full = new OrchestrationTools(codeTool, executor);
  async function dispatch(incoming, tools = codeTool, checkpoint = async () => {}) {
    const step = { content: '', tools: [{ call: incoming, status: 'pending', output: '' }] };
    await executeToolBatch(step, 0, tools, tools.definitions(), new Cancellation(), { checkpoint, event: () => {} });
    validateSteps([step]);
    return step.tools[0];
  }
  const run = (code, input, tools) => dispatch(call('execute_code', { code, input }), tools);
  const write = (output, expression, input = {}, tools) =>
    run('return await workspace.write(input.output, ' + expression + ');', { ...input, output }, tools);
  const success = (receipt) => {
    assert.equal(receipt.status, 'complete', receipt.output);
    return JSON.parse(receipt.output);
  };
  const failure = (receipt, error) => {
    assert.equal(receipt.status, 'failed', receipt.output);
    assert.match(receipt.output, error);
  };

  const pure = await run('return [input, typeof tools, typeof ALL_TOOLS, typeof require];', { values: [1, 2] }, readOnly);
  assert.deepEqual(success(pure).result, [{ values: [1, 2] }, 'undefined', 'undefined', 'undefined']);
  assert.equal(pure.children, undefined);
  const workbook = 'office.xlsx([{name:"数据",rows:office.text(await workspace.read(input.source)).split("\\n").map(line=>line.split(",")).concat([[true,2,{formula:"SUM(B3:B3)"}]])},{name:"其他",rows:[[0]]}])';
  const sheet = await write('data.xlsx', workbook, { source: 'input.csv' });
  assert.deepEqual(success(sheet).result, { path: 'data.xlsx', bytes: files.get('data.xlsx').length, written: true });
  assert.deepEqual(Array.from(sheet.children, ({ call: item }) => JSON.parse(item.function.arguments)), [{ path: 'input.csv' }, { path: 'data.xlsx' }]);
  assert.equal(JSON.stringify(collectFileOperations(toolReceipts([sheet]))), '{"readFiles":["input.csv"],"modifiedFiles":["data.xlsx"]}');
  const officeDoc = 'office.docx([{heading:"报告",level:2},{text:"收入 & 支出"},{table:[["项目","值"],["示例","2"]]}])';
  const deck = 'office.pptx([{title:"第一张",body:["一","二"]},{title:"第二张",body:["报告 & 原始数据"]}])';
  success(await write('report.docx', officeDoc));
  success(await write('deck.pptx', deck));

  success(await write('data-edited.xlsx', 'office.editXlsx(await workspace.read(input.source),[{sheet:"数据",cell:"b2",value:19},{sheet:"数据",cell:"AA5",value:"完成"}])', { source: 'data.xlsx' }));
  success(await write('report-edited.docx', 'office.editDocx(await workspace.read(input.source),[{find:"收入 & 支出",replace:"净收入"}])', { source: 'report.docx' }));
  success(await write('deck-edited.pptx', 'office.editPptx(await workspace.read(input.source),[{slide:2,find:"报告 & 原始数据",replace:"修订版"}])', { source: 'deck.pptx' }));
  const get = (file, part) => parts(files.get(file)).get(part);
  assert.match(get('data.xlsx', 'xl/worksheets/sheet1.xml'), /<c r="B2" t="inlineStr">.*12.*<f>SUM\(B3:B3\)<\/f>/);
  assert.match(get('data-edited.xlsx', 'xl/worksheets/sheet1.xml'), /<c r="B2" t="n"><v>19<\/v>.*<c r="AA5" t="inlineStr">/);
  assert.equal(get('data.xlsx', 'xl/worksheets/sheet2.xml'), get('data-edited.xlsx', 'xl/worksheets/sheet2.xml'));
  assert.match(get('report.docx', 'word/document.xml'), /收入 &amp; 支出/);
  assert.match(get('report-edited.docx', 'word/document.xml'), /Heading2.*净收入.*<w:tbl>/);
  assert.equal(get('report.docx', 'word/styles.xml'), get('report-edited.docx', 'word/styles.xml'));
  assert.match(get('deck.pptx', 'ppt/slides/slide2.xml'), /报告 &amp; 原始数据/);
  assert.match(get('deck-edited.pptx', 'ppt/slides/slide2.xml'), /修订版/);
  assert.equal(get('deck.pptx', 'ppt/slides/slide1.xml'), get('deck-edited.pptx', 'ppt/slides/slide1.xml'));

  files.set('dot.png', Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jZioAAAAASUVORK5CYII=', 'base64'));
  success(await write('styled.pptx', `office.pptx({
    theme:{name:"Coastal",fontFace:"Arial",background:"112233",text:"F8F2E4",accent:"50C8AD"},
    slides:[{elements:[
      {id:"badge",type:"shape",shape:"star5",x:1,y:1,w:2,h:2,fill:"accent",rotate:15},
      {id:"heading",type:"text",text:"Quarterly review",x:3,y:1,w:5,h:1,fontSize:36,bold:true},
      {id:"illustration",type:"image",x:8,y:1,w:3,h:3,alt:"Company illustration",data:await workspace.read("dot.png")}
    ]},{elements:[]}]})`));
  const originalSlide = get('styled.pptx', 'ppt/slides/slide1.xml');
  const theme = get('styled.pptx', 'ppt/theme/theme1.xml');
  assert.match(theme, /<a:accent1><a:srgbClr val="50C8AD"/);
  assert.match(originalSlide, /name="badge".*prst="star5".*val="accent1"/);
  assert.match(originalSlide, /<p:pic>.*name="illustration".*r:embed="rIdTinybotImage1"/);
  assert.match(get('styled.pptx', 'ppt/slides/_rels/slide1.xml.rels'), /\.\.\/media\/slide1-4-1\.png/);
  const inspected = success(await run('return office.inspectPptx(await workspace.read("styled.pptx"),1);', {})).result;
  assert.deepEqual(inspected.elements.map(item => item.id), ['badge', 'heading', 'illustration']);
  assert.equal(inspected.elements[0].rotate, 15);
  success(await write('styled-edited.pptx', `office.editPptx(await workspace.read("styled.pptx"),[
    {slide:1,element:"badge",changes:{x:2,shape:"diamond",fill:"accent2"}},
    {slide:1,element:"heading",changes:{text:"Updated & ready",color:"text"}},
    {slide:1,element:"illustration",changes:{x:9,data:await workspace.read("dot.png")}}
  ],{theme:{accent2:"DA784F"}})`));
  const revised = get('styled-edited.pptx', 'ppt/slides/slide1.xml');
  assert.match(revised, /name="badge".*x="1828800".*prst="diamond".*val="accent2"/);
  assert.match(revised, /Updated &amp; ready/);
  assert.match(revised, /name="illustration".*r:embed="rIdTinybotImage2"/);
  assert.match(get('styled-edited.pptx', 'ppt/theme/theme1.xml'), /<a:accent2><a:srgbClr val="DA784F"/);
  assert.equal(get('styled-edited.pptx', 'ppt/slides/slide2.xml'), get('styled.pptx', 'ppt/slides/slide2.xml'));
  assert.equal(get('styled.pptx', 'ppt/slides/slide1.xml'), originalSlide);
  failure(await write('missing-object.pptx', 'office.editPptx(await workspace.read("styled.pptx"),[{slide:1,element:"missing",changes:{x:2}}])'), /Expected one slide element/);
  console.log('PASS editable PPT theme, vector shape, image relationships, element inspection and targeted copy edits');
  success(await write('charts.pptx', `office.pptx({theme:{accent:"219875",accent2:"C16A59"},slides:[{elements:[
    {id:"revenue",type:"chart",chart:"bar",x:1,y:1,w:5,h:3,title:"Revenue",categories:["Q1","Q2"],
      series:[{name:"East",values:[8,13]},{name:"West",values:[-3,10]}]},
    {id:"trend",type:"chart",chart:"line",x:6,y:1,w:5,h:3,categories:["Q1","Q2"],series:[{name:"Sales",values:[5,9]}]},
    {id:"mix",type:"chart",chart:"doughnut",x:3,y:4,w:5,h:3,categories:["East","West"],series:[{name:"Mix",values:[5,8]}]}
  ]}]})`));
  const chartParts = parts(files.get('charts.pptx'));
  const slideChart = (number) => 'ppt/charts/tinybot-slide1-' + number + '.xml';
  assert.match(chartParts.get('ppt/slides/slide1.xml'), /<p:graphicFrame>.*name="revenue".*<c:chart/s);
  assert.match(chartParts.get(slideChart(2)), /<c:barChart>.*Sheet1!\$C\$2:\$C\$3/s);
  assert.match(chartParts.get(slideChart(3)), /<c:lineChart>/);
  assert.match(chartParts.get(slideChart(4)), /<c:doughnutChart>.*<c:dPt>/s);
  const workbookBytes = parts(files.get('charts.pptx'), true).get('ppt/embeddings/tinybot-slide1-2.xlsx');
  assert.match(parts(workbookBytes).get('xl/worksheets/sheet1.xml'), /<c r="C2" t="n"><v>-3<\/v>/);
  const charts = success(await run('return office.inspectPptx(await workspace.read("charts.pptx"),1);', {})).result.elements;
  assert.deepEqual(charts.map((item) => [item.id, item.chart]), [['revenue','bar'],['trend','line'],['mix','doughnut']]);
  assert.deepEqual(charts[0].series[1].values, [-3,10]);
  success(await write('chart-revised.pptx', `office.editPptx(await workspace.read("charts.pptx"),[
    {slide:1,element:"revenue",changes:{x:2,title:"Revised",colors:["4472C4"],
      series:[{name:"East",values:[10,15]}]}}])`));
  assert.match(get('chart-revised.pptx', slideChart(2)), /Revised.*4472C4/s);
  assert.equal(get('chart-revised.pptx', slideChart(3)), chartParts.get(slideChart(3)));
  const updatedCharts = success(await run('return office.inspectPptx(await workspace.read("chart-revised.pptx"),1);', {})).result.elements;
  assert.equal(updatedCharts[0].x, 2);
  assert.deepEqual(updatedCharts[0].series[0].values, [10,15]);
  console.log('PASS native PowerPoint charts, embedded data workbook, inspection and targeted chart revision');

  failure(await write('report.docx', officeDoc), /Output exists/);
  failure(await write('../bad.docx', officeDoc), /路径|path/);
  failure(await write('wrong.xlsx', officeDoc), /does not match/);
  failure(await write('missing.docx', 'office.editDocx(await workspace.read("report.docx"),[{find:"不存在",replace:"A"}])'), /did not match/);
  failure(await write('bad.docx', 'new Uint8Array([80,75,3,4])'), /Office ZIP/);
  failure(await write('denied.docx', officeDoc, {}, readOnly), /PERMISSION_DENIED/);
  failure(await write('denied.txt', '"new text"', {}, readOnly), /PERMISSION_DENIED/);
  failure(await write('research.docx', officeDoc, {}, research), /PERMISSION_DENIED/);
  success(await run('const old = await workspace.readText(input.path); return await workspace.write(input.path, old + " edited");',
    { path: 'notes.txt' }, research));
  assert.equal(files.get('notes.txt').toString(), 'Original text edited');
  const nested = await dispatch(call('orchestrate', { code: 'return await tools.execute_code({code:' +
    JSON.stringify('return await workspace.write("nested.txt", "nested");') + '});' }), full);
  success(nested);
  assert.equal(nested.children[0].children[0].status, 'complete');
  const deniedNested = await dispatch(call('orchestrate', { code: 'return await tools.execute_code({code:' +
    JSON.stringify('return await workspace.write("nested-denied.txt", "nested");') + '});' }), new OrchestrationTools(readOnly, executor));
  failure(deniedNested, /PERMISSION_DENIED/);
  assert.ok(!files.has('nested-denied.txt'));

  const partial = await run('await workspace.write("committed.txt", "kept"); throw Error("after write");');
  failure(partial, /after write/);
  assert.equal(files.get('committed.txt').toString(), 'kept');
  assert.equal(partial.children[0].status, 'complete');
  let checkpointed = false;
  await assert.rejects(dispatch(call('execute_code', { code: 'try { await workspace.write("blocked.txt", "a"); } catch {}' }), codeTool,
    async () => { if (checkpointed) throw Error('checkpoint failed'); checkpointed = true; }), /checkpoint failed/);
  assert.ok(!files.has('blocked.txt'));

  const limit = 20 * 1024 * 1024;
  const entries = new Map(Array.from(parts(files.get('report.docx')), ([name, text]) => [name, Buffer.from(text)]));
  const types = entries.get('[Content_Types].xml').toString('utf8');
  entries.set('[Content_Types].xml', Buffer.from(types.replace('</Types>',
    '<Default Extension="bin" ContentType="application/octet-stream"/></Types>')));
  entries.set('word/attachment.bin', Buffer.alloc(0));
  entries.set('word/attachment.bin', Buffer.alloc(limit - storedZip(entries).length, 0xab));
  const boundary = storedZip(entries);
  assert.equal(boundary.length, limit);
  files.set('boundary.docx', boundary);
  const large = await write('boundary-copy.docx', 'await workspace.read("boundary.docx")');
  assert.equal(success(large).result.bytes, limit);
  assert.deepEqual(files.get('boundary-copy.docx'), boundary);
  assert.ok(JSON.stringify(large).length < 2000, 'Receipts must not retain file bytes');
  failure(await run('await workspace.read("boundary.docx"); await workspace.read("input.csv");'), /exceeds limit/);
  failure(await write('too-large.docx', 'new Uint8Array(' + (limit + 1) + ')'), /output exceeds 20 MiB/);
  for (const path of ['wrong.xlsx', 'missing.docx', 'bad.docx', 'denied.docx', 'denied.txt', 'research.docx', 'too-large.docx']) assert.ok(!files.has(path));

  const delivery = new PresentTools(async (name) => { assert.ok(files.has(name)); return name; });
  const presented = await delivery.execute(call('present_files', { files: [{ path: 'deck-edited.pptx' }] }), new Cancellation());
  assert.deepEqual(JSON.parse(presented).files, [{ path: 'deck-edited.pptx' }]);
  console.log('PASS unified code, Office generation and copy edits, 20 MiB boundary, policy, durable receipts and delivery');
}

main().catch((error) => { console.error(error); process.exitCode = 1; });
