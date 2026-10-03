import { describe, expect, it } from '@ohos/hypium';
import { ProviderEditorViewModel } from '../main/ets/viewmodel/ProviderEditorViewModel';
import { defaultConfig, emptyData, parseAppData } from '../main/ets/model/Conversation';
import { ModelMessage, ToolDefinition, ToolProperty, ToolParameters, ToolDefinitionFunction } from '../main/ets/model/Agent';
import { ProviderProfile, availableModels, migrateProfiles, modelConfig, modelIds, validateProfile } from '../main/ets/model/ProviderProfiles';
import { protocolUrl, protocolHeaders, responsesRequest, anthropicRequest } from '../main/ets/services/providers/WireProtocols';
import { ResponsesStream, AnthropicStream, ModelStream } from '../main/ets/services/providers/EventStreams';
import { profileProvider } from '../main/ets/services/providers/DefaultProviders';

function profile(id: string, protocol: string = 'chat-completions'): ProviderProfile {
  return { id: id, name: id, protocol: protocol, baseUrl: 'https://example.com/v1', credentialAlias: id + '-key',
    noApiKey: false, enabled: true, models: ['same-model', 'other-model'], contextWindow: 8192 };
}
function rejects(action: () => void): void {
  let rejected = false;
  try { action(); } catch (_) { rejected = true; }
  expect(rejected).assertTrue();
}
const HISTORY: ModelMessage[] = [
  { role: 'system', content: 'system instructions' }, { role: 'user', content: 'read the file' },
  { role: 'assistant', content: 'checking', toolCalls: [{ id: 'call_1', type: 'function',
    function: { name: 'read_file', arguments: '{"path":"a.txt"}' } }] },
  { role: 'tool', content: 'first result', toolCallId: 'call_1' },
  { role: 'tool', content: 'second result', toolCallId: 'call_2' }
];
const PATH_PROPERTY: ToolProperty = { type: 'string', description: 'path' };
const PROPERTIES: Record<string, ToolProperty> = { 'path': PATH_PROPERTY };
const PARAMETERS: ToolParameters = { type: 'object', properties: PROPERTIES, required: ['path'], additionalProperties: false };
const READ_FUNCTION: ToolDefinitionFunction = { name: 'read_file', description: 'read', parameters: PARAMETERS };
const READ_TOOL: ToolDefinition = { type: 'function', function: READ_FUNCTION };
const TOOLS: ToolDefinition[] = [READ_TOOL];
const RESPONSE_TEXT = 'data: {"type":"response.output_text.delta","delta":"你好"}\r\n\r\n' +
  'data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"你好"}]}]}}\r\n\r\n';
const ANTHROPIC_TEXT = 'data: {"type":"message_start"}\n\n' +
  'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n' +
  'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"你好"}}\n\n' +
  'data: {"type":"content_block_stop","index":0}\n\n' +
  'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}\n\n' +
  'data: {"type":"message_stop"}\n\n';

