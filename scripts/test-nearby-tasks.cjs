const assert = require('node:assert/strict'), crypto = require('node:crypto');
const { fixture, from, until, thread } = require('./test-parallel-sessions.cjs');
const { ToolApproval } = from('services/ToolApproval');
const { Cancellation } = from('services/Cancellation');
const NearbyConversations = from('services/NearbyConversations').nearbyConversations.constructor;
let linkId = 0;
function pair(a, b) {
  let closed = false, aTail = Promise.resolve(), bTail = Promise.resolve();
  const close = () => { if (closed) return; closed = true; a.sync.closed(aLink); b.sync.closed(bLink); };
  const aLink = { id: ++linkId, deviceId: b.name, close, send(text) {
    if (closed) return Promise.reject(Error('Disconnected'));
    return aTail = aTail.then(() => b.sync.receive(bLink, text));
  } };
  const bLink = { id: ++linkId, deviceId: a.name, close, send(text) {
    if (closed) return Promise.reject(Error('Disconnected'));
    return bTail = bTail.then(() => a.sync.receive(aLink, text));
  } };
  const peer = a.sync.attach(aLink), reverse = b.sync.attach(bLink);
  a.sync.identify(peer, b.origin); b.sync.identify(reverse, a.origin);
  return { close, peer, reverse };
}
async function main() {
  const devices = [];
  for (const name of ['phone', 'tablet', 'observer']) {
    const approval = new ToolApproval(), f = await fixture(undefined, approval);
    devices.push({ ...f, approval, name, origin: crypto.randomUUID(), sync: new NearbyConversations() });
  }
  const [phone, tablet, observer] = devices, records = new Map();
  const database = { read: async (scope, id) => records.get(scope + id), commit: async changes => {
    for (const change of changes) {
      if (change.text === undefined) records.delete(change.scope + change.id);
      else records.set(change.scope + change.id, change.text);
    }
  } };
  for (const device of devices) device.sync.start({}, device.session, device.origin, () => device.name,
    () => devices.filter(d => d !== device).map(d => ({ id: d.name, name: d.name })), database);
  const link = pair(phone, tablet), watchLink = pair(observer, tablet);
  // The observer never submits a prompt, and the executor's unrelated draft must stay selected.
  tablet.session.setDraft('Unrelated work');
  try {
    await phone.sync.submit('tablet', '', '', 'a', 'Task');
    await until(() => tablet.requests.length === 1);
    const id = phone.app.active.peerThreadId;
    assert.equal(tablet.app.active.id, 'a');
    const catalog = await observer.sync.call(watchLink.peer, { kind: 'catalog' });
    assert.ok(catalog.threads.includes(id));
    await observer.sync.watch(watchLink.peer, id);
    await until(() => observer.session.peerThreadId(tablet.origin, id));
    await observer.app.selectThread(observer.session.peerThreadId(tablet.origin, id));
    tablet.requests[0].text('Shared output');
    await until(() => observer.app.active.messages.at(-1)?.content === 'Shared output', 500);
    await until(() => phone.app.peerTask?.task?.running);
    assert.equal(observer.requests.length, 0);
    console.log('PASS a third device subscribes without submitting, and executor navigation preserves current work');

    const approval = tablet.approval.scoped(id);
    const pending = approval.request('Write document', 'report.txt', new Cancellation());
    await until(() => phone.app.peerTask?.task?.approval && observer.app.peerTask?.task?.approval);
    const prompt = observer.app.peerTask.task;
    await observer.sync.control(tablet.origin, id, { action: 'approve', runId: prompt.runId,
      approvalId: prompt.approval.id, allowed: true });
    await pending;
    await assert.rejects(phone.sync.control(tablet.origin, id, { action: 'approve', runId: prompt.runId,
      approvalId: prompt.approval.id, allowed: false }), /其他设备处理/);
    console.log('PASS approvals bind to a task and resolve once across competing controllers');

    const form = approval.ask({ title: 'Details', fields: [{ name: 'name', label: 'Name', type: 'text', required: true }] }, new Cancellation());
    await until(() => phone.app.peerTask?.task?.approval?.form);
    const asking = phone.app.peerTask.task;
    await assert.rejects(phone.sync.control(tablet.origin, id, { action: 'form', runId: asking.runId,
      approvalId: asking.approval.id, allowed: true, values: [''] }));
    assert.ok(tablet.approval.form);
    await phone.sync.control(tablet.origin, id, { action: 'form', runId: asking.runId,
      approvalId: asking.approval.id, allowed: true, values: ['Ada'] });
    assert.equal(JSON.parse(await form).status, 'submitted');
    console.log('PASS remote forms validate on the executor and continue the waiting task');

    await phone.sync.submit('', tablet.origin, id, phone.app.active.id, 'Follow up');
    await until(() => observer.app.peerTask?.task?.pendingInputs.length === 1);
    const beforeStop = observer.app.peerTask.task;
    await observer.sync.control(tablet.origin, id, { action: 'stop', runId: beforeStop.runId });
    await tablet.session.waitForIdle();
    await until(() => phone.app.peerTask?.task?.queuePaused && !phone.app.peerTask.task.running);
    assert.equal(thread(tablet, id).messages.at(-1).status, 'stopped');
    await phone.sync.control(tablet.origin, id, { action: 'resume', runId: beforeStop.runId,
      inputId: phone.app.peerTask.task.pendingInputs[0].id });
    await until(() => tablet.requests.length === 2);
    await assert.rejects(observer.sync.control(tablet.origin, id, { action: 'stop', runId: beforeStop.runId }), /下一轮/);
    console.log('PASS remote stop/resume preserves queued work and stale controls cannot stop a new turn');

    link.close();
    assert.equal(phone.app.peerTask.connected, false);
    const dialed = [], open = phone.sync.open;
    phone.sync.open = async deviceId => {
      dialed.push(deviceId);
      return pair(phone, devices.find(device => device.name === deviceId)).peer;
    };
    await phone.sync.observeConnectedPeers();
    await assert.rejects(phone.sync.models('', tablet.origin), /手动连接/);
    await assert.rejects(phone.sync.submit('', tablet.origin, id, phone.app.active.id, 'Offline'), /手动连接/);
    assert.deepEqual(dialed, [], 'Passive polling and disconnected task operations cannot launch another device');
    await assert.rejects(phone.sync.reconnect('observer', tablet.origin, id), /不是此会话的执行端/);
    assert.equal(phone.sync.connected('observer'), undefined, 'Close a newly opened link to the wrong executor');
    await phone.sync.reconnect('tablet', tablet.origin, id);
    assert.deepEqual(dialed, ['observer', 'tablet'], 'Only explicitly selected devices are dialed');
    phone.sync.open = open;
    await phone.sync.observeConnectedPeers();
    tablet.requests[1].text('After reconnect');
    await until(() => phone.app.peerTask?.connected && phone.app.active.messages.at(-1)?.content === 'After reconnect', 500);
    tablet.requests[1].finish('Finished');
    await tablet.session.waitForIdle();
    await until(() => observer.app.active.messages.at(-1)?.status === 'complete');
    assert.equal(tablet.requests.length, 2);
    console.log('PASS passive checks never dial, and an explicitly selected executor resumes observation without replaying work');

    // Lose acknowledgement after durable admission. Recreate only the sender transport.
    const originalCall = phone.sync.call.bind(phone.sync);
    let lost = true;
    phone.sync.call = async (peer, packet) => {
      const reply = await originalCall(peer, packet);
      if (lost && packet.kind === 'command') { lost = false; throw Error('Lost acknowledgement'); }
      return reply;
    };
    const source = phone.app.active.id;
    await assert.rejects(phone.sync.submit('', tablet.origin, id, source, 'Once only'), /Lost acknowledgement/);
    await until(() => tablet.requests.length === 3);
    assert.equal(records.size, 1);
    phone.sync.stop(); phone.sync = new NearbyConversations();
    phone.sync.start({}, phone.session, phone.origin, () => 'phone', () => [{ id: 'tablet', name: 'tablet' }], database);
    pair(phone, tablet);
    await phone.sync.submit('', tablet.origin, id, source, 'Once only');
    assert.equal(tablet.requests.length, 3);
    assert.equal(thread(tablet, id).pendingInputs.length, 0);
    assert.equal(records.size, 0);
    tablet.requests[2].finish('Exactly once'); await tablet.session.waitForIdle();
    console.log('PASS sender restart reuses durable request identity after lost acknowledgement');

    const ids=[];
    await Promise.all([0,1].map(()=>phone.sync.submit('',tablet.origin,id,source,'Concurrent delivery',requestId=>ids.push(requestId))));
    await until(()=>tablet.requests.length===4);assert.equal(new Set(ids).size,1);
    assert.equal(thread(tablet,id).messages.filter(message=>message.content==='Concurrent delivery').length,1);
    let withdrawn='';
    await phone.sync.submit('',tablet.origin,id,source,'Withdrawn message',requestId=>{withdrawn=requestId;});
    await observer.sync.control(tablet.origin,id,{action:'remove-input',runId:tablet.session.taskState(id).runId,inputId:withdrawn});
    const reply=await phone.sync.call([...phone.sync.peers.values()][0],{kind:'command',origin:tablet.origin,threadId:id,
      requestId:withdrawn,create:false,text:'Withdrawn message'});
    assert.equal(reply.error,undefined);assert.equal(thread(tablet,id).pendingInputs.length,0);
    assert.ok(thread(tablet,id,true).peerInputReceipts.includes(withdrawn));
    console.log('PASS concurrent submissions share one request and retries cannot revive a withdrawn command');

    const attachment={id:'image',name:'photo.jpg',mime:'image/jpeg',path:'image.jpg',size:3};
    const reference={threadId:'a',title:'Reference',content:'Reference snapshot',capturedAt:1,truncated:false};
    let releaseTransfer,receiving=false;
    const transferGate=new Promise(resolve=>{releaseTransfer=resolve;});
    phone.sync.attachments={stage:async(_origin,items)=>items.map(attachment=>({attachment,digest:'test-digest'}))};
    tablet.sync.attachments={receive:async(_device,_origin,items)=>{receiving=true;await transferGate;return items.map(item=>item.attachment);}};
    assert.equal(await phone.app.setAttachments([attachment]),true);
    await phone.session.referenceThread('a').then(ok=>assert.equal(ok,false,'Empty chats cannot be referenced'));
    phone.session.setDraft('Look at this');
    let delivered=false;
    const sending=phone.app.send(()=>{},text=>phone.sync.submit('',tablet.origin,id,source,text,undefined,'followUp',
      {attachments:phone.app.active.attachments,references:[reference]})).then(()=>{delivered=true;});
    await until(()=>receiving);assert.equal(delivered,false);assert.equal(thread(tablet,id).pendingInputs.length,0);
    assert.equal(phone.app.active.attachments.length,1);releaseTransfer();await sending;
    assert.equal(phone.app.active.attachments.length,0);assert.equal(thread(tablet,id).pendingInputs[0].attachments[0].name,'photo.jpg');
    tablet.requests[3].finish('First done');await until(()=>tablet.requests.length===5);
    assert.equal(thread(tablet,id).messages.at(-2).references[0].content,'Reference snapshot');
    assert.ok(tablet.requests[4].request.messages.some(message=>message.content.includes('Reference snapshot')));
    await until(()=>tablet.session.taskState(id).acceptingSteering);
    let steeringId='';
    await phone.sync.submit('',tablet.origin,id,source,'Adjust the current answer',value=>{steeringId=value;},'steer');
    const messagesBeforeSteering=thread(tablet,id).messages.length;
    tablet.requests[4].finish('Before steering');await until(()=>tablet.requests.length===6);
    assert.equal(thread(tablet,id).messages.length,messagesBeforeSteering,'Steering continues the same turn');
    assert.ok(thread(tablet,id).messages.at(-1).steps.some(step=>step.steering?.id===steeringId));
    tablet.requests[5].finish('Attachment done');await tablet.session.waitForIdle();
    await phone.sync.call([...phone.sync.peers.values()][0],{kind:'command',origin:tablet.origin,threadId:id,
      requestId:steeringId,create:false,text:'Adjust the current answer',mode:'steer'});
    assert.equal(tablet.requests.length,6);assert.equal(thread(tablet,id).pendingInputs.length,0);
    console.log('PASS attachments reach the executor before admission, references enter context, and only accepted drafts clear');
    console.log('PASS steering enters the current turn and retries cannot replay a consumed input');

    await assert.rejects(tablet.session.acceptPeerInput(crypto.randomUUID(),'remote-'+crypto.randomUUID(),'Project task',true,()=>true,
      'followUp',{projectId:'missing'}),/项目尚未同步/);
    assert.equal(await tablet.session.saveProject('Shared project','Project instructions'),true);
    const project=tablet.session.snapshot().projects[0],projectChat=crypto.randomUUID();
    await tablet.session.acceptPeerInput(projectChat,'remote-'+crypto.randomUUID(),'Project task',true,()=>true,'followUp',
      {projectId:project.id,modelRef:{providerId:'test',modelId:'model-b'}});
    await until(()=>tablet.requests.length===7);
    assert.equal(thread(tablet,projectChat).projectId,project.id);assert.equal(tablet.requests[6].request.model,'model-b');
    tablet.requests[6].finish('Project done');await tablet.session.waitForIdle();
    const models=await phone.sync.models('tablet','');assert.ok(models.some(choice=>choice.modelId==='model-b'));
    await phone.sync.control(tablet.origin,projectChat,{action:'model',runId:tablet.session.taskState(projectChat).runId,
      modelRef:{providerId:'test',modelId:'model-a'}});
    assert.equal(thread(tablet,projectChat).modelRef.modelId,'model-a');
    console.log('PASS project admission validates executor context and uses an explicitly selected available model');
  } finally {
    for (const device of devices) device.sync.stop();
    await tablet.session.stopAll(); await tablet.session.waitForIdle();
  }
}
const watchdog = setTimeout(() => { throw Error('Nearby task tests timed out'); }, 30000);
main().catch(error => { console.error(error); process.exitCode = 1; }).finally(() => clearTimeout(watchdog));
