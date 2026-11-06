const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const studio=process.env.DEVECO_STUDIO_HOME||path.join(process.env.ProgramFiles,'Huawei/DevEco Studio');
const ts=require(path.join(studio,'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const cache=new Map();
function load(name){if(cache.has(name))return cache.get(name);const exports={};cache.set(name,exports);
 vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/model',name+'.ets'),'utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText,{exports,require:id=>load(path.basename(id))});return exports;}
const {gridStep,gridPixels,gridSnap,gridPlace,gridOverlap,validateGridRect}=load('PanelGrid');
const {parseLifeBoard}=load('LifeBoard');const plain=value=>JSON.parse(JSON.stringify(value));
const origin={x:0,y:0,w:6,h:6};
for(const width of [280,360,700])for(let w=2;w<=12;w++)for(let h=2;h<=12;h++){
 const target=gridSnap(origin,(w-6)*gridStep(width),(h-6)*gridStep(width),width,true);
 assert.deepEqual(plain(target),{x:0,y:0,w,h});validateGridRect(target);
 assert.ok(Math.abs(gridPixels(target,width).width-(w*gridStep(width)-8))<0.001);
}
assert.deepEqual(plain(gridSnap(origin,-10000,-10000,360,true)),{x:0,y:0,w:2,h:2});
assert.deepEqual(plain(gridSnap(origin,10000,10000,360,true)),{x:0,y:0,w:12,h:12});
assert.equal(gridSnap({x:8,y:2,w:4,h:3},1000,0,360,true).w,4);
const abc=[{x:0,y:0,w:6,h:5},{x:6,y:0,w:6,h:5},{x:0,y:5,w:12,h:7}];
assert.deepEqual(plain(gridPlace(abc,1,{x:0,y:12,w:6,h:5})),[abc[0],{x:0,y:12,w:6,h:5},abc[2]]);
assert.deepEqual(plain(gridPlace(abc,1,{x:0,y:0,w:6,h:5})),[{...abc[0],y:5},{x:0,y:0,w:6,h:5},{...abc[2],y:10}]);
// Exercise all legal widths/positions and multiple overlapping rows, retaining holes.
const crowded=Array.from({length:30},(_,i)=>({x:i%3*4,y:Math.floor(i/3)*5,w:4,h:3}));
const untouched=JSON.stringify(crowded);
for(let active=0;active<crowded.length;active++)for(let w=2;w<=12;w++){
 const target={x:12-w,y:active,w,h:2+active%11},placed=gridPlace(crowded,active,target);
 assert.deepEqual(plain(placed[active]),target);
 placed.forEach((rect,i)=>{validateGridRect(rect);if(i!==active){assert.equal(rect.x,crowded[i].x);assert.ok(rect.y>=crowded[i].y)}
  for(let j=0;j<i;j++)assert.equal(gridOverlap(rect,placed[j]),false);});
 assert.equal(JSON.stringify(placed),JSON.stringify(gridPlace(crowded,active,target)));
}
assert.equal(JSON.stringify(crowded),untouched);
const legacy={version:1,id:'board',title:'Old',description:'',items:['S','S','L'].map((size,i)=>({workspaceId:'owner',panelId:'panel-'+i,size,height:i===2?600:undefined})),archived:false,createdAt:1,updatedAt:2,editorThreadId:'editor'};
const migrated=parseLifeBoard(JSON.stringify(legacy),'board');assert.equal(migrated.version,2);
assert.deepEqual(plain(migrated.items.map(({x,y,w,h})=>({x,y,w,h}))),[{x:0,y:0,w:6,h:9},{x:6,y:0,w:6,h:9},{x:0,y:9,w:12,h:12}]);
assert.equal(migrated.editorThreadId,'editor');assert.equal(migrated.updatedAt,2);assert.equal(legacy.version,1);
assert.deepEqual(plain(parseLifeBoard(JSON.stringify(migrated),'board')),plain(migrated));
for(const bad of [{x:1.5,y:0,w:2,h:2},{x:11,y:0,w:2,h:2},{x:0,y:-1,w:2,h:2},{x:0,y:0,w:1,h:2},{x:0,y:0,w:2,h:13}])assert.throws(()=>validateGridRect(bad));
assert.throws(()=>parseLifeBoard(JSON.stringify({...migrated,items:migrated.items.map(i=>({...i,x:0,y:0}))}),'board'),/overlap/);
assert.throws(()=>parseLifeBoard(JSON.stringify({...migrated,items:[{...migrated.items[0],size:'S'}]}),'board'),/fields/);
console.log('PASS 12-column geometry at multiple widths, 363 cell sizes, clamps, 330 collision cases, holes, legacy migration and strict validation');
