// Receipt projections and lossless paging; no platform services or tool execution.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets');
const cache = new Map();
function load(file) {
  file = path.resolve(file.endsWith('.ets') ? file : file + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true
  } }).outputText, { exports, Observed: cls => cls, require: id => {
    if (id.endsWith('/I18n')) return { t: (key, values = []) => key.replace(/\{(\d+)\}/g, (_, n) => values[n]) };
    if (!id.startsWith('.')) throw Error('Unexpected native dependency: ' + id);
    return load(path.resolve(path.dirname(file), id));
  } }, { filename: file });
  return exports;
}
const { toolDetailContent: project, detailPages } = load(path.join(root, 'model/ToolDetailContent'));
const render = (name, args, result, status = 'complete') => project(name, JSON.stringify(args), JSON.stringify(result), status);
const flat = content => JSON.stringify(content);
let failures = 0;
function test(name, body) { try { body(); console.log('PASS ' + name); } catch (error) { failures++; console.error('FAIL ' + name, error); } }
test('file receipts use saved names, actual offsets and explicit tool truncation', () => {
  const result = render('read_attachment', {id:'id',offset:4,column:3}, {name:'日志.txt',content:'你好\nnext',startLine:4,totalLines:99,truncated:true,nextOffset:6,nextColumn:1});
  assert.equal(result.path,'日志.txt'); assert.equal(result.sections[0].body,'4:3  你好\n5  next');
  assert.match(result.summary,/99/); assert.equal(result.notices.length,2);
  assert.equal(render('read_file', {path:'x'}, {content:'x'.repeat(30000)}).notices.length,0,'UI paging is not tool truncation');
});
test('failed and pending edits never claim a successful replacement', () => {
  for (const status of ['failed','pending','running','cancelled','interrupted']) {
    const content=render('edit_file',{path:'file',oldText:'old',newText:'new'},{error:'missing baseline'},status);
    assert.ok(content.sections.every(section=>!['added','removed'].includes(section.style)));
    assert.ok(flat(content).includes('missing baseline'));
  }
  const done=render('edit_file',{path:'file',oldText:'old',newText:'new'},{changed:true});
  assert.deepEqual(Array.from(done.sections,section=>section.style),['removed','added']);
});
test('search groups duplicate paths while preserving matches and skipped files', () => {
  const result=render('search_file_content',{}, {matches:[{path:'a',line:1,text:'one'},{path:'b',line:3,text:'two'},{path:'a',line:5,text:'three'}],skipped:['binary'],truncated:true});
  assert.equal(result.sections.length,2); assert.equal(result.sections[0].rows.length,2);
  assert.equal(result.sections[0].rows[1].value,'three'); assert.ok(flat(result.notices).includes('binary'));
  assert.ok(flat(render('search_file_content',{}, {matches:[]})).includes('没有匹配项'));
});
test('directories and plans retain empty and status distinctions', () => {
  const listing=render('list_files',{}, {entries:[{name:'src',kind:'directory'},{name:'a.txt',kind:'file'},{name:'link',kind:'symlink'}]});
  assert.deepEqual(Array.from(listing.sections[0].rows,row=>row.value),['文件夹','文件','符号链接']);
  assert.match(flat(render('list_files',{}, {entries:[]})),/空目录/);
  const plan=render('update_plan',{}, {steps:[{step:'A',status:'completed'},{step:'B',status:'in_progress'},{step:'C',status:'pending'}]});
  assert.equal(new Set(plan.sections[0].rows.map(row=>row.label)).size,3);
});
test('execution separates return values, logs, code and independent failure counts', () => {
  const args={code:'return input',input:'{"a":1}'};
  for(const value of [0,false,null,'']) {
    const result=render('execute_code',args,{result:value,stdout:'a\nb',stderr:'warning',durationMs:12,error:''});
    assert.equal(result.sections[0].body,typeof value==='string'?value:JSON.stringify(value));
    assert.ok(result.sections.every(section=>section.style!=='error'),'empty error fields are not failures');
    assert.equal(result.logs[0].body,'a\nb');assert.equal(result.logs[1].body,'warning');assert.equal(result.inputs[0].body,args.code);
  }
  const failed=render('orchestrate',args,{error:'Timed out',stdout:'partial',calls:[{tool:'read_file',status:'failed'}],logsTruncated:true},'failed');
  assert.equal(failed.sections[0].style,'error');assert.equal(failed.logs[0].body,'partial');assert.match(failed.summary,/1 次失败/);assert.equal(failed.notices.length,1);
});
test('web receipts preserve title, source and links as text', () => {
  const result=render('read_web',{url:'https://example.com'}, {title:'Title',url:'https://example.com/page',content:'Body',links:[{title:'Source',url:'https://example.com/source'}],linksTruncated:true});
  assert.equal(result.path,'https://example.com/page');assert.equal(result.sections[0].body,'Body');assert.equal(result.sections[1].rows[0].label,'Source');
});
test('submitted forms use question labels and preserve falsy/empty answers', () => {
  const result=render('request_user_input',{data:JSON.stringify({title:'Questions',fields:[{name:'answer',label:'Your choice'}]})},{status:'submitted',values:{answer:'',count:'0'}});
  assert.equal(result.sections[0].rows[0].label,'Your choice');assert.equal(result.sections[0].rows[0].value,'');assert.equal(result.sections[0].rows[1].value,'0');
});
test('MCP text and structured content are separate from binary payloads', () => {
  const result=render('mcp_call',{}, {content:[{type:'text',text:'hello\nworld'},{type:'image',mimeType:'image/png',data:'BASE64_SECRET'}],structuredContent:{count:0}});
  assert.equal(result.sections[0].body,'hello\nworld');assert.ok(!flat(result.sections).includes('BASE64_SECRET'));assert.ok(flat(result.sections).includes('count'));
});
test('unknown, primitive, malformed and historical results remain inspectable', () => {
  for(const value of [false,0,null,[],{},'text']) assert.ok(render('future_tool',{},value).sections.length);
  for(const name of ['search_file_content','list_files','update_plan','read_file']) {
    for(const value of [null,{matches:[null,4]},{entries:[null]},{steps:[{}]},{content:42}]) assert.doesNotThrow(()=>render(name,{},value));
  }
  const historical=project('future_tool','{partial','plain legacy output','complete');
  assert.equal(historical.sections[0].body,'plain legacy output');assert.equal(historical.inputs[0].body,'{partial');
});
test('generated images only preview validated local attachments', () => {
  const attachment={id:'image-1',name:'Image.jpg',path:'image-1.jpg',mime:'image/jpeg',size:20};
  assert.equal(render('generate_image',{}, {attachment}).image.path,'image-1.jpg');
  for(const path of ['../outside.jpg','https://example.com/image.jpg','/data/image.jpg']) {
    const result=render('generate_image',{}, {attachment:{...attachment,path}});
    assert.equal(result.image,undefined);assert.ok(flat(result.sections).includes(path));
  }
  assert.equal(render('generate_image',{}, {attachment},'failed').image,undefined);
});
test('paged unicode and large row values are lossless with bounded pages', () => {
  const body='x'.repeat(7999)+'😀'+ '文\n'.repeat(15000);
  const pages=detailPages([{title:'body',body,style:'code',rows:[]}]);
  assert.equal(pages.map(page=>page.body).join(''),body);
  for(const page of pages){assert.ok(page.body.length<=8000);assert.ok(!/[\uD800-\uDBFF]$/.test(page.body));}
  const rows=Array.from({length:80},(_,i)=>({label:String(i),value:i===4?body:'value '+i}));
  const rowPages=detailPages([{title:'rows',body:'',style:'list',rows}]);
  assert.ok(rowPages.every(page=>page.rows.length<=30));
  const restored=new Map();for(const page of rowPages)for(const row of page.rows)restored.set(row.label,(restored.get(row.label)||'')+row.value);
  for(const row of rows)assert.equal(restored.get(row.label),row.value);
});
if(failures)process.exitCode=1;
