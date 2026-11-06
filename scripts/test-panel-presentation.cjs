const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets/model'), cache = new Map();
function load(name) {
  if (cache.has(name)) return cache.get(name);
  const exports = {}; cache.set(name, exports);
  const code = ts.transpileModule(fs.readFileSync(path.join(root, name + '.ets'), 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 } }).outputText;
  vm.runInNewContext(code, { exports, Date, require: id => load(path.basename(id)) }); return exports;
}
const { panelMasonry, panelRunLabel, panelErrorText } = load('PanelPresentation');
const { setLocale } = load('I18n');
const { validateMailAccount } = load('Mail');
const account = { id:'test',name:'Work',host:'imap.example.com',port:993,username:'me@example.com',enabled:false,allowBody:false };
validateMailAccount(account);
for (const [field,value,expected] of [['name','',/连接名称/],['host','https://invalid',/IMAP/],['port',0,/端口/],['username','',/登录账号/]]) {
  assert.throws(() => validateMailAccount({...account,[field]:value}),expected,field+' must have a specific error');
}
setLocale('en');assert.throws(() => validateMailAccount({...account,name:''}),/connection name/);setLocale('zh-CN');
assert.throws(() => validateMailAccount({...account,name:12}),/连接名称/);
assert.throws(() => validateMailAccount({...account,username:12}),/登录账号/);
assert.match(panelErrorText('API authentication is not connected for this request. Open the card connection settings.'),/API 尚未连接/);
assert.equal(panelErrorText('User data failed'), 'User data failed', 'Never translate arbitrary source/user errors');
const run = {status:'complete',trigger:'automatic',startedAt:Date.UTC(2026,10,5,9,25,26)};
assert.ok(panelRunLabel(run).includes(new Date(run.startedAt).toLocaleString('zh-CN')));
assert.match(panelRunLabel(run),/自动触发/);
assert.match(panelRunLabel({...run,trigger:'manual'}),/手动触发/);
assert.match(panelRunLabel({...run,trigger:undefined}),/未记录/, 'Do not invent a trigger for historical runs');
const layout = panelMasonry(360,2,[1,1,2,1],[120,240,100,150]);
assert.equal(layout[0].width,174);assert.equal(layout[1].x,186);
assert.equal(layout[2].y,252);assert.equal(layout[3].y,364);
const shrunk = panelMasonry(360,2,[1,1,2,1],[120,130,100,150]);
assert.equal(shrunk[2].y,142,'Cards below must follow measured content shrinkage');
for (let i=0;i<layout.length;i++) for(let j=i+1;j<layout.length;j++) {
  const a=layout[i],b=layout[j];
  assert.ok(a.x+a.width<=b.x || b.x+b.width<=a.x || a.y+a.height<=b.y || b.y+b.height<=a.y,'Measured cards must never overlap');
}
assert.equal(panelMasonry(360,2,[2],[90])[0].height,90,'Short cards retain their measured height');
console.log('PASS localized field errors, historical API errors, locale-aware run dates/triggers, adaptive masonry packing and reflow');
