// Run with the production WebUi host and packaged definitions (see the companion source test).
async (page, host, definitions, outputDirectory) => {
  const failures=[],requests=[];
  page.on('pageerror',error=>failures.push(error.message));
  await page.route('**/*',route=>{requests.push(route.request().url());route.abort();});
  const check=(condition,message)=>{if(!condition)throw Error(message);};
  async function mount(spec,options={}){
    await page.setViewportSize({width:options.width||page.viewportSize().width,height:spec.view.height});
    await page.goto('about:blank');await page.setContent(host);
    const context={data:spec.data,inputs:Object.fromEntries(Object.entries(spec.inputs||{}).map(([key,input])=>[key,input.default])),title:spec.title,status:'ready',canRefresh:!!spec.source,locale:options.locale||'zh-CN',theme:'light',tokens:{text:'#202822','text-secondary':'#788078',surface:'#ffffff',accent:'#286b56',border:'#e4e7e2'}};
    await page.evaluate(({spec,context,options})=>{
      window.messages=[];window.stored=options.stored||{value:null,revision:'initial'};window.failSave=false;window.seq=0;
      window.probePanel=context;
      const channel=new MessageChannel();window.nativePort=channel.port1;
      channel.port1.onmessage=event=>{
        const data=JSON.parse(event.data);window.messages.push(data);
        // Model the native viewport's small CSS/vp rounding difference on height feedback.
        if(data.type==='resize'&&options.autoHeight&&!options.fixedViewport&&window.messages.filter(message=>message.type==='resize').length<24){
          document.documentElement.style.height=(data.height+2)+'px';
        }
        if(data.type==='storageLoad')channel.port1.postMessage(JSON.stringify({type:'storageResult',id:data.id,snapshot:window.stored}));
        if(data.type==='storageSave'){
          if(window.failSave||data.revision!==window.stored.revision)channel.port1.postMessage(JSON.stringify({type:'storageResult',id:data.id,error:'Test save conflict'}));
          else {window.stored={value:data.value,revision:'saved-'+ ++window.seq};channel.port1.postMessage(JSON.stringify({type:'storageResult',id:data.id,snapshot:window.stored}));}
        }
      };
      window.postMessage('tinybot-web-port','*',[channel.port2]);
      const view={...spec.view,css:spec.view.css+'\nhtml{--tinybot-card-height:'+(options.autoHeight&&!options.fixedViewport?'auto':'100vh')+'}'};
      channel.port1.postMessage(JSON.stringify({type:'init',spec:view,values:{},active:true,preflight:!!options.probe,autoHeight:!!options.autoHeight,panel:context,
        panelProbe:options.probe?{width:options.width,height:spec.view.height,checks:spec.checks}:undefined}));
    },{spec,context,options});
    await page.waitForFunction(()=>messages.some(message=>message.type==='ready'||message.type==='error'));
    const errors=await page.evaluate(()=>messages.filter(message=>message.type==='error'));
    check(!errors.length,spec.title+': '+JSON.stringify(errors));
    const tap=await page.frames().find(frame=>frame.parentFrame()).evaluate(()=>getComputedStyle(document.documentElement).webkitTapHighlightColor);
    check(tap==='rgba(0, 0, 0, 0)','Default browser tap highlight must be transparent: '+tap);
    return page.frames().find(frame=>frame.parentFrame());
  }
  for(const width of [174,344]){
    await page.setViewportSize({width,height:600});
    for(const [id,spec]of Object.entries(definitions))if(id!=='guide-welcome'||width===344)await mount(spec,{probe:true,width});
  }
  if(definitions.ascii){
    let ascii=await mount(definitions.ascii,{width:344});
    check(await ascii.locator('#mode').textContent()==='TINYBOT','ASCII starts with the Tinybot mascot');
    check(!(await ascii.locator('header').textContent()).includes('ASCII / 001'),'Remove the ASCII sequence label');
    const first=await ascii.locator('#ascii').textContent();await page.waitForTimeout(600);
    check(first!==(await ascii.locator('#ascii').textContent()),'ASCII field must animate, not display a static placeholder');
    check((await ascii.locator('#ascii').textContent()).replace(/\s/g,'').length>80,'ASCII field must contain real generated geometry');
    check(Math.abs((await ascii.locator('article').boundingBox()).height-208)<1,'Banner fills the 12x5 viewport');
    check(!(await ascii.evaluate(()=>document.documentElement.scrollWidth>innerWidth||document.documentElement.scrollHeight>innerHeight)),'ASCII banner fits without scrolling');
    await ascii.locator('article').screenshot({path:outputDirectory+'/ascii-mascot.png'});
    await ascii.locator('#warp').click();await ascii.locator('#mode').filter({hasText:'ORBITAL'}).waitFor();
    const orbital=await ascii.locator('#ascii').textContent();await page.waitForTimeout(250);
    check(orbital!==await ascii.locator('#ascii').textContent(),'Existing orbital scene still animates');
    await ascii.locator('article').screenshot({path:outputDirectory+'/ascii-orbital.png'});
    await ascii.locator('#warp').click();await ascii.locator('#mode').filter({hasText:'HYPERDRIVE'}).waitFor();
    await ascii.locator('article').screenshot({path:outputDirectory+'/ascii-hyperdrive.png'});
    await ascii.locator('#warp').click();await ascii.locator('#mode').filter({hasText:'TINYBOT'}).waitFor();
    check((await page.evaluate(()=>messages)).every(message=>!['storageLoad','storageSave','panelRefresh','panelMailRead'].includes(message.type)),'Animation runs locally without storage, source or model requests');
    await page.evaluate(()=>nativePort.postMessage(JSON.stringify({type:'state',values:{},active:false,panel:probePanel})));
    await ascii.waitForFunction(()=>!tinybot.active);await page.waitForTimeout(100);
    const paused=await ascii.locator('#ascii').textContent();await page.waitForTimeout(350);check(paused===await ascii.locator('#ascii').textContent(),'Inactive ASCII animation pauses');
    await page.emulateMedia({reducedMotion:'reduce'});ascii=await mount(definitions.ascii,{width:344});
    await page.waitForTimeout(100);const still=await ascii.locator('#ascii').textContent();await page.waitForTimeout(350);
    check(still===await ascii.locator('#ascii').textContent(),'Reduced motion shows a static ASCII scene');
    await page.emulateMedia({reducedMotion:'no-preference'});
  }
  await page.setViewportSize({width:344,height:480});
  let frame=await mount(definitions.todo);
  await frame.locator('#new-task').fill('<b>A real task</b>');await frame.locator('#add-task').click();
  await frame.waitForFunction(()=>document.querySelectorAll('.task').length===1);
  check(await frame.locator('.check span').textContent()==='<b>A real task</b>','Tasks must render as text');
  check(await frame.locator('#tasks b').count()===0,'Task HTML must not execute');
  await frame.locator('.check').click();await page.waitForFunction(()=>stored.value.items[0].done===true);
  const stored=await page.evaluate(()=>stored);frame=await mount(definitions.todo,{stored});
  await frame.locator('.check[aria-pressed=true]').waitFor();
  await page.evaluate(()=>{window.failSave=true;});await frame.locator('.remove').click();
  await frame.locator('#status').filter({hasText:'Test save conflict'}).waitFor();
  check(await frame.locator('.task').count()===1,'Save failures must retain persisted tasks');
  await frame.locator('article').screenshot({path:outputDirectory+'/todo.png'});
  frame=await mount(definitions.focus);await frame.locator('#toggle').click();await page.waitForFunction(()=>stored.value?.running===true);
  const timer=await page.evaluate(()=>stored);timer.value.deadline=Date.now()+4200;
  frame=await mount(definitions.focus,{stored:timer});
  const value=await frame.locator('#remaining').textContent();check(value==='00:05'||value==='00:04','Timer must restore an absolute deadline: '+value);
  await frame.locator('#toggle').click();await page.waitForFunction(()=>stored.value?.running===false);
  await frame.locator('#mode-short').click();await page.waitForFunction(()=>stored.value.mode==='short');
  check(await frame.locator('#remaining').textContent()==='05:00','Short break duration');
  await frame.locator('article').screenshot({path:outputDirectory+'/focus.png'});
  frame=await mount(definitions.countdown);
  await frame.locator('#event-name').fill('下一次旅行');await frame.locator('#event-date').fill('2030-01-01');await frame.locator('#save-event').click();
  await frame.locator('#event-form').waitFor({state:'hidden'});check(await frame.locator('#event').textContent()==='下一次旅行','Countdown saved event');
  await frame.locator('article').screenshot({path:outputDirectory+'/countdown.png'});
  for(const id of ['clock','balance']){frame=await mount(definitions[id]);await frame.locator('article').screenshot({path:outputDirectory+'/'+id+'.png'});}
  frame=await mount(definitions.clock,{locale:'en'});await frame.locator('#format').click();await page.waitForFunction(()=>stored.value?.hour12===true);
  await page.evaluate(()=>nativePort.postMessage(JSON.stringify({type:'state',values:{},active:true,panel:{data:{},inputs:{},locale:'en',theme:'dark',tokens:{text:'#eeeeee','text-secondary':'#a5ada7',surface:'#151b17',accent:'#8ac9ac',border:'#35443b'},canRefresh:false,status:'ready'}})));
  check(await frame.locator('#time').evaluate(el=>getComputedStyle(el).color)==='rgb(238, 238, 238)','Theme must propagate live');
  const overflow=await frame.evaluate(()=>document.documentElement.scrollWidth>innerWidth);check(!overflow,'English 12h clock overflow');
  const balance=definitions.balance;
  frame=await mount({...balance,data:{...balance.data,amounts:[{currency:'USD',label:'Account',kind:'account',total:'123.45'}],checkedAt:1}},
    {stored:{value:{balanceHidden:true},revision:'legacy'}});
  check(await frame.locator('#privacy').count()===0,'Balance has no hide control');
  check(await frame.locator('#amount').getAttribute('aria-label')==='$123.45','USD amount includes its symbol and ignores old hide preferences');
  check((await page.evaluate(()=>messages)).every(message=>message.type!=='storageLoad'&&message.type!=='storageSave'),'Balance has no privacy storage dependency');
  frame=await mount({...balance,data:{...balance.data,amounts:[{currency:'CNY',label:'账户余额',kind:'account',total:'94.63'}],checkedAt:1}},{width:344});
  check(await frame.locator('#amount').getAttribute('aria-label')==='￥94.63','CNY balance includes the requested yuan symbol');
  await frame.locator('article').screenshot({path:outputDirectory+'/balance-currency.png'});
  for(const [row,expected] of [[{currency:'CNY',total:'0.00'},'￥0.00'],[{currency:'credits',total:'1234.56789'},'1,234.56789 credits'],[{currency:'CNY',unlimited:true},'无限额'],[{currency:'CNY'},'未返回额度']]){
    frame=await mount({...balance,data:{...balance.data,amounts:[{...row,label:'Balance',kind:'account'}],checkedAt:1}},{width:174});
    check(await frame.locator('#amount').getAttribute('aria-label')===expected,'Currency must preserve precision, zero and quota semantics: '+expected);
    check(!(await frame.evaluate(()=>document.documentElement.scrollWidth>innerWidth)),'Currency amount must fit a narrow card');
  }
  if(definitions['guide-welcome']){
    for(const id of ['guide-welcome','guide-move','guide-resize']){
      for(const width of [174,344]){
        frame=await mount({...definitions[id],view:{...definitions[id].view,height:720}},{width,autoHeight:true});
        await page.waitForFunction(()=>messages.some(message=>message.type==='resize'));
        await page.waitForTimeout(350);
        const before=await frame.locator('article').boundingBox();
        check(before.height<500,'Inline guide must shrink to natural content: '+id);
        await page.evaluate(()=>document.documentElement.style.height=(parseFloat(document.documentElement.style.height)+120)+'px');
        await page.waitForTimeout(150);
        const after=await frame.locator('article').boundingBox();
        check(Math.abs(before.height-after.height)<1,'Inline guide must not depend on its viewport: '+id);
        check(await page.evaluate(()=>messages.filter(message=>message.type==='resize').length)<4,'Guide height feedback must settle: '+id);
      }
      frame=await mount(definitions[id],{width:344,autoHeight:true,fixedViewport:true});
      check(Math.abs((await frame.locator('article').boundingBox()).height-definitions[id].view.height)<1,'Board guide must fill its explicit viewport: '+id);
    }
    for(const id of ['guide-welcome','guide-move','guide-resize']){
      frame=await mount(definitions[id],{width:id==='guide-welcome'?344:166});
      check(!(await frame.locator('h1,h2').textContent()).includes('\\n'),'Guide line breaks must render');
      await frame.waitForFunction(()=>[...document.querySelectorAll('[data-reveal]')].every(element=>element.getAnimations().every(animation=>animation.playState==='finished')));
      await frame.locator('article').screenshot({path:outputDirectory+'/'+id+'.png'});
    }
    frame=await mount(definitions['guide-move'],{width:166});
    await frame.waitForFunction(()=>document.querySelector('article').getAnimations({subtree:true}).some(animation=>animation.playState==='running'));
    await page.evaluate(()=>nativePort.postMessage(JSON.stringify({type:'state',values:{},active:false,panel:probePanel})));
    await frame.waitForFunction(()=>!tinybot.active);
    check(await frame.evaluate(()=>document.querySelector('article').getAnimations({subtree:true}).every(animation=>animation.playState!=='running')),'Guide effects must pause while inactive');
    await page.emulateMedia({reducedMotion:'reduce'});
    frame=await mount(definitions['guide-welcome']);
    check(await frame.evaluate(()=>document.querySelector('article').getAnimations({subtree:true}).length)===0,'Reduced motion must show static readable content');
    check(await frame.locator('h1').evaluate(element=>getComputedStyle(element).webkitTextFillColor)!=='rgba(0, 0, 0, 0)','Reduced-motion headline must remain visible');
    await page.emulateMedia({reducedMotion:'no-preference'});
  }
  check(!failures.length,JSON.stringify(failures));check(!requests.length,'Built-ins must not fetch external resources');
  return {cards:Object.keys(definitions).length,probeWidths:[174,344],persistence:true,saveConflict:true,timerResume:true,themes:true,tapHighlight:'transparent',guideMotion:true,guideAutoHeight:true,networkRequests:requests.length};
}