export default function profileTests(): void {
  describe('ProviderProfiles', () => {
    it('mobileEditorAddsModelsWithoutDuplicatesAndRejectsInvalidBatchAtomically', 0, () => {
      const editor = new ProviderEditorViewModel(); editor.reset(profile('test'));
      expect(editor.hasChanges).assertFalse();
      editor.addModels('same-model,new-model');
      expect(editor.modelList.join(',')).assertEqual('same-model,other-model,new-model'); expect(editor.hasChanges).assertTrue();
      const before = editor.models; rejects(() => editor.addModels('valid,' + 'x'.repeat(201)));
      expect(editor.models).assertEqual(before);
      editor.removeModel('new-model'); expect(editor.hasChanges).assertFalse();
      editor.removeModel('same-model'); editor.removeModel('other-model');
      expect(editor.fieldError('models').length > 0).assertTrue();
    });
    it('mobileEditorRetainsKeysAcrossProtocolsAtTheSameServiceRoot', 0, () => {
      const editor = new ProviderEditorViewModel(); editor.reset(profile('test'));
      expect(editor.canKeepKey).assertTrue(); expect(editor.fieldError('key')).assertEqual('');
      editor.baseUrl += '/chat/completions'; expect(editor.canKeepKey).assertTrue();
      editor.baseUrl = 'https://other.example/v1'; expect(editor.canKeepKey).assertFalse();
      expect(editor.fieldError('key').length > 0).assertTrue();
      editor.apiKey = 'replacement'; expect(editor.fieldError('key')).assertEqual('');
      editor.reset(profile('test')); editor.changeProtocol('responses'); expect(editor.canKeepKey).assertTrue();
      expect(editor.fieldError('key')).assertEqual('');
      editor.changeProtocol('anthropic-messages'); expect(editor.canKeepKey).assertTrue();
      editor.baseUrl = 'https://example.com/other'; expect(editor.canKeepKey).assertFalse();
      editor.baseUrl = 'https://example.com:8443/v1'; expect(editor.canKeepKey).assertFalse();
      editor.baseUrl = 'http://example.com/v1'; expect(editor.canKeepKey).assertFalse();
      editor.baseUrl = 'invalid'; expect(editor.canKeepKey).assertFalse();
      editor.noApiKey = true; expect(editor.fieldError('key')).assertEqual('');
    });
    it('mobileEditorConvertsFullEndpointPathsWhenSwitchingProtocol', 0, () => {
      const existing = profile('test'); existing.baseUrl += '/chat/completions/';
      const editor = new ProviderEditorViewModel(); editor.reset(existing);
      editor.changeProtocol('responses');
      expect(editor.baseUrl).assertEqual('https://example.com/v1/responses');
      expect(editor.canKeepKey).assertTrue(); expect(editor.fieldError('url')).assertEqual('');
      editor.changeProtocol('chat-completions');
      expect(editor.baseUrl).assertEqual('https://example.com/v1/chat/completions');
      expect(editor.canKeepKey).assertTrue();
    });
    it('mobileEditorReportsFieldErrorsAndResetsDirtyStateBetweenServices', 0, () => {
      const editor = new ProviderEditorViewModel(); editor.reset();
      expect(editor.hasChanges).assertFalse(); expect(editor.fieldError('name').length > 0).assertTrue();
      editor.baseUrl = 'not a url'; expect(editor.fieldError('url').length > 0).assertTrue();
      editor.contextWindow = '8191'; expect(editor.fieldError('context').length > 0).assertTrue();
      editor.contextWindow = '8192'; expect(editor.fieldError('context')).assertEqual('');
      editor.reset(profile('another')); expect(editor.hasChanges).assertFalse(); expect(editor.apiKey).assertEqual('');
      editor.modelInput = 'unfinished model'; expect(editor.hasChanges).assertTrue();
      editor.reset(profile('test')); expect(editor.modelInput).assertEqual(''); expect(editor.hasChanges).assertFalse();
    });
    it('migratesConfiguredLegacyDeepSeekWithoutChangingAliasOrEndpoint', 0, () => {
      const config = defaultConfig();
      config.configured = true; config.credentialAlias = 'existing-secure-key';
      config.baseUrl = 'https://custom.deepseek.example/v1'; config.model = 'custom-deepseek-model';
      const profiles = migrateProfiles(config);
      expect(profiles.length).assertEqual(1);
      expect(profiles[0].credentialAlias).assertEqual('existing-secure-key');
      expect(profiles[0].baseUrl).assertEqual(config.baseUrl);
      expect(profiles[0].models[0]).assertEqual(config.model);
      expect(migrateProfiles(defaultConfig()).length).assertEqual(0);
    });
    it('routesIdenticalModelIdsToSeparateInstancesAndCredentials', 0, () => {
      const profiles = [profile('company'), profile('personal', 'responses')];
      const choices = availableModels(profiles);
      expect(choices.length).assertEqual(4);
      const company = modelConfig(profiles, { providerId: 'company', modelId: 'same-model' }, defaultConfig());
      const personal = modelConfig(profiles, { providerId: 'personal', modelId: 'same-model' }, defaultConfig());
      expect(company.providerId).assertEqual('company'); expect(company.credentialAlias).assertEqual('company-key');
      expect(personal.credentialAlias).assertEqual('personal-key'); expect(personal.contextWindow).assertEqual(8192);
    });
    it('neverSilentlySelectsAnotherProviderWhenSelectionIsUnavailable', 0, () => {
      const profiles = [profile('disabled'), profile('available')]; profiles[0].enabled = false;
      expect(availableModels(profiles).length).assertEqual(2);
      rejects(() => { modelConfig(profiles, { providerId: 'disabled', modelId: 'same-model' }, defaultConfig()); });
      rejects(() => { modelConfig(profiles, { providerId: 'missing', modelId: 'same-model' }, defaultConfig()); });
      rejects(() => { modelConfig(profiles, { providerId: 'available', modelId: 'removed-model' }, defaultConfig()); });
    });
    it('persistsSessionAndAnswerRoutingIndependentlyOfGlobalDefault', 0, () => {
      const data = emptyData(); data.providerProfiles = [profile('first'), profile('second')];
      data.config = modelConfig(data.providerProfiles, { providerId: 'first', modelId: 'same-model' }, data.config);
      data.threads = [{ id: 'session', title: 'thread', updatedAt: 1, modelRef: { providerId: 'second', modelId: 'other-model' },
        messages: [{ id: 'user', role: 'user', content: 'hello', status: 'complete', error: '' },
          { id: 'answer', role: 'assistant', content: 'hi', status: 'complete', error: '',
            modelRef: { providerId: 'second', modelId: 'other-model' } }] }];
      const restored = parseAppData(JSON.stringify(data));
      expect(restored.config.providerId).assertEqual('first');
      expect(restored.threads[0].modelRef?.providerId).assertEqual('second');
      expect(restored.threads[0].messages[1].modelRef?.modelId).assertEqual('other-model');
      expect(restored.providerProfiles?.[0].credentialAlias).assertEqual('first-key');
    });
    it('rejectsDuplicateProfilesAliasesModelsAndUnsupportedProtocols', 0, () => {
      const data = emptyData(); data.providerProfiles = [profile('first'), profile('first')];
      rejects(() => { parseAppData(JSON.stringify(data)); });
      data.providerProfiles = [profile('first'), profile('second')]; data.providerProfiles[1].credentialAlias = 'first-key';
      rejects(() => { parseAppData(JSON.stringify(data)); });
      const value = profile('first'); value.protocol = 'unknown'; rejects(() => validateProfile(value));
      rejects(() => modelIds('same,same')); rejects(() => modelIds(' , '));
    });
    it('usesTheSelectedProtocolRatherThanProviderNameOrBaseUrl', 0, () => {
      const value = profile('deepseek-proxy', 'anthropic-messages');
      expect(profileProvider(value).endpoint(value.baseUrl)).assertEqual(value.baseUrl + '/messages');
      expect(protocolUrl('responses', 'https://example.com/v1/responses/', false)).assertEqual('https://example.com/v1/responses');
      expect(protocolUrl('anthropic-messages', 'https://api.anthropic.com', false)).assertEqual('https://api.anthropic.com/v1/messages');
      rejects(() => protocolUrl('responses', 'https://example.com/v1/chat/completions', false));
    });
  });
  describe('WireProtocols', () => {
    it('separatesAnthropicApiKeyHeadersFromOpenAiBearerAuth', 0, () => {
      expect(protocolHeaders('responses', 'fixture-key')['Authorization']).assertEqual('Bearer fixture-key');
      expect(protocolHeaders('chat-completions', 'fixture-key')['Authorization']).assertEqual('Bearer fixture-key');
      const headers = protocolHeaders('anthropic-messages', 'fixture-key');
      expect(headers['x-api-key']).assertEqual('fixture-key');
      expect(headers['anthropic-version']).assertEqual('2023-06-01');
      expect(headers['Authorization'] === undefined).assertTrue();
      expect(protocolHeaders('responses', '')['Authorization'] === undefined).assertTrue();
    });
    it('convertsResponsesToolsAndReceiptsWithoutMutatingHistory', 0, () => {
      const before = JSON.stringify(HISTORY);
      const body = responsesRequest('model', HISTORY, TOOLS, 4096);
      expect(body.instructions).assertEqual('system instructions'); expect(body.store).assertFalse();
      expect(body.input[2].type).assertEqual('function_call'); expect(body.input[2].call_id).assertEqual('call_1');
      expect(body.input[3].type).assertEqual('function_call_output'); expect(body.input[3].output).assertEqual('first result');
      expect(body.tools?.[0].name).assertEqual('read_file'); expect(body.max_output_tokens).assertEqual(4096);
      expect(JSON.stringify(HISTORY)).assertEqual(before);
      expect(JSON.stringify(responsesRequest('model', HISTORY, [])).includes('"tools"')).assertFalse();
    });
    it('convertsAnthropicSystemToolsAndGroupedUserReceipts', 0, () => {
      const body = anthropicRequest('model', HISTORY, TOOLS, 4096);
      expect(body.system).assertEqual('system instructions'); expect(body.max_tokens).assertEqual(4096);
      expect(body.messages[1].content[1].type).assertEqual('tool_use');
      expect(body.messages[2].role).assertEqual('user'); expect(body.messages[2].content.length).assertEqual(2);
      expect(body.messages[2].content[0].tool_use_id).assertEqual('call_1');
      expect(body.tools?.[0].input_schema.required[0]).assertEqual('path');
      expect(JSON.stringify(anthropicRequest('model', HISTORY, [])).includes('"tools"')).assertFalse();
    });
    it('streamsBothNativeProtocolsAcrossEveryTransportBoundary', 0, () => {
      for (const wire of [RESPONSE_TEXT, ANTHROPIC_TEXT]) {
        for (let boundary = 1; boundary < wire.length; boundary++) {
          let visible = '';
          const parser: ModelStream = wire === RESPONSE_TEXT ? new ResponsesStream((text: string) => { visible += text; }) :
            new AnthropicStream((text: string) => { visible += text; });
          parser.push(wire.slice(0, boundary)); parser.push(wire.slice(boundary));
          expect(parser.finish().content).assertEqual('你好'); expect(visible).assertEqual('你好');
        }
      }
    });
    it('collectsResponsesCallsFromTheAuthoritativeCompletedOutput', 0, () => {
      const parser = new ResponsesStream(() => {});
      parser.push('data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"function_call","call_id":"call_1","name":"read_file","arguments":"{\\\"path\\\":\\\"a.txt\\\"}"}]}}\n\n');
      expect(parser.finish().toolCalls[0].function.arguments).assertEqual('{"path":"a.txt"}');
    });
    it('collectsAnthropicFragmentedToolInputWithInterleavedTextBlocks', 0, () => {
      const parser = new AnthropicStream(() => {});
      parser.push(ANTHROPIC_TEXT.slice(0, ANTHROPIC_TEXT.indexOf('data: {"type":"message_delta"')));
      parser.push('data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"call_1","name":"read_file","input":{}}}\n\n');
      parser.push('data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\\"path\\\":"}}\n\n');
      parser.push('data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\\\"a.txt\\\"}"}}\n\n');
      parser.push('data: {"type":"content_block_stop","index":1}\n\ndata: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}\n\ndata: {"type":"message_stop"}\n\n');
      expect(parser.finish().toolCalls[0].function.arguments).assertEqual('{"path":"a.txt"}');
    });
    it('rejectsIncompleteErroredAndContradictoryNativeStreams', 0, () => {
      const response = new ResponsesStream(() => {}); response.push('data: {"type":"response.output_text.delta","delta":"partial"}\n\n');
      rejects(() => { response.finish(); });
      rejects(() => new ResponsesStream(() => {}).push('data: {"type":"response.incomplete"}\n\n'));
      rejects(() => new ResponsesStream(() => {}).push(RESPONSE_TEXT.replace('"text":"你好"', '"text":"different"')));
      rejects(() => new AnthropicStream(() => {}).push(ANTHROPIC_TEXT.replace('end_turn', 'max_tokens')));
      const anthropic = new AnthropicStream(() => {}); anthropic.push(ANTHROPIC_TEXT.replace('data: {"type":"message_stop"}\n\n', ''));
      rejects(() => { anthropic.finish(); });
      rejects(() => new AnthropicStream(() => {}).push('data: {"type":"error","error":{"message":"upstream secret"}}\n\n'));
    });
  });
}
