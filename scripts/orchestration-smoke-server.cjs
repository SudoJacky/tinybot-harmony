// Deterministic model fixture. Uses real app tool execution; does not contact a model service.
const http = require('node:http'), fs = require('node:fs'), path = require('node:path');
const reportPath = path.resolve('.cache/orchestration-device-report.json');
const report = fs.existsSync(reportPath) ? JSON.parse(fs.readFileSync(reportPath, 'utf8')) : { cases: {}, errors: [] };
const save = () => fs.writeFileSync(reportPath, JSON.stringify(report, null, 2));
const scripts = {
  helpers: `await tools.write_file({path:'helpers-a.json',content:'[10,11]'});
await tools.write_file({path:'helpers-b.json',content:'[9,12]'});
const jobs=new Map(['helpers-a.json','helpers-b.json','helpers-missing.json'].map(path=>[path,tools.read_file({path})]));
let total=0; const failures=[];
await stream_settled(jobs, r=>{if(r.status==='fulfilled') total+=JSON.parse(r.value.content).reduce((a,b)=>a+b,0); else failures.push({path:r.index,error:String(r.reason)});});
const values=[]; for await(const r of as_settled([Promise.resolve(42)])) values.push(r.value);
text({total,failed:failures.length}); return {total,failures,values};`,
  normal: `await tools.write_file({path:'orchestration-a.json',content:'[1,2]'});
await tools.write_file({path:'orchestration-b.json',content:'[3,4]'});
const rows=await Promise.all(['orchestration-a.json','orchestration-b.json'].map(path=>tools.read_file({path})));
const total=rows.flatMap(r=>JSON.parse(r.content)).reduce((a,b)=>a+b,0);
await tools.write_file({path:'orchestration-result.json',content:JSON.stringify({total})});
const saved=await tools.read_file({path:'orchestration-result.json'});
return {total,verified:JSON.parse(saved.content).total===total};`,
  partial: `const r=await Promise.allSettled([tools.read_file({path:'orchestration-result.json'}),tools.read_file({path:'orchestration-missing.json'})]); return r.map(x=>x.status);`,
  timeout: 'await Promise.resolve(); while(true) {}',
  recovery: "return JSON.parse((await tools.read_file({path:'orchestration-result.json'})).content);",
  cancel: "await tools.write_file({path:'orchestration-before-stop.txt',content:'committed'}); await tools.read_web({url:'http://127.0.0.1:18769/slow'}); await tools.write_file({path:'orchestration-after-stop.txt',content:'must-not-exist'}); return true;",
  verify_cancel: "const before=await tools.read_file({path:'orchestration-before-stop.txt'}); const files=await tools.list_files({path:'.'}); return {before:before.content,afterExists:files.entries.some(x=>x.name==='orchestration-after-stop.txt')};"
};
function respond(res, content, calls = []) {
  res.writeHead(200, { 'content-type': 'text/event-stream' });
  const frame = data => res.write('data: ' + JSON.stringify(data) + '\n\n');
  frame({ choices: [{ index: 0, delta: { content, ...(calls.length ? { tool_calls: calls.map((c, index) => ({ ...c, index })) } : {}) } }] });
  frame({ choices: [{ index: 0, delta: {}, finish_reason: calls.length ? 'tool_calls' : 'stop' }], usage: { prompt_tokens: 1000, completion_tokens: 100 } });
  res.end('data: [DONE]\n\n');
}
http.createServer(async (req,res)=>{
  try {
    if (req.url === '/slow') { report.slowStarted = true; save(); const timer=setTimeout(()=>res.end('slow tool completed'),30000); req.on('close',()=>clearTimeout(timer)); return; }
    if (req.url.endsWith('/models')) { res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({data:[{id:'orchestration-smoke'}]}));return; }
    let body='';for await (const part of req) body+=part;
    const request=JSON.parse(body), messages=request.messages||[];
    if (!request.tools?.some(t=>t.function?.name==='orchestrate')) {
      const instructions=messages.filter(m=>m.role==='system').map(m=>m.content).join('\n');
      respond(res, /标题|title/i.test(instructions)?'Orchestration verification':'[]');return;
    }
    const prompt=messages.filter(m=>m.role==='user').at(-1)?.content||'';
    const mode=Object.keys(scripts).find(key=>prompt.includes('ORCH_'+key.toUpperCase()))||'normal';
    const last=messages.at(-1);
    if(last?.role==='tool') {
      const output=JSON.parse(last.content);
      const passed = mode==='timeout' ? output.status==='timeout' : output.status==='ok' && (
        mode==='helpers' ? output.result?.total===42 && output.result?.failures?.length===1 && output.result.failures[0].path==='helpers-missing.json' && output.result.failures[0].error.length>0 && output.result.values[0]===42 && output.stdout==='{"total":42,"failed":1}\n' :
        mode==='normal' ? output.result?.total===10 && output.result?.verified===true :
        mode==='partial' ? JSON.stringify(output.result)==='["fulfilled","rejected"]' :
        mode==='recovery' ? output.result?.total===10 :
        mode==='verify_cancel' ? output.result?.before==='committed' && output.result?.afterExists===false : false);
      report.cases[mode]={passed,output};save();
      respond(res,(passed?'PASS':'FAIL')+' ORCH_'+mode.toUpperCase()+'\n'+JSON.stringify(output.result||output.error));return;
    }
    report.cases[mode]={started:true};save();
    respond(res,'正在验证工具编排。',[{id:'orch_'+mode+'_'+Date.now(),type:'function',function:{name:'orchestrate',arguments:JSON.stringify({code:scripts[mode]})}}]);
  } catch(error) { report.errors.push(error.message);save();if(!res.headersSent)res.writeHead(500);res.end(JSON.stringify({error:{message:error.message}})); }
}).listen(18769,'127.0.0.1',()=>{save();console.log('Orchestration fixture ready on 18769');});
