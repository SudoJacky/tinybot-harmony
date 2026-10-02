// Deterministic local model for emulator verification; no credentials or external model calls.
// Run: node scripts/team-smoke-server.cjs
const http = require('node:http');
const plan = { tasks: [
  { id: 'research', title: '整理事实', memberId: 'researcher', instructions: '写入 research.md，列出两条已确认事实。', dependencies: [] },
  { id: 'analysis', title: '分析方案', memberId: 'analyst', instructions: '写入 analysis.md，比较两个方案。', dependencies: [] },
  { id: 'report', title: '汇总报告', memberId: 'editor', instructions: '根据前置结果写入 report.md。', dependencies: ['research', 'analysis'] }
], finalTaskId: 'report' };
http.createServer(async (req, res) => {
  if (req.url === '/v1/models') { res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ data: [{ id: 'team-smoke' }] })); return; }
  let raw = ''; for await (const chunk of req) raw += chunk;
  try {
    const body = JSON.parse(raw); const planner = body.messages[0].content.includes('为团队生成依赖计划');
    const task = planner ? undefined : JSON.parse(body.messages.find(m => m.role === 'user').content).task;
    const hasReceipt = body.messages.some(m => m.role === 'tool');
    console.log(JSON.stringify({ planner, task: task?.id, hasReceipt }));
    res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache' });
    const event = (delta, finish_reason = null) => res.write('data: ' + JSON.stringify({ choices: [{ index: 0, delta, finish_reason }] }) + '\n\n');
    await new Promise(resolve => setTimeout(resolve, planner ? 500 : 2500));
    if (planner) { event({ content: JSON.stringify(plan) }); event({}, 'stop'); }
    else if (!hasReceipt) {
      event({ tool_calls: [{ index: 0, id: 'call_' + task.id, type: 'function', function: { name: 'write_file', arguments: JSON.stringify({ path: task.id + '.md', content: '# ' + task.title + '\n\n这是本地模拟服务生成的团队验证产物。\n' }) } }] });
      event({}, 'tool_calls');
    } else { event({ content: '## ' + task.title + '\n\n已完成分配任务。\n\n产物：`' + task.id + '.md`\n\n未解决问题：此为本地模拟服务测试，未调用真实模型。' }); event({}, 'stop'); }
    res.write('data: ' + JSON.stringify({ choices: [], usage: { prompt_tokens: 120, completion_tokens: 80 } }) + '\n\n');
    res.end('data: [DONE]\n\n');
  } catch (error) { res.writeHead(400); res.end(error.message); }
}).listen(18765, '127.0.0.1', () => console.log('Team smoke model: http://127.0.0.1:18765/v1'));
