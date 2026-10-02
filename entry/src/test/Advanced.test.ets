import { describe, expect, it } from '@ohos/hypium';
import { parsePlan, parseForm, formResult, parseDataView, dataCsv, parseDelimited, lineDiff } from '../main/ets/model/RichArtifacts';
import { UsageStream } from '../main/ets/model/Usage';
import { defaultAssistantOptions, routeModel } from '../main/ets/model/AssistantOptions';
import { replaceUnique, WorkspaceTools, WorkspaceFiles } from '../main/ets/services/WorkspaceTools';
import { Cancellation } from '../main/ets/services/Cancellation';
import { ToolApproval } from '../main/ets/services/ToolApproval';
import { InteractionTools } from '../main/ets/services/InteractionTools';
import { ToolCall } from '../main/ets/model/Agent';
import { ModelReference } from '../main/ets/model/ProviderProfiles';
function rejects(action: () => void): void { let rejected = false; try { action(); } catch (_) { rejected = true; } expect(rejected).assertTrue(); }
function call(name: string, data: string): ToolCall { return { id: 'test', type: 'function', function: { name: name, arguments: JSON.stringify({ data: data }) } }; }
class SearchFiles implements WorkspaceFiles {
  async list(path: string, _signal: Cancellation): Promise<string> { return path ? '{"entries":[{"name":"b.txt","kind":"file"}],"truncated":false}' : '{"entries":[{"name":"sub","kind":"directory"},{"name":"a.txt","kind":"file"},{"name":"link","kind":"symlink"}],"truncated":false}'; }
  async read(path: string, _signal: Cancellation): Promise<string> { return JSON.stringify({ content: path === 'a.txt' ? 'first\nTODO a' : 'TODO b' }); }
  async write(_path: string, _content: string, _signal: Cancellation): Promise<string> { throw new Error('Unexpected write'); }
}
export default function advancedTests(): void {
  describe('Advanced', () => {
    it('plansEnforceOneActiveStepAndPermitCompletedPlans', 0, () => {
      expect(parsePlan('{"steps":[{"step":"read","status":"in_progress"},{"step":"write","status":"pending"}]}').steps.length).assertEqual(2);
      rejects(() => parsePlan('{"steps":[{"step":"read","status":"pending"}]}'));
      expect(parsePlan('{"steps":[{"step":"done","status":"completed"}]}').steps.length).assertEqual(1);
    });
    it('formsValidateRequiredFieldsAndOptions', 0, () => {
      const form = parseForm('{"title":"choose","fields":[{"name":"budget","label":"Budget","type":"number","required":true},{"name":"style","label":"Style","type":"select","options":["A","B"]}]}');
      rejects(() => formResult(form, ['', 'A'])); rejects(() => formResult(form, ['NaN', 'A'])); rejects(() => formResult(form, ['1', 'C']));
      expect(formResult(form, ['100', 'A']).includes('submitted')).assertTrue();
      rejects(() => parseForm('{"title":"bad","fields":[{"name":"constructor","label":"x","type":"text"}]}'));
    });
    it('formCancellationClearsPendingInteraction', 0, async () => {
      const approval = new ToolApproval(); const signal = new Cancellation();
      const pending = new InteractionTools(approval).execute(call('request_user_input', '{"title":"Test","fields":[{"name":"text","label":"text","type":"text"}]}'), signal);
      expect(approval.form?.title).assertEqual('Test'); signal.cancel();
      let rejected = false; try { await pending; } catch (_) { rejected = true; } expect(rejected).assertTrue(); expect(approval.form === undefined).assertTrue();
    });
    it('formCanSubmitAndContinue', 0, async () => {
      const approval = new ToolApproval(); const form = parseForm('{"title":"Test","fields":[{"name":"text","label":"text","type":"text","required":true}]}');
      const pending = approval.ask(form, new Cancellation()); approval.submit(['value']); expect((await pending).includes('value')).assertTrue();
    });
    it('chartValidationAndCsvExportPreserveValues', 0, () => {
      const view = parseDataView('{"title":"Chart","source":"user table","kind":"bar","columns":[{"key":"month","label":"Month","type":"string"},{"key":"value","label":"Value","type":"number"}],"rows":[{"values":["=SUM(A1)",2]}]}');
      expect(dataCsv(view).includes("'=SUM(A1)")).assertTrue();
      rejects(() => parseDataView('{"title":"Chart","source":"user","kind":"bar","columns":[{"key":"a","label":"a","type":"string"},{"key":"b","label":"b","type":"number"}],"rows":[{"values":["a","2"]}]}'));
    });
    it('csvHandlesQuotedDelimitersAndNewlines', 0, () => {
      const rows = parseDelimited('name,value\r\n"a,b","line\nsecond"\r\n"say ""hi""",2', ',');
      expect(rows[1][0]).assertEqual('a,b'); expect(rows[1][1]).assertEqual('line\nsecond'); expect(rows[2][0]).assertEqual('say "hi"');
      rejects(() => parseDelimited('"incomplete', ','));
    });
    it('uniqueEditsDoNotExpandReplacementSyntaxOrAcceptAmbiguity', 0, () => {
      expect(replaceUnique('A old B', 'old', '$&')).assertEqual('A $& B');
      rejects(() => replaceUnique('same same', 'same', 'x')); rejects(() => replaceUnique('text', 'missing', 'x'));
      expect(lineDiff('a\nb\nc', 'a\nx\nc')).assertEqual('@@ 第 2 行起 @@\n- b\n+ x');
    });
    it('searchTraversesTextFilesAndReturnsLineNumbers', 0, async () => {
      const result = await new WorkspaceTools(new SearchFiles()).execute({ id: 'a', type: 'function', function: { name: 'search_file_content', arguments: '{"path":".","query":"TODO"}' } }, new Cancellation());
      expect(result.includes('sub/b.txt')).assertTrue(); expect(result.includes('"line":2')).assertTrue(); expect(result.includes('"checkedFiles":2')).assertTrue();
    });
    it('usageParsesFragmentedChatAndDoesNotDoubleCountCache', 0, () => {
      const stream = new UsageStream(); const text = 'data: {"usage":{"prompt_tokens":100,"completion_tokens":20,"prompt_tokens_details":{"cached_tokens":70},"completion_tokens_details":{"reasoning_tokens":5}}}\r\n\r\n';
      for (const char of text) { stream.push(char); }
      expect(stream.result()?.input).assertEqual(100); expect(stream.result()?.cached).assertEqual(70); expect(stream.result()?.reasoning).assertEqual(5);
      expect(new UsageStream().result() === undefined).assertTrue();
    });
    it('anthropicUsageMergesStartAndDeltaAndCountsCacheInput', 0, () => {
      const stream = new UsageStream(); stream.push('data: {"type":"message_start","message":{"usage":{"input_tokens":10,"output_tokens":0,"cache_read_input_tokens":90,"cache_creation_input_tokens":20}}}\n\n');
      stream.push('data: {"type":"message_delta","usage":{"output_tokens":30}}\n\n');
      expect(stream.result()?.input).assertEqual(120); expect(stream.result()?.output).assertEqual(30);
    });
    it('routingUsesExplicitChoicesAndFallsBackToCurrent', 0, () => {
      const options = defaultAssistantOptions(); const current: ModelReference = { providerId: 'p', modelId: 'current' };
      options.fast = { providerId: 'p', modelId: 'fast' }; options.deep = { providerId: 'p', modelId: 'deep' };
      expect(routeModel(options, 'hi', false, current).modelId).assertEqual('current'); options.autoRoute = true;
      expect(routeModel(options, 'hi', false, current).modelId).assertEqual('fast'); expect(routeModel(options, '详细分析', false, current).modelId).assertEqual('deep');
      expect(routeModel(options, '图片', true, current).modelId).assertEqual('current');
    });
  });
}
