// Build first. Verify native playback lifecycle and that every tap lands on its visible control.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'..');
const studio=process.env.DEVECO_STUDIO_HOME||path.join(process.env.ProgramFiles,'Huawei/DevEco Studio');
const ts=require(path.join(studio,'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const src=path.join(root,'entry/src/main/ets/views/HelpDemo.ets');
const emitted=path.join(root,'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/views/HelpDemo.ts');
assert.ok(fs.statSync(emitted).mtimeMs>=fs.statSync(src).mtimeMs,'Build before testing');
const model={exports:{}};
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root,'entry/src/main/ets/model/HelpTutorial.ets'),'utf8'),{
 compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText,model);
const api=model.exports;
const tree=ts.createSourceFile(emitted,fs.readFileSync(emitted,'utf8'),ts.ScriptTarget.Latest,true);
const component=tree.statements.find(n=>ts.isClassDeclaration(n)&&n.name.text==='HelpDemo');
const methods=['aboutToAppear','aboutToDisappear','syncPlayback','navigation','focus','zoom','cameraRect','cameraOffset','cameraX','cameraY',
 'pointerX','pointerY','pointerAlpha','tap','ripple','stageAlpha','isOverlay','pageChange'];
const context={exports:{},...api};
vm.runInNewContext(ts.transpileModule(`class Probe { ${component.members.filter(n=>methods.includes(n.name?.getText(tree))).map(n=>n.getText(tree)).join('\n')} }
exports.Probe=Probe;`,{compilerOptions:{target:ts.ScriptTarget.ES2021}}).outputText,context);
const animations=[];
const probe=Object.assign(new context.exports.Probe(),{kind:'chat',foreground:true,mounted:false,visible:false,playing:false,index:0,phase:0,stageWidth:300,
 getUIContext:()=>({createAnimator:options=>{
  const animator={options,plays:0,pauses:0,cancelled:false,play(){this.plays++;},pause(){this.pauses++;},cancel(){this.cancelled=true;this.onFrame?.(2);}};
  animations.push(animator);return animator;
 }})});
probe.aboutToAppear();probe.syncPlayback();assert.equal(animations.length,0);
probe.visible=true;probe.syncPlayback();const animator=animations[0];
assert.equal(animator.options.duration,7600);assert.equal(animator.options.iterations,-1);
animator.onFrame(.43);assert.equal(probe.index,0);assert.equal(probe.navigation(),0,'Page changes must follow the tap');
probe.foreground=false;probe.syncPlayback();animator.onFrame(2.5);assert.equal(probe.index,0);
probe.foreground=true;probe.syncPlayback();probe.visible=false;probe.syncPlayback();animator.onFrame(2.5);assert.equal(probe.index,0);
probe.visible=true;probe.syncPlayback();assert.equal(animations.length,1,'Resume must preserve the timeline');
probe.syncPlayback();assert.equal(animations.length,1,'Visibility callbacks must not duplicate loops');
const zh=JSON.parse(fs.readFileSync(path.join(root,'locales/zh-CN.json'),'utf8'));
const en=JSON.parse(fs.readFileSync(path.join(root,'locales/en.json'),'utf8'));
for(const kind of ['chat','attachments','preferences','backup','failure','prepare','model','task','results']) {
 const steps=api.tutorialSteps(kind);assert.ok(steps.length*api.TUTORIAL_STEP_MS<=12000,'Tutorials must stay short');
 for(const [index,step] of steps.entries()) {
  assert.ok(zh[step.caption]&&en[step.caption],'Missing caption translation: '+step.caption);
  const rect=api.tutorialRect(step.control);
  assert.ok(rect.x>=0&&rect.y>=0&&rect.x+rect.width<=api.TUTORIAL_WIDTH&&rect.y+rect.height<=api.TUTORIAL_HEIGHT);
  Object.assign(probe,{steps,index,phase:.43});
  if(['composer','document-input','key','send','stop','mic'].includes(step.control)) {
   assert.equal(probe.pageChange(),false,'Typing and message updates must keep the current page stationary');
  }
  assert.ok(Math.abs(probe.pointerX()-(rect.x+rect.width/2))<1e-6,'Tap must land on the horizontal center');
  assert.ok(Math.abs(probe.pointerY()-(rect.y+rect.height/2))<1e-6,'Tap must land on the vertical center');
  for(const width of [230,300,420]) {
   probe.stageWidth=width;
   const x=probe.pointerX()*probe.zoom()+probe.cameraX(),y=probe.pointerY()*probe.zoom()+probe.cameraY();
   assert.ok(x>0&&x<width&&y>0&&y<320,'Camera must keep the tap visible on narrow and wide layouts');
   probe.phase=.7;
   const result=api.tutorialResultRect(step);
   const resultX=(result.x+result.width/2)*probe.zoom()+probe.cameraX();
   const resultY=(result.y+result.height/2)*probe.zoom()+probe.cameraY();
   assert.ok(resultX>0&&resultX<width&&resultY>0&&resultY<320,'Camera must also show the result of the click');
   probe.phase=.43;
  }
 }
}
for(const kind of ['chat','attachments','preferences','backup','failure','prepare','model','task','results']) {
 const steps=api.tutorialSteps(kind);
 for(let index=0;index<steps.length-1;index++) {
  Object.assign(probe,{steps,index,phase:1});
  assert.equal(probe.focus(),1,'Intermediate steps must retain the close-up instead of returning to the overview');
  if(steps[index].after!==steps[index+1].screen) continue;
  for(const width of [230,300,420]) {
   Object.assign(probe,{index,phase:1,stageWidth:width});
   const end={zoom:probe.zoom(),x:probe.cameraX(),y:probe.cameraY()};
   Object.assign(probe,{index:index+1,phase:0});
   assert.equal(probe.stageAlpha(),1,'Connected steps must not fade out and restart');
   assert.ok(Math.abs(probe.zoom()-end.zoom)<1e-6,'Step boundaries must preserve camera zoom');
   assert.ok(Math.abs(probe.cameraX()-end.x)<1e-6,'Step boundaries must preserve camera X');
   assert.ok(Math.abs(probe.cameraY()-end.y)<1e-6,'Step boundaries must preserve camera Y');
  }
 }
 Object.assign(probe,{steps,index:steps.length-1,phase:1});
 assert.equal(probe.focus(),0,'Only the end of the tutorial returns to the overview');
}
const screen=fs.readFileSync(path.join(root,'entry/src/main/ets/views/HelpTutorialScreen.ets'),'utf8');
for(const match of screen.matchAll(/this\.text\('([^']+)'\)/g)) assert.ok(zh[match[1]]&&en[match[1]],'Missing screen translation: '+match[1]);
Object.assign(probe,{steps:api.tutorialSteps('chat'),index:3,phase:1});assert.equal(probe.stageAlpha(),0);
probe.index=0;probe.phase=0;assert.equal(probe.stageAlpha(),0,'Loop rewinds while the stage is hidden');
probe.aboutToDisappear();assert.equal(animator.cancelled,true);assert.equal(probe.animator,undefined);
const phase=probe.phase;animator.onFrame(1.5);assert.equal(probe.phase,phase,'Detached callbacks cannot mutate the component');
console.log('PASS help walkthroughs: all topics, real control targets, camera visibility, tap-before-navigation, translations, background/offscreen suspension and cleanup');
