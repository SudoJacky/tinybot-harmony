// Local OpenAI-compatible smoke provider. Run: node scripts/interactive-ui-smoke-server.cjs
// Forward emulator localhost:18766 to this host port using hdc rport before connecting.
const http = require('node:http');
const { content } = require('./interactive-ui-fixture.cjs');
const server = http.createServer(async (req, res) => {
  if (req.url === '/v1/models') { res.writeHead(200, {'Content-Type':'application/json'}); res.end(JSON.stringify({data:[{id:'interactive-ui-smoke'}]})); return; }
  if (req.url !== '/v1/chat/completions' || req.method !== 'POST') { res.writeHead(404); res.end(); return; }
  let raw='';
  try {
    for await (const chunk of req) { raw += chunk; if (raw.length>1024*1024) throw Error('Request too large'); }
    const body=JSON.parse(raw);
    const latest=body.messages.filter(m=>m.role==='user').at(-1)?.content || '';
    const system=body.messages.find(m=>m.role==='system')?.content || '';
    const auxiliary=!(body.tools || []).length;
    const response=auxiliary && system.includes('记忆') ? '[]' : auxiliary && system.includes('标题') ? 'Interactive UI smoke test' : latest.includes('用户点击了交互界面') ? '已收到你在界面中提交的当前输入。此回执来自本地固定测试服务。' : content;
    res.writeHead(200,{'Content-Type':'text/event-stream','Cache-Control':'no-cache'});
    for(let index=0;index<response.length;index+=96) {
      if(res.destroyed) return;
      res.write('data: '+JSON.stringify({choices:[{index:0,delta:{content:response.slice(index,index+96)},finish_reason:null}]})+'\n\n');
      await new Promise(resolve=>setTimeout(resolve,35));
    }
    res.end('data: '+JSON.stringify({choices:[{index:0,delta:{},finish_reason:'stop'}]})+'\n\ndata: [DONE]\n\n');
  } catch(error) { if(!res.headersSent)res.writeHead(400);res.end(error.message); }
});
server.listen(18766,'127.0.0.1',()=>console.log('Interactive UI smoke provider: http://127.0.0.1:18766/v1'));
