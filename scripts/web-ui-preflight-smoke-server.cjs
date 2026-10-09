// Deterministic device integration: large QuickJS invocation, broken Three.js, then repair.
// Run locally and forward emulator port 18767; select this provider only in a test chat.
const http=require('node:http'),fs=require('node:fs');
const good=JSON.parse(fs.readFileSync('entry/src/main/resources/rawfile/interactive-web/example.json','utf8')).content;
const bad=good.split('\n').map(line=>{
 if(!line.startsWith('{'))return line;
 const record=JSON.parse(line);
 if(record.node?.kind==='web'){const spec=JSON.parse(record.node.data);spec.js='new THREE.OrbitControls();\n'+spec.js;record.node.data=JSON.stringify(spec);}
 return JSON.stringify(record);
}).join('\n');
const fallback=JSON.parse(fs.readFileSync('entry/src/main/resources/rawfile/interactive-web/example-2d.json','utf8')).content;
const report={largeInvocation:false,constructorDiagnostic:false,capabilityDiagnostic:false,repaired:false};
const code='/*'+'x'.repeat(128*1024)+'*/return {length:input.length, payload:"x".repeat(65536)};';
const call={index:0,id:'large_code',type:'function',function:{name:'execute_code',arguments:JSON.stringify({code,input:JSON.stringify('中'.repeat(40000))})}};
http.createServer(async(req,res)=>{
 if(req.url==='/v1/models'){res.setHeader('Content-Type','application/json');res.end(JSON.stringify({data:[{id:'web-preflight-smoke'}]}));return;}
 if(req.url!=='/v1/chat/completions'){res.writeHead(404);res.end();return;}
 try{
  let raw='';for await(const chunk of req)raw+=chunk;const body=JSON.parse(raw);
  const auxiliary=!(body.tools||[]).length;
  const messages=body.messages.slice(body.messages.findLastIndex(m=>m.role==='user'&&typeof m.content==='string'&&!m.content.startsWith('Client UI validation failed')));
  const result=messages.find(m=>m.role==='tool'&&m.tool_call_id==='large_code');
  const feedback=messages.findLast(m=>m.role==='user'&&typeof m.content==='string'&&m.content.startsWith('Client UI validation failed'));
  let content='',tool;
  if(auxiliary)content=body.messages.some(m=>m.role==='system'&&typeof m.content==='string'&&m.content.includes('记忆'))?'[]':'Preflight verification';
  else if(!result)tool=call;
  else{
   const output=JSON.parse(result.content);report.largeInvocation=output.status==='ok'&&output.result.length===40000&&output.result.payload.length===65536;
   if(!report.largeInvocation)throw Error('Large QuickJS invocation failed: '+output.status);
   if(feedback){
    if(feedback.content.includes('THREE.OrbitControls')&&feedback.content.includes('node=')){
     report.constructorDiagnostic=true;content=good;
    }else if(feedback.content.includes('WebGL 2')&&report.constructorDiagnostic){
     report.capabilityDiagnostic=true;content=fallback;
    }else throw Error('Unexpected preflight failure: '+feedback.content);
    report.repaired=true;
   }else content=bad;
   fs.writeFileSync('.hvigor/preflight-device-report.json',JSON.stringify(report,null,2));
   console.log(JSON.stringify(report));
  }
  res.writeHead(200,{'Content-Type':'text/event-stream','Cache-Control':'no-cache'});
  const emit=delta=>res.write('data: '+JSON.stringify({choices:[{index:0,delta,finish_reason:null}]})+'\n\n');
  if(tool){
   emit({tool_calls:[{...tool,function:{name:tool.function.name,arguments:''}}]});
   for(let i=0;i<tool.function.arguments.length;i+=4096)emit({tool_calls:[{index:0,function:{arguments:tool.function.arguments.slice(i,i+4096)}}]});
  }else for(let i=0;i<content.length;i+=1024)emit({content:content.slice(i,i+1024)});
  res.end('data: '+JSON.stringify({choices:[{index:0,delta:{},finish_reason:tool?'tool_calls':'stop'}]})+'\n\ndata: [DONE]\n\n');
 }catch(error){console.error(error.message);if(!res.headersSent)res.writeHead(500);res.end(error.message);}
}).listen(18767,'127.0.0.1',()=>console.log('Preflight smoke provider: http://127.0.0.1:18767/v1'));
