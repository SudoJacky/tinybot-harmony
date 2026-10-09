import { describe, expect, it } from '@ohos/hypium';
import { AgentTurn, ModelMessage, ModelTurn, ToolCall, ToolDefinition } from '../main/ets/model/Agent';
import { emptyData, parseAppData, requestHistory } from '../main/ets/model/Conversation';
import { defaultExtensions, explicitSkill, parseSkill, skillCatalog, validateExtensions } from '../main/ets/model/Skills';
import { AgentTools, runAgentLoop } from '../main/ets/services/AgentLoop';
import { Cancellation } from '../main/ets/services/Cancellation';
import { ModelSession } from '../main/ets/services/providers/Provider';
import { SkillTools } from '../main/ets/services/SkillTools';
import { ToolSet } from '../main/ets/services/ToolSet';
import { MAX_WEB_TEXT, WebDocument, WebTools, WebTransport, extractWebPage, validateWebAddress } from '../main/ets/services/WebTools';

const DOCUMENT: string = '---\nname: summarize\ndescription: 总结网页和资料\n---\n先读取 references/guide.md，再总结用户提供的网页。';

function call(id: string, name: string, args: string): ToolCall {
  return { id: id, type: 'function', function: { name: name, arguments: args } };
}

function rejects(action: () => void, message: string): void {
  let result = '';
  try { action(); } catch (error) { result = (error as Error).message; }
  expect(result.includes(message)).assertTrue();
}

async function rejectsAsync(action: () => Promise<void>, message: string): Promise<void> {
  let result = '';
  try { await action(); } catch (error) { result = (error as Error).message; }
  expect(result.includes(message)).assertTrue();
}

class FixtureWeb implements WebTransport {
  requests: string[] = [];
  failure: string = '';
  cancelOnRead: boolean = false;
  body: string = '<html><head><title>来源 &amp; 示例</title><script>secretScript()</script></head>' +
    '<body><nav>navigation</nav><main><h1>中文标题</h1><p>网页正文 &lt;参考&gt;。</p>' +
    '<a href="/details?a=1&amp;b=2">详情</a><a href="javascript:bad()">bad</a>' +
    '<style>hiddenStyle</style></main></body></html>';

  async get(address: string, cancellation: Cancellation): Promise<WebDocument> {
    cancellation.check();
    this.requests.push(address);
    if (this.failure.length > 0) { throw new Error(this.failure); }
    if (this.cancelOnRead) { cancellation.cancel(); }
    return { url: 'https://example.com/page', contentType: 'text/html; charset=utf-8', body: this.body };
  }

  resolve(reference: string, _base: string): string {
    return reference.startsWith('/') ? 'https://example.com' + reference : reference;
  }
}

class ExtensionModel implements ModelSession {
  requests: ModelMessage[][] = [];
  catalog: ToolDefinition[] = [];
  private turns: ModelTurn[];
  constructor(turns: ModelTurn[]) { this.turns = turns; }
  async stream(messages: ModelMessage[], tools: ToolDefinition[], cancellation: Cancellation,
    _onText: (text: string) => void): Promise<ModelTurn> {
    cancellation.check();
    this.requests.push(JSON.parse(JSON.stringify(messages)) as ModelMessage[]);
    this.catalog = tools;
    const turn = this.turns.shift();
    if (!turn) { throw new Error('unexpected model call'); }
    return turn;
  }
}

async function run(model: ModelSession, tools: AgentTools, result: AgentTurn,
  saved: string[], cancellation: Cancellation = new Cancellation()): Promise<void> {
  await runAgentLoop({ model: model, tools: tools, messages: [{ role: 'user', content: '总结网页' }],
    turn: result, maxSteps: 8 }, cancellation, {
    event: () => {}, checkpoint: async () => { saved.push(JSON.stringify(result)); }
  });
}

