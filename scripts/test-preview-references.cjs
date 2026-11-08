// Real publication, AgentLoop wording repair, final placement and persisted/static projections.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const studio=process.env.DEVECO_STUDIO_HOME||'C:/Program Files/Huawei/DevEco Studio';
const ts=require(path.join(studio,'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root=path.resolve(__dirname,'../entry/src/main/ets'),cache=new Map();
function load(file){file=path.resolve(file.endsWith('.ets')?file:file+'.ets');if(cache.has(file))return cache.get(file);
  const exports={};cache.set(file,exports);vm.runInNewContext(ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{
    module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021,experimentalDecorators:true}}).outputText,
  {exports,Error,Observed:cls=>cls,console,setTimeout,clearTimeout,require:id=>id.endsWith('/I18n')?{t:s=>s}:load(path.resolve(path.dirname(file),id))},{filename:file});return exports;}
const from=name=>load(path.join(root,name)),plain=x=>JSON.parse(JSON.stringify(x));
const {previewReference,previewReferenceParts,previewReferenceTargets,previewReferenceError}=from('model/PreviewReferences');
const {publishedAnswerParts,stepPreviews,stepDisplayContent,latestPreviewIds}=from('model/PublishedPreview');
const {PreviewTools}=from('services/PreviewTools'),{runAgentLoop}=from('services/AgentLoop'),{Cancellation}=from('services/Cancellation');
const {validateSteps}=from('model/Agent'),{parseAppData,emptyData}=from('model/Conversation');
const {buildTimeline}=from('model/ProcessPresentation'),{conversationSections}=from('model/ConversationExport');
const {selectedConversation,conversationMarkdown}=from('model/ConversationShare');
const {panelReference}=from('model/PublishedPanel');
const image={id:'shot',name:'preview.jpg',path:'shot.jpg',mime:'image/jpeg',size:20};
const call=(id,name,args)=>({id,type:'function',function:{name,arguments:JSON.stringify(args)}});
function fixture(){const turn={content:'',steps:[]},effects={reads:0,probes:0,captures:0};
  const tools=new PreviewTools({read:async path=>{effects.reads++;return {path,content:'<p>Immutable content</p>',version:'v1'};}},
    async()=>{effects.probes++;},async()=>{effects.captures++;return {image,width:300,height:200,viewportWidth:300};});
  return {turn,effects,tools};}
async function execute(f,respond,limit=6,signal=new Cancellation(),observer={}){let round=0;await runAgentLoop({
  turn:f.turn,tools:f.tools,maxSteps:limit,messages:[],model:{stream:async messages=>respond(round++,messages)}},signal,
  {event(){},checkpoint:async()=>validateSteps(f.turn.steps),...observer});return round;}
