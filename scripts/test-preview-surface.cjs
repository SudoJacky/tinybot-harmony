// Build first. Exercise the emitted owner against a stateful native-node adapter.
// This verifies node identity and lifecycle; it does not replace ArkWeb device validation.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const studio=process.env.DEVECO_STUDIO_HOME||path.join(process.env.ProgramFiles,'Huawei/DevEco Studio');
const ts=require(path.join(studio,'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root=path.resolve(__dirname,'..');
const source=path.join(root,'entry/src/main/ets/views/PreviewSurface.ets');
const built=path.join(root,'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/views/PreviewSurface.ts');
assert.ok(fs.statSync(built).mtimeMs>=fs.statSync(source).mtimeMs,'Build PreviewSurface before testing');
let builds=0,disposals=0,appends=0,moves=0;const builders=[],logs=[];
class Frame {
 constructor(){this.parent=null;this.children=[];this.live=false;this.commonAttribute={width(){}};}
 getParent(){return this.parent;}
 appendChild(child){assert.equal(child.parent,null,'Initial attach only; reparenting must use moveTo');appends++;this.children.push(child);child.parent=this;}
 moveTo(parent){assert.equal(parent.live,true,'Move only after the destination is attached');moves++;
  this.parent.children=this.parent.children.filter(child=>child!==this);parent.children.push(this);this.parent=parent;}
}
class Builder {
 constructor(context){this.context=context;this.frame=new Frame();this.frame.page={document:{id:Symbol('document')},controller:{id:Symbol('web')},ports:[{}],score:7,initializations:0};builders.push(this);}
 build(_builder,options){this.options={...options};builds++;this.frame.page.initializations++;}
 getFrameNode(){return this.frame;}
 update(options){this.options={...options};}
 dispose(){disposals++;this.frame.page.disposed=true;if(this.frame.parent)this.frame.parent.children=this.frame.parent.children.filter(child=>child!==this.frame);}
}
const exportsObject={};
vm.runInNewContext(ts.transpileModule(fs.readFileSync(built,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText,{
 exports:exportsObject,wrapBuilder:builder=>({builder}),require:id=>{
  if(id==='@ohos:arkui.node')return {BuilderNode:Builder,NodeController:class{},typeNode:{createNode(){return new Frame();}}};
  if(id.endsWith('/Diagnostics&'))return {Diagnostics:{log:(...args)=>logs.push(args)}};
  if(id.endsWith('/InteractiveAnswer&'))return {InteractiveAnswer:class{}};
  throw Error('Unexpected native dependency: '+id);
 }
},{filename:built});
const {PreviewSurface,PreviewSurfaceOptions}=exportsObject;
const preview={id:'answer:publication',content:'immutable preview snapshot',step:3,surfaceOffset:2,path:'game.js',title:'Game'};
function options(){const value=new PreviewSurfaceOptions(preview);value.available=true;value.frameless=false;value.saved=[{key:'3:2',values:{count:4}}];return value;}
function mount(controller){const parent=controller.makeNode({});parent.live=true;controller.aboutToAppear();return parent;}
const surface=new PreviewSurface();surface.setOptions(options());const inline=mount(surface.inlineMount);
assert.equal(builds,1);assert.equal(appends,1);const frame=inline.children[0],page=frame.page,controller=page.controller,document=page.document,ports=page.ports;
for(let index=0;index<50;index++){
 surface.enterFullscreen();const fullscreen=surface.fullscreenMount.makeNode({});
 assert.equal(frame.getParent(),inline,'Preparing a cover must not detach the live page');
 fullscreen.live=true;surface.fullscreenMount.aboutToAppear();assert.equal(frame.getParent(),fullscreen);
 surface.resizeFullscreen(900);assert.equal(builders[0].options.viewportHeight,900);assert.equal(builders[0].options.frameless,true);
 page.score++;
 surface.setOptions(options());assert.equal(builders[0].options.viewportHeight,900,'Availability/state updates retain the fullscreen viewport');
 surface.exitFullscreen();assert.equal(frame.getParent(),inline,'Restore before the cover is removed');
 assert.equal(builders[0].options.viewportHeight,0);assert.equal(builders[0].options.frameless,false);
 surface.fullscreenMount.aboutToDisappear();fullscreen.live=false;
 assert.equal(frame.page,page);assert.equal(page.controller,controller);assert.equal(page.document,document);assert.equal(page.ports,ports);
 assert.equal(page.initializations,1);assert.equal(disposals,0);assert.equal(builds,1);
}
assert.equal(page.score,57);assert.equal(moves,100);assert.equal(appends,1);
console.log('PASS 50 fullscreen round trips keep one builder, document/controller/port identity and advancing page state');
surface.enterFullscreen();surface.exitFullscreen();assert.equal(builds,1,'Cancelled cover creation does not recreate the preview');
surface.enterFullscreen();mount(surface.fullscreenMount);surface.fullscreenMount.aboutToDisappear();
assert.equal(frame.getParent(),inline,'Native cover dismissal restores inline ownership');assert.equal(disposals,0);
surface.enterFullscreen();mount(surface.fullscreenMount);surface.dispose();surface.dispose();
surface.fullscreenMount.aboutToDisappear();surface.inlineMount.aboutToDisappear();
assert.equal(disposals,1,'Removing a card releases its live page exactly once, including during fullscreen');
assert.throws(()=>surface.enterFullscreen(),/not mounted/);
console.log('PASS cancelled opening, native dismissal and owner disposal neither duplicate nor leak the live page');
const collapsed=new PreviewSurface();collapsed.setOptions(options());mount(collapsed.inlineMount);
collapsed.inlineMount.aboutToDisappear();assert.equal(disposals,2,'A collapsed/inspected inline preview does not retain an invisible renderer');
mount(collapsed.inlineMount);assert.equal(builds,3,'Reopening a deliberately removed inline host creates a fresh lifetime');collapsed.dispose();
assert.ok(logs.every(log=>log[1]==='preview'&&log[2]==='surface_moved'));
console.log('PASS ordinary inline removal retains the existing lazy-release policy and node transfers are observable');

// MatePad: sending in a restored conversation makes LazyForEach temporarily detach a cached
// NodeContainer, then call aboutToAppear again WITHOUT makeNode (the card is not destroyed).
const cached=new PreviewSurface();cached.setOptions(options());const cachedHost=mount(cached.inlineMount);
const cachedContext=builders.at(-1).context;
let cachedCover;
for(let index=0;index<20;index++){
 const previous=cachedHost.children[0],beforeBuilds=builds,beforeDisposals=disposals;
 cached.inlineMount.aboutToDisappear();cachedHost.live=false;
 assert.equal(disposals,beforeDisposals+1,'Detached inline renderers are released');
 const nextOptions=options();nextOptions.available=index%2===0;cached.setOptions(nextOptions);
 cachedHost.live=true;cached.inlineMount.aboutToAppear();
 assert.equal(builds,beforeBuilds+1,'Cached host reappearance recreates its released renderer');
 assert.equal(builders.at(-1).context,cachedContext,'Recreate in the original host UIContext');
 assert.equal(builders.at(-1).options.available,nextOptions.available,'Use current interaction availability');
 assert.deepEqual(builders.at(-1).options.saved,nextOptions.saved,'Restore persisted preview state');
 assert.equal(cachedHost.children.length,1);assert.notEqual(cachedHost.children[0],previous);
 assert.equal(previous.page.disposed,true);
 const live=cachedHost.children[0],beforeCoverBuilds=builds;
 cached.enterFullscreen();
 if(index===0){cachedCover=mount(cached.fullscreenMount);}
 else{cachedCover.live=true;cached.fullscreenMount.aboutToAppear();}
 assert.equal(live.getParent(),cachedCover);assert.equal(builds,beforeCoverBuilds);
 cached.fullscreenMount.aboutToDisappear();cachedCover.live=false;
 assert.equal(live.getParent(),cachedHost,'Reused fullscreen hosts restore the same live renderer');
}
cached.dispose();
assert.equal(disposals,builds,'Every renderer is released exactly once after all owners are disposed');
console.log('PASS cached inline and fullscreen hosts reappear without makeNode across 20 restored-chat lifecycle cycles');
