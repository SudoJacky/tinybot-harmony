// Manual emulator integration: forward port 18768 and configure a temporary Chat Completions provider
// with no API key and a context window of at least 32768. Send a fresh test message.
// By default, the agent requests human handoff. For automatic takeover with a model request in flight,
// GET /arm before the run, click the page's user button, GET /release, then explicitly hand it back.
// The report must remain at 2 requests before handoff, then finish at 4 with both counters exactly 1.
const http = require('node:http'), fs = require('node:fs');
fs.mkdirSync('.cache', { recursive: true });
const report = { requests: 0, opened: false, handedBack: false, acted: false };
let armed = false, release;
const html = `<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><title>Tinybot Browser Smoke</title><style>body{font:24px sans-serif;padding:20px}button{display:block;font:24px sans-serif;padding:24px;margin:30px 0}</style><h1>Browser live page</h1><button id="human" onclick="document.getElementById('human-result').textContent='Human count: '+(++window.human)">User control test</button><p id="human-result">Human count: 0</p><button id="agent" onclick="document.getElementById('agent-result').textContent='Agent count: '+(++window.agent)">Agent control test</button><p id="agent-result">Agent count: 0</p><script>window.human=0;window.agent=0</script>`;
http.createServer(async (req, res) => {
  if(req.url==='/arm'){armed=true;res.end('armed');return;}
  if(req.url==='/release'){release?.();res.end('released');return;}
  if(req.url==='/page'){res.writeHead(200,{'Content-Type':'text/html'});res.end(html);return;}
  if(req.url==='/v1/models'){res.setHeader('Content-Type','application/json');res.end(JSON.stringify({data:[{id:'browser-device-smoke'}]}));return;}
  if(req.url!=='/v1/chat/completions'){res.writeHead(404);res.end();return;}
  try {
    let raw='';for await(const data of req)raw+=data;const body=JSON.parse(raw);
    let content='', tool;
    const start = body.messages.findLastIndex(m=>m.role==='user');
    const receipts = body.messages.slice(start+1).filter(m=>m.role==='tool');
    const last=receipts.at(-1);
    if(!body.tools?.length) content='Browser smoke';
    else {
      if(!last){report.requests=0;report.opened=false;report.handedBack=false;report.acted=false;}
      report.requests++;
      if(!last)tool={name:'browser_open',arguments:{url:'http://127.0.0.1:18768/page',reason:'Verify the live embedded browser and human handoff.'}};
      else if(last.tool_call_id==='open') {
        const result=JSON.parse(last.content);if(!result.page?.text.includes('Browser live page'))throw Error(last.content);
        report.opened=true;
        if(armed){
          armed=false;fs.writeFileSync('.cache/browser-device-report.json',JSON.stringify(report,null,2));
          await new Promise(resolve=>{release=resolve});release=undefined;
          tool={name:'browser_snapshot',arguments:{}};
        }else tool={name:'browser_handoff',arguments:{reason:'Click User control test once, then hand back to Tinybot.'}};
      } else if(last.tool_call_id==='handoff'||last.tool_call_id==='snapshot') {
        const result=JSON.parse(last.content);if(!result.page?.text.includes('Human count: 1'))throw Error('Human action was lost: '+last.content);
        report.handedBack=true;const element=result.page.elements.find(e=>e.label==='Agent control test');
        tool={name:'browser_action',arguments:{action:'click',snapshotId:result.page.snapshotId,elementId:element.id}};
      } else if(last.tool_call_id==='action') {
        const result=JSON.parse(last.content);if(!result.page?.text.includes('Agent count: 1'))throw Error('Agent click failed: '+last.content);
        report.acted=true;content='Browser device smoke passed. Human count: 1; Agent count: 1.';
      } else throw Error('Unexpected tool result '+last.tool_call_id);
      fs.writeFileSync('.cache/browser-device-report.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report));
    }
    res.writeHead(200,{'Content-Type':'text/event-stream'});
    const delta=tool?{tool_calls:[{index:0,id:tool.name==='browser_open'?'open':tool.name==='browser_handoff'?'handoff':tool.name==='browser_snapshot'?'snapshot':'action',type:'function',function:{name:tool.name,arguments:JSON.stringify(tool.arguments)}}]}:{content};
    res.write('data: '+JSON.stringify({choices:[{index:0,delta,finish_reason:null}]})+'\n\n');
    res.end('data: '+JSON.stringify({choices:[{index:0,delta:{},finish_reason:tool?'tool_calls':'stop'}]})+'\n\ndata: [DONE]\n\n');
  }catch(e){console.error(e.message);if(!res.headersSent)res.writeHead(500);res.end(e.message);}
}).listen(18768,'127.0.0.1',()=>console.log('Browser device test server on 18768'));
