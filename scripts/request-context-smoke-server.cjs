// Local OpenAI-compatible fixture for device smoke tests. Never forwards requests to a model.
const http = require('node:http'), fs = require('node:fs'), path = require('node:path');
const reportPath = path.resolve('.hvigor/request-context-device-report.json');
const report = { preview: false, originalRead: false, compacted: false, completed: false };
let reference;
function save() { fs.writeFileSync(reportPath, JSON.stringify(report, null, 2)); }
function respond(res, content, toolCalls = [], input = 1000) {
  res.writeHead(200, { 'content-type': 'text/event-stream' });
  const frame = data => res.write('data: ' + JSON.stringify(data) + '\n\n');
  frame({ choices: [{ index: 0, delta: { content, ...(toolCalls.length ? { tool_calls: toolCalls.map((call, index) => ({ ...call, index })) } : {}) } }] });
  frame({ choices: [{ index: 0, delta: {}, finish_reason: toolCalls.length ? 'tool_calls' : 'stop' }], usage: { prompt_tokens: input, completion_tokens: 100 } });
  res.end('data: [DONE]\n\n');
}
function tool(id, name, args) { return { id, type: 'function', function: { name, arguments: JSON.stringify(args) } }; }
http.createServer(async (req, res) => {
  try {
    if (req.url.endsWith('/models')) { res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify({ data: [{ id: 'shared-test-model' }] })); return; }
    let body = ''; for await (const chunk of req) body += chunk;
    const request = JSON.parse(body), messages = request.messages || [];
    const system = messages.filter(message => message.role === 'system').map(message => message.content).join('\n');
    if (system.includes('上下文摘要助手')) {
      report.compacted = true; save();
      respond(res, 'The calculation succeeded. Its full output is saved; messageId=' + reference.messageId + ', callId=large. Do not repeat the calculation. Continue from the recent saved-result read.'); return;
    }
    if (!system.includes('你是 Tinybot')) { respond(res, system.includes('记忆') ? '[]' : 'Context verification'); return; }
    const last = messages.at(-1);
    if (last?.role === 'tool' && last.tool_call_id === 'read-original') {
      const page = JSON.parse(last.content);
      if (!page.content.includes('CONTEXT_RESULT_END')) throw Error('Original result tail was not returned');
      if (!report.compacted || !messages.some(message => String(message.content).includes('<context-summary>'))) throw Error('No persisted compaction summary in final request');
      report.originalRead = true; report.completed = true; save();
      respond(res, '上下文压缩与完整工具结果分段读取验证通过。计算只执行了一次，完整结果仍保存在会话记录中。'); return;
    }
    if (last?.role === 'tool' && last.tool_call_id === 'large') {
      reference = JSON.parse(last.content);
      if (!reference.contextPreview || reference.totalCharacters < 100000) throw Error('Expected a saved large-result preview');
      report.preview = true; report.characters = reference.totalCharacters; save();
      // Usage deliberately exceeds the configured 200k input budget. It exercises usage-driven
      // mid-turn compaction without making the device render a megabyte of assistant text.
      respond(res, '正在核验已保存的计算结果。\n' + 'Result verification. '.repeat(500), [tool('read-original', 'read_tool_result', {
        messageId: reference.messageId, callId: 'large', offset: reference.totalCharacters - 256, length: 256
      })], 195000); return;
    }
    respond(res, '', [tool('large', 'execute_code', { code: "return {payload:'x'.repeat(100000),tail:'CONTEXT_RESULT_END'};" })]);
  } catch (error) {
    report.error = error.message; save();
    if (!res.headersSent) res.writeHead(500, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: { message: error.message } }));
  }
}).listen(18768, '127.0.0.1', () => { save(); console.log('Request context fixture listening on 18768'); });