export default function extensionTests(): void {
  describe('Skills', () => {
    it('parsesPortableFrontmatterAndAdvertisesOnlyMetadata', 0, () => {
      const skill = parseSkill(DOCUMENT);
      expect(skill.name).assertEqual('summarize');
      expect(skillCatalog([skill]).includes('总结网页和资料')).assertTrue();
      expect(skillCatalog([skill]).includes('先读取 references')).assertFalse();
      const multiline = parseSkill('---\nname: block\ndescription: >\n  总结资料\n  保留来源\nmetadata:\n  author: fixture\n---\n正文');
      expect(multiline.description).assertEqual('总结资料 保留来源');
      expect(explicitSkill('/skill:summarize https://example.com')).assertEqual('summarize');
      expect(explicitSkill('解释 /skill:summarize')).assertEqual('');
      rejects(() => { parseSkill('普通说明'); }, '元数据');
      rejects(() => { parseSkill(DOCUMENT.replace('name: summarize', 'name: ../escape')); }, 'name');
      rejects(() => { parseSkill(DOCUMENT.replace('description:', 'name: duplicate\ndescription:')); }, '重复');
      rejects(() => { parseSkill(DOCUMENT.replace('description: 总结网页和资料', 'description: {nested: value}')); }, 'YAML');
    });

    it('honorsManualOnlyAndDisabledSkillsAndFreezesRunContent', 0, async () => {
      const skill = parseSkill(DOCUMENT.replace('description:', 'disable-model-invocation: true\ndescription:'));
      expect(new SkillTools([skill]).definitions().length).assertEqual(0);
      expect(skillCatalog([skill])).assertEqual('');
      const tools = new SkillTools([skill], 'summarize');
      skill.document = 'changed after run start';
      const result = await tools.execute(call('s', 'read_skill', '{"name":"summarize"}'), new Cancellation());
      expect(result.includes('先读取')).assertTrue();
      expect(result.includes('changed after')).assertFalse();
      skill.enabled = false;
      await rejectsAsync(async () => { await new SkillTools([skill], 'summarize').execute(
        call('s', 'read_skill', '{"name":"summarize"}'), new Cancellation()); }, '未启用');
    });

    it('persistsSkillsAndRejectsCorruptOrEscapingReferences', 0, async () => {
      const data = emptyData();
      expect(parseAppData(JSON.stringify(data)).extensions).assertUndefined();
      const skill = parseSkill(DOCUMENT);
      skill.files = [{ path: 'references/guide.md', content: '请保留来源。' }];
      data.extensions = { webEnabled: false, skills: [skill] };
      const restored = parseAppData(JSON.stringify(data));
      expect(restored.extensions?.webEnabled).assertFalse();
      const tools = new SkillTools(restored.extensions?.skills || []);
      expect((await tools.execute(call('r', 'read_skill', '{"name":"summarize","path":"references/guide.md"}'),
        new Cancellation())).includes('请保留来源')).assertTrue();
      for (const path of ['../other', '/absolute', 'a/../b', 'C:\\secret', 'a//b']) {
        await rejectsAsync(async () => { await tools.execute(call('x', 'read_skill', JSON.stringify({ name: 'summarize', path: path })),
          new Cancellation()); }, '相对路径');
      }
      await rejectsAsync(async () => { await tools.execute(call('x', 'read_skill', '{"name":"summarize","path":"missing"}'),
        new Cancellation()); }, '尚未导入');
      skill.files.push({ path: 'references/guide.md', content: 'duplicate' });
      rejects(() => { validateExtensions({ webEnabled: true, skills: [skill] }); }, '重复');
      expect(defaultExtensions().skills.length).assertEqual(0);
    });
  });

  describe('WebReading', () => {
    it('extractsStaticTextAndSourceLinksWithoutExecutingMarkup', 0, async () => {
      const transport = new FixtureWeb();
      const document = await transport.get('https://example.com', new Cancellation());
      const page = extractWebPage(document, transport);
      expect(page.title).assertEqual('来源 & 示例');
      expect(page.content.includes('中文标题')).assertTrue();
      expect(page.content.includes('<参考>')).assertTrue();
      expect(page.content.includes('secretScript')).assertFalse();
      expect(page.content.includes('hiddenStyle')).assertFalse();
      expect(page.content.includes('navigation')).assertFalse();
      expect(page.links.length).assertEqual(1);
      expect(page.links[0].url).assertEqual('https://example.com/details?a=1&b=2');
      expect(page.trust).assertEqual('untrusted');
      expect(page.truncated).assertFalse();
    });

    it('boundsTextAndRejectsBinaryOrEmptyDocuments', 0, () => {
      const transport = new FixtureWeb();
      const page = extractWebPage({ url: 'https://example.com', contentType: 'text/plain', body: '中'.repeat(MAX_WEB_TEXT + 1) }, transport);
      expect(page.truncated).assertTrue();
      expect(page.content.length).assertEqual(MAX_WEB_TEXT);
      rejects(() => { extractWebPage({ url: 'https://example.com', contentType: 'application/pdf', body: '%PDF' }, transport); }, '内容类型');
      rejects(() => { extractWebPage({ url: 'https://example.com', contentType: 'text/html', body: '<script>run()</script>' }, transport); }, '没有可读取');
      rejects(() => { extractWebPage({ url: 'https://example.com', contentType: 'text/plain', body: '\u0000' }, transport); }, '二进制');
    });

    it('rejectsNonWebSchemesCredentialsAndMalformedArgumentsBeforeNetworking', 0, async () => {
      const transport = new FixtureWeb();
      const tools = new WebTools(transport);
      for (const address of ['file:///secret', 'data:text/plain,test', 'https://user:pass@example.com', 'https://exam ple.com', 'http://']) {
        rejects(() => { validateWebAddress(address); }, '网页');
      }
      for (const args of ['null', '[]', '{"url":1}', '{"url":"https://example.com","headers":{}}']) {
        await rejectsAsync(async () => { await tools.execute(call('w', 'read_web', args), new Cancellation()); }, '参数');
      }
      expect(transport.requests.length).assertEqual(0);
    });
  });

  describe('ExtensionLoop', () => {
    it('readsSkillThenWebThroughTheActualLoopAndReplaysReceipts', 0, async () => {
      const skill = parseSkill(DOCUMENT);
      skill.files = [{ path: 'references/guide.md', content: '引用来源 URL。' }];
      const model = new ExtensionModel([
        { content: '', toolCalls: [call('s', 'read_skill', '{"name":"summarize"}')] },
        { content: '', toolCalls: [call('r', 'read_skill', '{"name":"summarize","path":"references/guide.md"}'),
          call('w', 'read_web', '{"url":"https://example.com"}')] },
        { content: '已总结，来源 https://example.com/page', toolCalls: [] }
      ]);
      const result: AgentTurn = { content: '', steps: [] };
      const saved: string[] = [];
      await run(model, new ToolSet([new SkillTools([skill]), new WebTools(new FixtureWeb())]), result, saved);
      const durable = (JSON.parse(saved[saved.length - 1]) as AgentTurn).steps.flatMap((step) => step.tools);
      expect(JSON.stringify(durable)).assertEqual(JSON.stringify(result.steps.flatMap((step) => step.tools)));
      expect(model.requests[2][5].toolCallId).assertEqual('w');
      expect(model.requests[2][5].content.includes('"trust":"untrusted"')).assertTrue();
      const data = emptyData();
      data.threads = [{ id: 't', title: 't', updatedAt: 1, messages: [
        { id: 'u', role: 'user', content: '总结网页', status: 'complete', error: '' },
        { id: 'a', role: 'assistant', content: result.content, status: 'complete', error: '', steps: result.steps }
      ] }];
      const replay = requestHistory(parseAppData(JSON.stringify(data)).threads[0].messages, '');
      expect(replay.filter((message: ModelMessage) => message.role === 'tool').length).assertEqual(3);
      expect(replay[replay.length - 1].content).assertEqual(result.content);
    });

    it('doesNotDispatchDisabledToolsAndReportsNetworkErrorsToTheModel', 0, async () => {
      const transport = new FixtureWeb();
      const disabled = new ToolSet([]);
      expect(disabled.definitions().length).assertEqual(0);
      await rejectsAsync(async () => { await disabled.execute(call('w', 'read_web', '{"url":"https://example.com"}'), new Cancellation()); }, '未启用');
      transport.failure = 'HTTP 403';
      const model = new ExtensionModel([
        { content: '', toolCalls: [call('w', 'read_web', '{"url":"https://example.com"}')] },
        { content: '网页拒绝访问', toolCalls: [] }
      ]);
      const result: AgentTurn = { content: '', steps: [] };
      await run(model, new ToolSet([new WebTools(transport)]), result, []);
      expect(result.steps[0].tools[0].status).assertEqual('failed');
      expect(model.requests[1][2].content.includes('HTTP 403')).assertTrue();
    });

    it('stopsAfterCancelledWebReadAndDoesNotStartTheNextTool', 0, async () => {
      const transport = new FixtureWeb();
      transport.cancelOnRead = true;
      const model = new ExtensionModel([{ content: '', toolCalls: [
        call('a', 'read_web', '{"url":"https://example.com/a"}'), call('b', 'read_web', '{"url":"https://example.com/b"}')
      ] }]);
      const result: AgentTurn = { content: '', steps: [] };
      await rejectsAsync(async () => { await run(model, new ToolSet([new WebTools(transport)]), result, []); }, '停止');
      expect(transport.requests.length).assertEqual(1);
      expect(result.steps[0].tools[0].status).assertEqual('cancelled');
      expect(result.steps[0].tools[1].status).assertEqual('cancelled');
      expect(model.requests.length).assertEqual(1);
    });
  });
}
