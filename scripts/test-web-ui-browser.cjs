// Browser integration for the exact isolated host shipped in ArkWeb. Requires Playwright and DevEco TypeScript.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const {chromium}=require('playwright');
const studio=process.env.DEVECO_STUDIO_HOME||path.join(process.env.ProgramFiles,'Huawei/DevEco Studio');
const ts=require(studio+'/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
function model(name,directory='entry/src/main/ets/model'){const file=path.resolve(directory,name+'.ets'),exports={};vm.runInNewContext(ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText,{exports,require:id=>model(id,path.dirname(file))});return exports;}
const exportsObject=model('WebUi');
const {webUiHost,parseWebUi,parseWebUiMessage,webUiAutoHeight}=exportsObject;
const assets='entry/src/main/resources/rawfile/interactive-web/';
const fixtures=path.join(__dirname,'fixtures/interactive-web/');
const example=JSON.parse(fs.readFileSync(path.join(fixtures,'example.json'),'utf8')).content.split('\n');
const begin=JSON.parse(example[1]);const spec=parseWebUi(JSON.parse(example[2]).node.data);
const html=webUiHost(fs.readFileSync(assets+'host.js','utf8'),fs.readFileSync(assets+'three.bundle.js','utf8'));
assert.throws(()=>parseWebUi(JSON.stringify({...spec,library:'cdn'})));assert.throws(()=>parseWebUiMessage('{"type":"submit"}'));assert.throws(()=>parseWebUiMessage('{"type":"save","id":0,"values":{}}'));
assert.throws(()=>parseWebUi(JSON.stringify({...spec,autoHeight:'yes'})));
assert.throws(()=>parseWebUiMessage('{"type":"resize","height":-1}'));
assert.throws(()=>parseWebUiMessage('{"type":"resize","height":"200"}'));
(async()=>{
 const browser=await chromium.launch({channel:'msedge',headless:true,args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']});
 try{
  const page=await browser.newPage({viewport:{width:400,height:600}});const errors=[];page.on('pageerror',e=>errors.push(e.message));
  const consoleErrors=[];page.on('console',message=>{if(message.type()==='error')consoleErrors.push(message.text());});
  const requests=[];await page.route('**/*',route=>{requests.push(route.request().url());route.abort();});
  async function mount(values,specOverride=spec,expectedError='',preflight=false,snapshotMode=false){
   // setContent retains the previous window and message listeners; a remount needs a fresh host.
   await page.goto('about:blank');
   await page.setContent(html);
   await page.evaluate(({spec,values,preflight,autoHeight,snapshotMode})=>{
    window.messages=[];window.saved=values;window.failSave=false;
    const channel=new MessageChannel();window.nativePort=channel.port1;
    channel.port1.onmessage=event=>{const data=JSON.parse(event.data);window.messages.push(data);if(data.type==='resize'&&autoHeight){
      document.documentElement.style.height=Math.max(48,Math.min(800,data.height))+'px';
    }if(data.type==='save'){
      if(window.failSave)channel.port1.postMessage(JSON.stringify({type:'ack',id:data.id,error:'Disk write failed'}));
      else {window.saved=data.values;channel.port1.postMessage(JSON.stringify({type:'ack',id:data.id,values:data.values}));}
    }};
    window.postMessage('tinybot-web-port','*',[channel.port2]);
    channel.port1.postMessage(JSON.stringify({type:'init',spec,values,active:true,preflight,autoHeight,snapshotMode}));
   },{spec:specOverride,values,preflight,autoHeight:webUiAutoHeight(specOverride),snapshotMode});
   try { await page.waitForFunction(()=>window.messages.some(m=>m.type==='ready'||m.type==='error')); }
   catch(error){console.error({errors,consoleErrors,frames:page.frames().map(f=>f.url()),host:await page.evaluate(()=>({ready:window.__tinybotHostReady,messages:window.messages}))});throw error;}
   const messages=await page.evaluate(()=>window.messages);
   if(expectedError){
    assert.ok(messages.some(m=>m.type==='error'&&m.message.includes(expectedError)),JSON.stringify(messages));
    await page.waitForTimeout(350);
    assert.equal(await page.evaluate(()=>messages.some(m=>m.type==='ready')),false,'failed startup cannot publish a late ready');
   }else assert.equal(messages.find(m=>m.type==='error'),undefined,JSON.stringify(messages));
   return page.frames().find(f=>f.parentFrame());
  }
  const {PreviewTools}=model('../services/PreviewTools'),{Cancellation}=model('../services/Cancellation');
  const {parseUiSurface}=model('InteractiveUi');
  const previewSource='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><text x="5" y="30">Pelican</text></svg>';
  const previewCall={id:'browser-preview',type:'function',function:{name:'publish_preview',arguments:JSON.stringify({path:'pelican.svg'})}};
  const receipt={call:previewCall,status:'running',output:''};
  const publisher=new PreviewTools({read:async()=>({content:previewSource})},async content=>{
    const data=JSON.parse(parseUiSurface(content,'0').nodes[0].data);
    await mount({},data,'',true);
  });
  await publisher.execute(previewCall,new Cancellation(),{execution:receipt});
  const preview=JSON.parse(parseUiSurface(receipt.previewContent,'0').nodes[0].data);
  let frame=await mount({},preview);
  assert.equal(await frame.locator('svg text').textContent(),'Pelican');
  assert.equal(await frame.locator('svg').getAttribute('viewBox'),'0 0 100 100');
  assert.equal(preview.html,previewSource);
  console.log('PASS file publication runs real browser preflight and renders the exact SVG snapshot with empty state');
  const landscape={...preview,html:previewSource.replace('0 0 100 100','0 0 100 50')};
  frame=await mount({},landscape);
  await page.waitForFunction(()=>document.querySelector('iframe').clientHeight===200);
  assert.equal((await frame.locator('svg').boundingBox()).height,200);
  await page.setViewportSize({width:280,height:600});
  await page.waitForFunction(()=>document.querySelector('iframe').clientHeight===140);
  await frame.locator('svg').evaluate(svg=>svg.setAttribute('viewBox','0 0 100 20'));
  await page.waitForFunction(()=>document.querySelector('iframe').clientHeight===56);
  await page.waitForTimeout(100);
  assert.ok((await page.evaluate(()=>messages.filter(m=>m.type==='resize').length))<10,'height feedback must settle');
  assert.equal(await page.evaluate(()=>messages.some(m=>m.type==='save')),false);
  await page.setViewportSize({width:400,height:600});
  const legacy={...landscape};delete legacy.autoHeight;
  frame=await mount({},legacy);
  await page.waitForFunction(()=>document.querySelector('iframe').clientHeight===200);
  console.log('PASS new and saved file previews shrink to content and update on width/content changes without saves or resize loops');
  frame=await mount({},{...preview,html:'<div style="height:24px">Small preview</div>'});
  await page.waitForFunction(()=>document.querySelector('iframe').clientHeight===48);
  frame=await mount({},{...preview,html:'<div style="height:1200px">Tall preview</div>'});
  await page.waitForFunction(()=>document.querySelector('iframe').clientHeight===800);
  assert.equal(await frame.evaluate(()=>document.body.scrollHeight),1200);
  frame=await mount({},{...preview,html:'<h1>Title</h1><p>Text with margins</p>'});
  await page.waitForFunction(()=>document.querySelector('iframe').clientHeight<200);
  const textBounds=await frame.locator('p').boundingBox();
  assert.ok(textBounds.y+textBounds.height<=await page.locator('iframe').evaluate(el=>el.clientHeight),
    JSON.stringify({textBounds,measure:await frame.evaluate(()=>({body:document.body.getBoundingClientRect().toJSON(),scroll:document.body.scrollHeight,margin:getComputedStyle(document.body).margin})),messages:await page.evaluate(()=>messages)}));
  console.log('PASS compact and tall HTML previews respect height bounds and preserve text margins');
  frame=await mount({},preview,'',true,true);
  assert.equal(await page.evaluate(()=>messages.some(m=>m.type==='snapshotReady')),false);
  await page.evaluate(()=>nativePort.postMessage(JSON.stringify({type:'snapshot'})));
  await page.waitForFunction(()=>messages.some(m=>m.type==='snapshotReady'));
  assert.equal(await page.evaluate(()=>messages.some(m=>m.type==='save')),false);
  console.log('PASS snapshot requests cross the sandbox and report painted-frame readiness without saving state');
  frame=await mount(begin.state);
  assert.equal(await page.evaluate(()=>messages.some(m=>m.type==='resize')),false,'explicit scene height is retained');
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
  const example2d=JSON.parse(fs.readFileSync(path.join(fixtures,'example-2d.json'),'utf8')).content.split('\n');
  const initial2d=JSON.parse(example2d[1]).state, spec2d=parseWebUi(JSON.parse(example2d[2]).node.data);
  frame=await mount(initial2d,spec2d);await frame.locator('#add').click();
  await page.waitForFunction(()=>window.saved.count===1);
  assert.equal(await frame.locator('#count').textContent(),'当前计数：1');
  await page.evaluate(values=>nativePort.postMessage(JSON.stringify({type:'state',values,active:true})),initial2d);
  await frame.waitForFunction(()=>document.getElementById('count').textContent==='当前计数：0');
  console.log('PASS Canvas demo commits DOM edits and applies native reset through the same bridge');
  await mount(begin.state,spec,'',true);
  console.log('PASS actual Three.js scene passes startup preflight');
  const bad={version:1,html:'',css:'',js:'new THREE.OrbitControls();',library:'three',height:360};
  await mount({},bad,'new OrbitControls(camera, renderer.domElement)',true);
  assert.ok(await page.evaluate(()=>messages.some(m=>m.message?.includes('tinybot-generated.js'))),'diagnostic includes source stack');
  await mount({},{...bad,library:'none',js:'const = broken'},'SyntaxError',true);
  await mount({},{...bad,library:'none',js:'Promise.reject(new Error("async startup failed"));'},'async startup failed',true);
  await mount({},{...bad,library:'none',js:'tinybot.animate(()=>{throw new Error("first frame failed")})'},'first frame failed',true);
  await mount({},{...bad,library:'none',js:'console.error("renderer failed")'},'renderer failed',true);
  await mount({},{...bad,library:'none',js:'await tinybot.save({});'},'Save state only on user interaction',true);
  await mount({},{...bad,library:'none',js:'document.body.textContent="fixed";'},'',true);
  console.log('PASS constructor, syntax, rejection, animation and console failures reach the bridge; failed probes cannot save or become ready; next probe recovers');
 }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
