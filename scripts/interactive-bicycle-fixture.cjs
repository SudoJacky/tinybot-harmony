// Procedural teaching model, not a mechanically complete bicycle or a model-quality benchmark.
function bicycle() {
  const $ = id => document.getElementById(id);
  const stage = $('stage'), canvas = document.createElement('canvas');
  if (!canvas.getContext('webgl2')) throw Error('自行车示例需要 WebGL2，当前设备未提供。');
  stage.append(canvas);
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: false });
  renderer.setPixelRatio(Math.min(devicePixelRatio, 1.5));
  renderer.setClearColor(0xf1f5f3);
  const scene = new THREE.Scene(), camera = new THREE.PerspectiveCamera(40, 1, 0.1, 50);
  const controls = new OrbitControls(camera, canvas);
  controls.target.set(0, 1.05, 0); controls.enablePan = false;
  controls.minDistance = 3.8; controls.maxDistance = 10;
  camera.position.set(2.9, 2.1, 6.7); controls.update();
  scene.add(new THREE.HemisphereLight(0xffffff, 0x63756a, 2.7));
  const light = new THREE.DirectionalLight(0xffffff, 3); light.position.set(-3, 5, 5); scene.add(light);
  const colors = { frame: 0x228a70, front: 0x343f3a, rear: 0x343f3a, fork: 0x7f9caa, handle: 0x394e59, saddle: 0x795c48, crank: 0xca944a, chain: 0x718178 };
  const info = {
    frame: ['车架', '连接前后轮与各组件，承受骑行载荷。这里用三角形管架展示基本结构。'],
    front: ['前轮', '轮胎接触地面；轮圈、辐条和花鼓共同支撑车轮。前轮随前叉转向。'],
    rear: ['后轮', '承受部分骑行载荷，并从传动系统获得驱动力。这里省略飞轮与变速机构。'],
    fork: ['前叉', '连接前轮与车架头管，让前轮可以随车把转向。'],
    handle: ['车把', '通过把立连接转向机构，供骑行者控制方向。'],
    saddle: ['车座', '通过座管连接车架，支撑骑行者并调节坐姿。'],
    crank: ['曲柄与脚踏', '将脚踏力转成绕中轴旋转的力矩，再传给牙盘与链条。'],
    chain: ['链条', '将牙盘的转动传给后轮传动机构。此处用简化闭环表示传动路径。']
  };
  const shifts = { frame: [0,0,0], front: [0.65,0,0.25], rear: [-0.65,0,-0.25], fork: [0.45,0.25,0.65], handle: [0.15,0.8,0], saddle: [-0.2,0.8,0], crank: [0,-0.1,0.85], chain: [0,-0.45,-0.7] };
  const parts = {}, pickable = [];
  for (const id of Object.keys(info)) {
    const group = new THREE.Group(); group.userData.part = id; scene.add(group); parts[id] = group;
  }
  function mesh(id, geometry, color = colors[id]) {
    const material = new THREE.MeshStandardMaterial({ color, metalness: 0.3, roughness: 0.55 });
    const object = new THREE.Mesh(geometry, material); object.userData.part = id;
    parts[id].add(object); pickable.push(object); return object;
  }
  function tube(id, a, b, radius = 0.035, color) {
    const start = new THREE.Vector3(...a), end = new THREE.Vector3(...b), delta = end.clone().sub(start);
    const object = mesh(id, new THREE.CylinderGeometry(radius, radius, delta.length(), 12), color);
    object.position.copy(start.add(end).multiplyScalar(0.5));
    object.quaternion.setFromUnitVectors(new THREE.Vector3(0,1,0), delta.normalize()); return object;
  }
  function wheel(id, x) {
    const tire = mesh(id, new THREE.TorusGeometry(0.59, 0.042, 10, 56)); tire.position.set(x,0.65,0);
    const rim = mesh(id, new THREE.TorusGeometry(0.535, 0.014, 6, 56), 0xc4cfca); rim.position.copy(tire.position);
    tube(id, [x,0.65,-0.11], [x,0.65,0.11], 0.055, 0x81928b);
    for (let i=0;i<16;i++) { const angle=i*Math.PI/8; tube(id,[x,0.65,0],[x+Math.cos(angle)*0.53,0.65+Math.sin(angle)*0.53,0],0.006,0x9faea6); }
  }
  wheel('rear',-1.12); wheel('front',1.12);
  const rear=[-1.12,0.65,0], bb=[-0.3,0.5,0], seat=[-0.55,1.5,0], head=[0.64,1.48,0], neck=[0.74,1.22,0];
  for(const [a,b] of [[rear,bb],[bb,seat],[seat,rear],[seat,head],[head,neck],[neck,bb]]) tube('frame',a,b,0.043);
  for(const z of [-0.085,0.085]) tube('fork',[0.69,1.37,z],[1.12,0.65,z],0.026);
  tube('handle',[0.64,1.48,0],[0.58,1.75,0],0.028);
  tube('handle',[0.58,1.75,0],[0.78,1.8,0],0.028);
  tube('handle',[0.78,1.8,-0.38],[0.78,1.8,0.38],0.026);
  tube('saddle',seat,[-0.59,1.8,0],0.025);
  const saddle=mesh('saddle',new THREE.BoxGeometry(0.43,0.07,0.24)); saddle.position.set(-0.62,1.83,0);
  const gear=mesh('crank',new THREE.TorusGeometry(0.17,0.021,8,32)); gear.position.set(-0.3,0.5,0.1);
  tube('crank',[-0.3,0.5,-0.17],[-0.3,0.5,0.17],0.045);
  tube('crank',[-0.3,0.5,0.17],[-0.17,0.27,0.17],0.026);
  tube('crank',[-0.3,0.5,-0.17],[-0.43,0.73,-0.17],0.026);
  for(const [x,y,z] of [[-0.17,0.27,0.24],[-0.43,0.73,-0.24]]) { const pedal=mesh('crank',new THREE.BoxGeometry(0.16,0.05,0.18),0x3c4841);pedal.position.set(x,y,z); }
  tube('chain',[-1.12,0.73,0.12],[-0.3,0.67,0.12],0.011);
  tube('chain',[-1.12,0.57,0.12],[-0.3,0.33,0.12],0.011);
  for(const [x,y,r] of [[-1.12,0.65,0.08],[-0.3,0.5,0.17]]) { const ring=mesh('chain',new THREE.TorusGeometry(r,0.011,6,32));ring.position.set(x,y,0.12); }
  let values = tinybot.state, displayed = values.explode, saving = false, down;
  const render = () => renderer.render(scene,camera);
  function show() {
    $('amount').textContent = '拆解程度：' + Math.round(values.explode*100) + '%';
    $('explode').value = String(values.explode*100);
    $('detail').textContent = info[values.part][0] + ' · ' + info[values.part][1];
    for(const id of Object.keys(parts)) {
      parts[id].children.forEach(object=>{ object.material.emissive.setHex(id===values.part?0x244b39:0); });
      $('part-'+id).setAttribute('aria-pressed',String(id===values.part));
    }
    render();
  }
  function position() { for(const id of Object.keys(parts)) parts[id].position.set(...shifts[id]).multiplyScalar(displayed); }
  async function save(patch) {
    if(saving || !tinybot.active) return;
    saving=true; $('status').textContent='正在保存…';
    try { values=await tinybot.save({...values,...patch}); show(); $('status').textContent='已保存'; }
    catch(error) { values=tinybot.state; show(); $('status').textContent='保存失败：'+error.message; }
    finally { saving=false; }
  }
  for(const id of Object.keys(parts)) {
    const button=document.createElement('button');button.id='part-'+id;button.textContent=info[id][0];button.onclick=()=>save({part:id});$('parts').append(button);
  }
  $('explode').oninput=()=>{ if(saving || !tinybot.active)return; values={...values,explode:Number($('explode').value)/100};show(); };
  $('explode').onchange=()=>save({explode:Number($('explode').value)/100});
  $('open').onclick=()=>save({explode:1}); $('close').onclick=()=>save({explode:0});
  $('view').onclick=()=>{ camera.position.set(2.9,2.1,6.7);controls.target.set(0,1.05,0);controls.update();render(); };
  $('zoom-in').onclick=()=>{ const d=camera.position.clone().sub(controls.target);camera.position.copy(controls.target).add(d.setLength(Math.max(controls.minDistance,d.length()*0.8)));controls.update();render(); };
  $('zoom-out').onclick=()=>{ const d=camera.position.clone().sub(controls.target);camera.position.copy(controls.target).add(d.setLength(Math.min(controls.maxDistance,d.length()*1.25)));controls.update();render(); };
  const raycaster=new THREE.Raycaster();
  canvas.addEventListener('pointerdown',event=>{ down={x:event.clientX,y:event.clientY}; });
  canvas.addEventListener('pointerup',event=>{
    if(!down||Math.hypot(event.clientX-down.x,event.clientY-down.y)>7)return;
    const rect=canvas.getBoundingClientRect();raycaster.setFromCamera(new THREE.Vector2((event.clientX-rect.left)/rect.width*2-1,1-(event.clientY-rect.top)/rect.height*2),camera);
    const hit=raycaster.intersectObjects(pickable,false)[0];if(hit)save({part:hit.object.userData.part});down=undefined;
  });
  canvas.addEventListener('pointercancel',()=>{down=undefined;});
  controls.addEventListener('change',render);
  const resize=new ResizeObserver(()=>{ renderer.setSize(stage.clientWidth,280);camera.aspect=stage.clientWidth/280;camera.updateProjectionMatrix();render(); });resize.observe(stage);
  tinybot.onState(state=>{values=state;show();});
  tinybot.animate((_time,delta)=>{ if(Math.abs(displayed-values.explode)>0.001){ displayed+=(values.explode-displayed)*Math.min(1,delta*10);position();render(); } });
  position();show();
  addEventListener('pagehide',()=>{resize.disconnect();controls.dispose();renderer.dispose();});
}
const state = { explode: 0, part: 'frame' };
const spec = {
  version: 1, library: 'three', height: 760,
  html: '<main><h2>自行车 · 拆开看</h2><p class="hint">拖动旋转 · 双指缩放 · 点选零件</p><div id="stage" aria-label="可旋转的三维自行车"></div><div class="toolbar"><button id="zoom-in">放大</button><button id="zoom-out">缩小</button><button id="view">复位视角</button></div><label id="amount" for="explode"></label><input id="explode" type="range" min="0" max="100" step="1" aria-label="拆解程度"><div class="toolbar"><button id="open">全部拆开</button><button id="close">重新组装</button></div><div id="parts" aria-label="选择零件"></div><p id="detail" aria-live="polite"></p><p id="status" role="status">可操作</p><p class="hint">教学示意模型；省略刹车、变速器等细节。拆开方向不代表实际维修步骤。</p></main>',
  css: 'body{background:#f1f5f3;color:#213b30}main{padding:12px}h2{font-size:20px;margin:0 0 6px}.hint{font-size:12px;color:#53695d;margin:4px 0 10px;line-height:1.5}#stage{height:280px;overflow:hidden;border-radius:12px}button{border:1px solid #c4d3ca;background:#fff;color:#213b30;border-radius:10px;padding:5px 10px;min-height:42px;font-size:13px}.toolbar{display:flex;gap:8px;margin:8px 0}.toolbar button{flex:1}#parts{display:grid;grid-template-columns:repeat(4,1fr);gap:5px;margin:12px 0}#parts button{padding:4px;font-size:12px}button[aria-pressed=true]{background:#225c43;color:white}label{font-size:13px;display:block;margin-top:12px}input{width:100%;height:28px;accent-color:#228a70}#detail{font-size:13px;line-height:1.5;min-height:60px;margin:8px 0}#status{font-size:11px;color:#53695d;margin:6px 0}',
  js: '('+bicycle.toString()+')();'
};
const records = [{op:'begin',version:1,title:'自行车结构探索',state},{op:'node',node:{id:'bicycle',kind:'web',data:JSON.stringify(spec)}},{op:'end'}];
const content = '这是用于验证交互能力的固定教学样例。可以旋转自行车、调整拆解程度，并点选零件查看说明。\n\n```tinybot-ui\n'+records.map(JSON.stringify).join('\n')+'\n```';
module.exports = { spec, state, records, content };
