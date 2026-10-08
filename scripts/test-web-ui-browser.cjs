// Browser integration for the exact isolated host shipped in ArkWeb. Requires Playwright and DevEco TypeScript.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const {chromium}=require('playwright');
const studio=process.env.DEVECO_STUDIO_HOME||path.join(process.env.ProgramFiles,'Huawei/DevEco Studio');
const ts=require(studio+'/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const exportsObject={};vm.runInNewContext(ts.transpileModule(fs.readFileSync('entry/src/main/ets/model/WebUi.ets','utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText,{exports:exportsObject});
const {webUiHost,parseWebUi,parseWebUiMessage}=exportsObject;
const assets='entry/src/main/resources/rawfile/interactive-web/';
const example=JSON.parse(fs.readFileSync(assets+'example.json','utf8')).content.split('\n');
const begin=JSON.parse(example[1]);const spec=parseWebUi(JSON.parse(example[2]).node.data);
const html=webUiHost(fs.readFileSync(assets+'host.js','utf8'),fs.readFileSync(assets+'three.bundle.js','utf8'));
assert.throws(()=>parseWebUi(JSON.stringify({...spec,library:'cdn'})));assert.throws(()=>parseWebUiMessage('{"type":"submit"}'));assert.throws(()=>parseWebUiMessage('{"type":"save","id":0,"values":{}}'));
(async()=>{
 const browser=await chromium.launch({channel:'msedge',headless:true,args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']});
 try{
  const page=await browser.newPage({viewport:{width:400,height:600}});const errors=[];page.on('pageerror',e=>errors.push(e.message));
  const requests=[];await page.route('**/*',route=>{requests.push(route.request().url());route.abort();});
  async function mount(values,specOverride=spec){
   await page.setContent(html);
   await page.evaluate(({spec,values})=>{
    window.messages=[];window.saved=values;window.failSave=false;
    const channel=new MessageChannel();window.nativePort=channel.port1;
    channel.port1.onmessage=event=>{const data=JSON.parse(event.data);window.messages.push(data);if(data.type==='save'){
      if(window.failSave)channel.port1.postMessage(JSON.stringify({type:'ack',id:data.id,error:'Disk write failed'}));
      else {window.saved=data.values;channel.port1.postMessage(JSON.stringify({type:'ack',id:data.id,values:data.values}));}
    }};
    window.postMessage('tinybot-web-port','*',[channel.port2]);
    channel.port1.postMessage(JSON.stringify({type:'init',spec,values,active:true}));
   },{spec:specOverride,values});
   await page.waitForFunction(()=>window.messages.some(m=>m.type==='ready'||m.type==='error'));
   const messages=await page.evaluate(()=>window.messages);assert.equal(messages.find(m=>m.type==='error'),undefined,JSON.stringify(messages));
   return page.frames().find(f=>f.parentFrame());
  }
  let frame=await mount(begin.state);
  assert.equal(await frame.evaluate(()=>THREE.REVISION),'186');
  assert.equal(await frame.locator('canvas').count(),1);
  assert.equal(await frame.evaluate(()=>{try{parent.document.body;return false}catch{return true}}),true);
  console.log('PASS Three.js initializes inside an opaque sandbox with a real WebGL2 canvas');
  await frame.locator('#speed').evaluate(input=>{input.value='1.2';input.dispatchEvent(new Event('change'));});
  await page.waitForFunction(()=>window.saved.speed===1.2);
  assert.equal(await frame.evaluate(()=>tinybot.state.speed),1.2);
  await frame.locator('#stage').screenshot({path:'.hvigor/web-ui-three.png'});
  console.log('PASS DOM controls commit state through the message port and receive acknowledgements');
  const saved=await page.evaluate(()=>window.saved);frame=await mount(saved);
  assert.equal(await frame.locator('#speed').inputValue(),'1.2');
  await page.evaluate(()=>{nativePort.postMessage(JSON.stringify({type:'state',values:{...saved,speed:0},active:false}));});
  await frame.waitForFunction(()=>tinybot.active===false);
  await assert.rejects(frame.evaluate(()=>tinybot.save(tinybot.state)),/read-only/);
  let counts=await frame.evaluate(()=>{window.framesRun=0;tinybot.animate(()=>framesRun++);return framesRun;});
  await page.waitForTimeout(100);assert.equal(await frame.evaluate(()=>framesRun),counts);
  await page.evaluate(()=>nativePort.postMessage(JSON.stringify({type:'state',values:saved,active:true})));
  await frame.waitForFunction(()=>framesRun>0);
  console.log('PASS reload restores state, native updates reach controls, and hidden/read-only animation pauses');
  await page.evaluate(()=>{window.failSave=true;});
  await assert.rejects(frame.evaluate(()=>tinybot.save({...tinybot.state,speed:1.7})),/Disk write failed/);
  assert.equal(await frame.evaluate(()=>tinybot.state.speed),1.2);
  console.log('PASS failed persistence rejects the promise without committing the new state');
  await frame.evaluate(async()=>{try{await fetch('https://example.com/blocked')}catch{}});
  assert.equal(requests.length,0);
  assert.equal(await frame.evaluate(()=>{try{localStorage.setItem('x','1');return false}catch{return true}}),true);
  assert.equal(errors.length,0,errors.join('\n'));
  console.log('PASS CSP blocks outgoing fetch before any request and sandbox denies storage');
  const example2d=JSON.parse(fs.readFileSync(assets+'example-2d.json','utf8')).content.split('\n');
  const initial2d=JSON.parse(example2d[1]).state, spec2d=parseWebUi(JSON.parse(example2d[2]).node.data);
  frame=await mount(initial2d,spec2d);await frame.locator('#add').click();
  await page.waitForFunction(()=>window.saved.count===1);
  assert.equal(await frame.locator('#count').textContent(),'当前计数：1');
  await page.evaluate(values=>nativePort.postMessage(JSON.stringify({type:'state',values,active:true})),initial2d);
  await frame.waitForFunction(()=>document.getElementById('count').textContent==='当前计数：0');
  console.log('PASS Canvas demo commits DOM edits and applies native reset through the same bridge');
 }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