function panelReferences(){
  const card={workspaceId:'owner',panelId:'mail'},board={workspaceId:'owner',boardId:'board'};
  const ref=panelReference(card),boardRef=panelReference(board);
  const receipt=(name,target,status='complete')=>({status,call:call(name,name,{}),output:JSON.stringify({...target,title:name})});
  const publish={content:'',tools:[receipt('publish_life_panel',card),receipt('manage_life_board',board),
    receipt('publish_life_panel',{workspaceId:'owner',panelId:'debug-probe'})]};
  const steps=[publish,{content:'Before\n'+boardRef+'\nMiddle\n'+ref+'\nAfter\n'+ref,tools:[]}];
  const display=(content,status='complete')=>publishedAnswerParts('panels',[publish,{content,tools:[]}],1,status,[]);
  assert.equal(display('Done').filter(p=>p.kind==='panel').length,0,'No reference means no automatic card/board display');
  const parts=publishedAnswerParts('panels',steps,1,'complete',[]);
  assert.deepEqual(Array.from(parts,p=>p.kind),['text','panel','text','panel','text','pending']);
  assert.deepEqual(Array.from(parts[1].panel.excludedPanelKeys),['owner/mail']);
  assert.equal(parts[3].panel.target.panelId,'mail','Only the requested card is shown, never a debug publication');
  assert.deepEqual(Array.from(display(boardRef)[0].panel.excludedPanelKeys),[],'Unreferenced publications do not hide cards inside the board');
  assert.equal(previewReferenceError([publish], 'Done'),'','Omitting a widget reference never triggers an answer-repair request');
  for(const status of ['generating','failed','stopped'])assert.equal(display(ref,status).filter(p=>p.kind==='panel').length,0);
  for(const content of ['```text\n'+ref+'\n```','~~~~\n'+ref+'\n~~~~','\\'+ref,'> '+ref,'    '+ref,'See '+ref]){
    assert.ok(display(content).every(p=>p.kind==='text'),'Examples, code, quotes and inline text never mount cards');
  }
  for(let i=2;i<ref.length;i++)assert.ok(display('Before\n'+ref.slice(0,i),'generating').every(p=>p.kind==='text'||p.kind==='pending'));
  assert.equal(display('[[tinybot-panel:owner/unknown]]')[0].kind,'error');
  assert.equal(display('[[tinybot-panel:../mail]]')[0].kind,'error');
  for(const name of ['get_life_panel','get_life_board']){
    const target=name==='get_life_panel'?card:board,reference=panelReference(target);
    const read=[{content:'',tools:[receipt(name,target)]},{content:reference,tools:[]}];
    assert.equal(publishedAnswerParts('read',read,1,'complete',[])[0].kind,'panel','Existing cards/boards can be referenced without publishing again');
  }
  const child={content:'',tools:[{status:'failed',call:call('batch','orchestrate',{}),output:'',children:[receipt('publish_life_panel',card)]}]};
  assert.equal(publishedAnswerParts('child',[child,{content:ref,tools:[]}],1,'complete',[])[0].kind,'panel');
  const failed={content:'',tools:[receipt('publish_life_panel',card,'failed')]};
  assert.equal(publishedAnswerParts('failed',[failed,{content:ref,tools:[]}],1,'complete',[])[0].kind,'error');
  const sections=conversationSections({title:'Widgets',messages:[{id:'panels',role:'assistant',content:steps[1].content,status:'complete',error:'',steps}]});
  assert.ok(!JSON.stringify(sections).includes('[[tinybot-'),'Export replaces references with readable titles');
  const shared=selectedConversation({title:'Widgets',messages:[{id:'panels',role:'assistant',content:steps[1].content,status:'complete',error:'',steps}]},['panels']);
  const markdown=conversationMarkdown(shared);
  assert.ok(markdown.includes('[publish_life_panel]')&&markdown.includes('[manage_life_board]'));
  assert.ok(!markdown.includes('[[tinybot-')&&!markdown.includes('Preview unavailable'));
  assert.ok(!JSON.stringify(shared).includes('debug-probe'),'Sharing excludes unrelated card data and receipts');
  console.log('PASS optional card/board references: inline placement, omitted/debug suppression, duplicate and board deduplication, read-only lookup, streaming/status gates and export');

  // Exercise the actual emitted answer builder, including its surrounding tail.
  const source=path.join(root,'views/MessageBubble.ets');
  const emitted=path.resolve(__dirname,'../entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/views/MessageBubble.ts');
  assert.ok(fs.statSync(emitted).mtimeMs>=fs.statSync(source).mtimeMs,'Build before native answer rendering checks');
  const tree=ts.createSourceFile(emitted,fs.readFileSync(emitted,'utf8'),ts.ScriptTarget.Latest,true);
  const component=tree.statements.find(n=>ts.isClassDeclaration(n)&&n.name.text==='MessageBubble');
  const method=component.members.find(n=>n.name?.getText(tree)==='assistantMessage').getText(tree);
  function mount(content,status='complete'){
    const rendered=[],noUi=new Proxy({},{get:()=>()=>{}}),effect={combine(){return this},animation(){return this}};
    const child=kind=>class{constructor(_parent,params){rendered.push({kind,...params});}};
    const globals={exports:{},Column:noUi,Row:noUi,ForEach:noUi,Text:noUi,Image:noUi,Blank:noUi,If:noUi,Space:{},HorizontalAlign:{},VerticalAlign:{},FontWeight:{},Motion:{},Alignment:{},
      TransitionEffect:{OPACITY:effect,translate:()=>effect},ViewPU:{create(){}},ViewStackProcessor:{StartGetAccessRecordingFor(){},StopGetAccessRecording(){}},
      InteractiveAnswer:child('text'),PublishedPanelCard:child('panel'),PublishedPreviewCard:child('preview'),ProcessGroup:child('process'),MessageUsage:child('usage'),
      stepPreviews,deliveredFiles:()=>[],turnFileChanges:()=>[], $r:x=>x};
    vm.runInNewContext(ts.transpileModule('class Probe{'+method+'}exports.Probe=Probe;',{
      compilerOptions:{target:ts.ScriptTarget.ES2021}}).outputText,globals);
    const current=[publish,{content,tools:[]}];let next=0;
    const view=Object.assign(new globals.exports.Probe(),{message:{id:'native',content,status,error:'',stepViews:current,steps:current},appearance:{},latestPreviewIds:[],
      images:()=>[],workflowVisible:()=>false,timeline:()=>buildTimeline(current),entryVisible:()=>true,traceEntry:()=>false,folded:()=>true,workflowRail:()=>undefined,
      answerParts:index=>publishedAnswerParts('native',current,index,status,[]),retryStatus:()=>'',messageActions(){},
      observeComponentCreation2:fn=>fn(++next,true),ifElseBranchUpdateFunction:(_id,render)=>render(),forEachUpdateFunction:(_id,items,render)=>items.forEach(render)});
    view.assistantMessage();return rendered.filter(p=>['text','panel','preview'].includes(p.kind));
  }
  assert.deepEqual(mount('Done').map(p=>p.kind),['text'],'The actual answer tail never appends published widgets');
  const native=mount(steps[1].content);
  assert.deepEqual(native.map(p=>p.kind),['text','panel','text','panel','text']);
  assert.equal(native[3].reference.target.panelId,'mail');
  assert.equal(mount(ref+'\n'+ref).length,1,'Native output mounts repeated references once');
  assert.equal(mount(ref,'generating').length,0,'No widget mounts during generation');
  console.log('PASS emitted MessageBubble: optional inline widget placement, no appended cards, repeated reference mounts once and generation mounts none');
}
async function main(){
  panelReferences();
  const f=fixture();let reference;
  const rounds=await execute(f,(round,messages)=>{
    if(round===0)return {content:'Preparing',toolCalls:[call('prepare','publish_preview',{path:'scene.html'})]};
    reference=JSON.parse(f.turn.steps[0].tools[0].output).reference;
    if(round===1){assert.equal(stepPreviews('m',f.turn.steps[0],0,[]).length,0);return {content:'Forgot the reference',toolCalls:[]};}
    assert.ok(messages.some(m=>m.content.includes('Missing preview reference: '+reference)));
    return {content:'Before\n\n'+reference+'\n\nAfter',toolCalls:[]};
  });
  assert.equal(rounds,3);assert.deepEqual(f.effects,{reads:1,probes:1,captures:1});
  const targets=previewReferenceTargets(f.turn.steps),id=targets[0].previewId;
  assert.ok(f.turn.steps[1].uiValidation.includes('PREVIEW_REFERENCE_INVALID'));
  assert.equal(stepDisplayContent({...f.turn.steps[0],content:''}),'');
  const parts=publishedAnswerParts('m',f.turn.steps,2,'complete',[]);
  assert.deepEqual(Array.from(parts,p=>p.kind),['text','preview','text']);
  assert.equal(parts[1].preview.step,0);assert.equal(parts[1].preview.screenshot.image.id,'shot');
  for(const status of ['generating','failed','stopped'])assert.equal(publishedAnswerParts('m',f.turn.steps,2,status,[]).filter(p=>p.kind==='preview').length,0);
  assert.equal(publishedAnswerParts('m',f.turn.steps,0,'complete',[]).filter(p=>p.kind==='preview').length,0);
  assert.equal(previewReferenceError(f.turn.steps,reference),'');
  assert.ok(previewReferenceError(f.turn.steps,reference+'\n'+reference).includes('Duplicate'));
  assert.ok(previewReferenceError(f.turn.steps,'[[tinybot-preview:pv_foreign]]').includes('Unknown'));
  assert.ok(previewReferenceError(f.turn.steps,'[[tinybot-preview:/arbitrary/file.html]]').includes('Malformed'));
  for(const code of ['```text\n'+reference+'\n```','~~~~\n'+reference+'\n~~~~','\\'+reference,'> '+reference,'    '+reference]){
    assert.equal(previewReferenceParts(code).some(p=>p.kind==='preview'),false);assert.ok(previewReferenceError(f.turn.steps,code).includes('Missing'));}
  for(let length=2;length<reference.length;length++){
    const stream=previewReferenceParts('Before\n'+reference.slice(0,length),true);
    assert.ok(!stream.some(p=>p.kind==='invalid'));assert.ok(!stream.some(p=>p.content.includes('[[tinybot-preview:')));
  }
  assert.ok(previewReferenceError(f.turn.steps,Array(1000).fill('[[tinybot-preview:invalid]]').join('\n')).length<=8000);
  console.log('PASS actual publication -> missing-reference feedback -> final placement, no repeated effects, stream/stopped gates and scoped reference grammar');

  const data=emptyData();data.activeThreadId='t';data.threads=[{id:'t',title:'References',updatedAt:1,messages:[
    {id:'u',role:'user',content:'Show a preview',status:'complete',error:''},
    {id:'m',role:'assistant',content:f.turn.content,status:'complete',error:'',steps:f.turn.steps}]}];
  const restored=parseAppData(JSON.stringify(data)),message=restored.threads[0].messages[1];
  assert.equal(publishedAnswerParts('m',message.steps,2,'complete',[])[1].preview.content,parts[1].preview.content);
  const sections=conversationSections(restored.threads[0]);
  const before=sections.findIndex(s=>s.text==='Before'),shot=sections.findIndex(s=>s.kind==='attachment-image'),after=sections.findIndex(s=>s.text==='After');
  assert.ok(before>=0&&shot>before&&after>shot);assert.equal(sections.filter(s=>s.kind==='attachment-image').length,1);
  assert.ok(!JSON.stringify(sections).includes('Forgot the reference'));assert.ok(!JSON.stringify(sections).includes(reference));
  const selected=selectedConversation(restored.threads[0],['m']);
  assert.equal(conversationSections(selected).filter(s=>s.kind==='attachment-image').length,1);
  assert.ok(!conversationMarkdown(selected).includes('[[tinybot-preview:'));assert.ok(!conversationMarkdown(selected).includes('Preparing'));
  const legacy=plain(f.turn.steps[0]);const old=JSON.parse(legacy.tools[0].output);delete old.previewId;delete old.reference;legacy.tools[0].output=JSON.stringify(old);legacy.content='';
  assert.equal(stepPreviews('old',legacy,0,latestPreviewIds([{id:'old',steps:[legacy]}])).length,1);
  assert.ok(stepDisplayContent(legacy).includes('tinybot-ui'));assert.ok(buildTimeline([legacy]).some(p=>p.kind==='text'));
  assert.equal(previewReferenceError([legacy],'Old answer'),'');
  const revision=plain(f.turn.steps[0]);const updated=JSON.parse(revision.tools[0].output);updated.previewId='pv_revision';updated.reference=previewReference(updated.previewId);revision.tools[0].call.id='revision';revision.tools[0].output=JSON.stringify(updated);
  assert.equal(previewReferenceError([f.turn.steps[0],revision],updated.reference),'');
  assert.ok(previewReferenceError([f.turn.steps[0],revision],reference).includes('Missing'));
  const second=plain(revision),secondReceipt=JSON.parse(second.tools[0].output);
  secondReceipt.path='second.html';second.tools[0].output=JSON.stringify(secondReceipt);
  const multiple=[f.turn.steps[0],second,{content:'First\n'+reference+'\nMiddle\n'+updated.reference+'\nLast',tools:[]}];
  assert.equal(previewReferenceError(multiple,multiple[2].content),'');
  assert.deepEqual(Array.from(publishedAnswerParts('multi',multiple,2,'complete',[]),p=>p.kind),['text','preview','text','preview','text']);
  assert.equal(targets[0].previewId,id);
  console.log('PASS immutable reload, legacy auto-display, latest revisions, inline static image export and final-only sharing');

  const bad=fixture();let corrections=0;
  await assert.rejects(execute(bad,round=>round===0?{content:'',toolCalls:[call('bad','publish_preview',{path:'bad.html'})]}:
    {content:++corrections?'[[tinybot-preview:pv_wrong]]':'',toolCalls:[]},5),/UI validation failed after repair attempts/);
  assert.equal(corrections,3);assert.equal(bad.effects.reads,1);
  const stopped=fixture(),signal=new Cancellation();
  await assert.rejects(execute(stopped,()=>({content:'',toolCalls:[call('stop','publish_preview',{path:'stop.html'})]}),4,signal,
    {event:e=>{if(e.type==='tool_end')signal.cancel();}}));
  assert.equal(stopped.turn.steps[0].tools[0].status,'complete');
  assert.equal(stepPreviews('stopped',stopped.turn.steps[0],0,[]).length,0);
  console.log('PASS invalid-reference retries are bounded; cancellation preserves prepared snapshots without displaying them');

  // Execute the emitted surface renderer: the native wrapper must actually lose its chrome.
  const emitted=path.resolve(__dirname,'../entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/views/InteractiveAnswer.ts');
  const source=path.join(root,'views/InteractiveAnswer.ets');
  assert.ok(fs.statSync(emitted).mtimeMs>=fs.statSync(source).mtimeMs,'Build before the native surface regression');
  const tree=ts.createSourceFile(emitted,fs.readFileSync(emitted,'utf8'),ts.ScriptTarget.Latest,true);
  const surface=tree.statements.find(n=>ts.isClassDeclaration(n)&&n.name.text==='UiSurface');
  const render=surface.members.find(n=>n.name?.getText(tree)==='initialRender').getText(tree);
  function mount(frameless){const styles={},labels=[];
    const noUi=new Proxy({},{get:()=>()=>{}});
    const globals={exports:{},Column:new Proxy({},{get:(_,name)=>value=>{styles[name]=value;}}),If:noUi,Row:noUi,
      Text:new Proxy({},{get:(_,name)=>value=>{if(name==='create')labels.push(value);}}),LoadingProgress:noUi,
      ForEach:noUi,Button:noUi,HorizontalAlign:{},FontWeight:{},Radius:{md:12},Color:{Transparent:'transparent'},$r:x=>x,t:x=>x};
    vm.runInNewContext(ts.transpileModule('class Probe{'+render+'}exports.Probe=Probe;',{compilerOptions:{target:ts.ScriptTarget.ES2021}}).outputText,globals);
    const view=Object.assign(new globals.exports.Probe(),{frameless,title:'Preview title',appearance:{},nodes:[],invalid:[],error:'',busy:false,complete:true,failed:false,dirty:false,
      observeComponentCreation2:fn=>fn(1,true),ifElseBranchUpdateFunction:(_id,create)=>create(),forEachUpdateFunction:(_id,items,create)=>items.forEach(create)});
    view.initialRender();return {styles,labels};}
  const inline=mount(true),card=mount(false);
  assert.equal(inline.styles.padding,0);assert.equal(inline.styles.backgroundColor,'transparent');assert.equal(inline.styles.border.width,0);
  assert.ok(!inline.labels.includes('Preview title'));assert.equal(card.styles.padding,14);assert.equal(card.styles.border.width,1);assert.ok(card.labels.includes('Preview title'));
  console.log('PASS actual emitted surface renderer: inline preview has no heading, padding, background or border; legacy card retains chrome');
}
main().catch(error=>{console.error(error);process.exitCode=1;});
