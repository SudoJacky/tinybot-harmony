const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const callbacks = new Map(), errors = [], observedWrites = [], geometry = [];
const none = {left:0,top:0,width:0,height:0};
let keyboardArea = {bottomRect:none,topRect:none,leftRect:none,rightRect:none};
const host = {
  getWindowAvoidArea: type => type===1 ? {bottomRect:{height:84}} : keyboardArea,
  on: (name, callback) => { if(!callbacks.has(name))callbacks.set(name,new Set());callbacks.get(name).add(callback); },
  off: (name, callback) => callbacks.get(name).delete(callback)
};
const platform = {AvoidAreaType:{TYPE_NAVIGATION_INDICATOR:1,TYPE_KEYBOARD:2},getLastWindow:async()=>host};
const exportsObject={};
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.resolve(__dirname,'../entry/src/main/ets/viewmodel/WindowViewport.ets'),'utf8'),{
  compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021,experimentalDecorators:true}
}).outputText,{exports:exportsObject,Observed:cls=>class extends cls {
  constructor(...args) { super(...args); return new Proxy(this, {set(target,key,value,receiver) {
    observedWrites.push(key); return Reflect.set(target,key,value,receiver);
  }}); }
},require:id=>{
  if(id==='../model/Diagnostics')return { Diagnostics: { log(level, _module, event, fields) {
    if (event === 'keyboard_geometry') geometry.push({ width: fields.width, height: fields.height });
    if (level === 'error') errors.push(event);
  } } };
  if(id==='@kit.ArkUI')return {window:platform};
  throw Error('Unexpected dependency '+id);
}});
const {WindowViewport}=exportsObject,ui={px2vp:height=>height/3.5,getHostContext:()=>({})};
const emit=(name,value)=>callbacks.get(name).forEach(callback=>callback(value));
(async()=>{
  const chat=new WindowViewport(),sheet=new WindowViewport(),shown=[];chat.onKeyboard=value=>shown.push(value);
  await chat.observe(ui);await sheet.observe(ui);assert.equal(sheet.bottom,24);
  observedWrites.length=0;
  emit('keyboardHeightChange',900);assert.equal(chat.keyboardHeight,900);assert.equal(sheet.keyboardHeight,900);
  assert.equal(observedWrites.filter(key=>key==='keyboardHeight').length,2,'window callbacks must update through the observed proxy');
  emit('keyboardHeightChange',920);assert.deepEqual(shown,[true],'keyboard animation does not repeatedly reset reading position');
  emit('keyboardHeightChange',0);assert.deepEqual(shown,[true,false]);
  emit('avoidAreaChange',{type:1,area:{bottomRect:{height:105}}});assert.equal(sheet.bottom,30);
  console.log('PASS keyboard visibility transitions and navigation inset changes');
  keyboardArea={bottomRect:{left:1400,top:700,width:700,height:600},topRect:none,leftRect:none,rightRect:none};
  emit('avoidAreaChange',{type:2,area:keyboardArea});
  assert.deepEqual(geometry.at(-1), { width: 200, height: 600 / 3.5 });
  assert.equal(chat.keyboardHeight, 0, 'An early avoid-area event only records geometry');
  assert.deepEqual(shown, [true, false]);
  keyboardArea={bottomRect:none,topRect:none,leftRect:none,rightRect:none};
  emit('avoidAreaChange',{type:2,area:keyboardArea});
  assert.deepEqual(geometry.at(-1), { width: 0, height: 0 });
  const adaptive={};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.resolve(__dirname,'../entry/src/main/ets/model/AdaptiveUi.ets'),'utf8'),{
    compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}
  }).outputText,{exports:adaptive});
  const {AdaptiveUi}=adaptive;
  assert.equal(AdaptiveUi.compactComposer(440),true);assert.equal(AdaptiveUi.compactComposer(520),false);
  console.log('PASS keyboard geometry diagnostics and visibility are independent');
  sheet.dispose();assert.equal(callbacks.get('keyboardHeightChange').size,1);emit('keyboardHeightChange',1000);assert.equal(chat.keyboardHeight,1000);assert.equal(sheet.keyboardHeight,0);
  chat.dispose();assert.equal(callbacks.get('avoidAreaChange').size,0);
  console.log('PASS disposing a sheet removes only its listeners and preserves chat observation');
  let resolve;platform.getLastWindow=()=>new Promise(done=>{resolve=done;});const abandoned=new WindowViewport();const starting=abandoned.observe(ui);abandoned.dispose();resolve(host);await starting;
  assert.equal(callbacks.get('keyboardHeightChange').size,0);assert.equal(errors.length,0);
  console.log('PASS closing before the window resolves does not leak listeners');
})().catch(error=>{console.error(error);process.exitCode=1;});
