import { ProviderEffects } from '../main/ets/services/providers/Provider';
import { ProviderProfile } from '../main/ets/model/ProviderProfiles';
import { ProviderEditorViewModel } from '../main/ets/viewmodel/ProviderEditorViewModel';
import { describe, expect, it } from '@ohos/hypium';
import { ModelMessage, ToolDefinition } from '../main/ets/model/Agent';
import { builtinProviderInfos } from '../main/ets/model/Provider';
import { profileProvider } from '../main/ets/services/providers/DefaultProviders';
import { chatRequest } from '../main/ets/services/providers/ChatCompletionsProtocol';

function rejects(action: () => void): void {
  let rejected = false;
  try { action(); } catch (_) { rejected = true; }
  expect(rejected).assertTrue();
}

export default function providerTests(): void {
  const effects: ProviderEffects = { hydrate: async (messages) => messages, recordUsage: () => {} };
  describe('BuiltInProviders', () => {
    it('buildsConfiguredProvidersThroughTheProductionFactory', 0, () => {
      for (const info of builtinProviderInfos()) {
        const profile: ProviderProfile = { id: 'saved-' + info.id, name: info.name, presetId: info.id,
          protocol: info.protocol, baseUrl: info.defaultBaseUrl || 'https://custom.example/v1',
          models: info.models?.length ? info.models : ['custom-model'], enabled: true, noApiKey: true, credentialAlias: '' };
        const provider = profileProvider(profile, effects);
        expect(provider.info.id).assertEqual(profile.id);
        expect(provider.info.models![0]).assertEqual(profile.models[0]);
        profile.models.push('changed');
        expect(provider.info.models!.includes('changed')).assertFalse();
        expect(provider.endpoint(profile.baseUrl).startsWith(profile.baseUrl)).assertTrue();
      }
    });
    it('allowsExplicitHttpProfilesAndRejectsMalformedEndpoints', 0, () => {
      for (const info of builtinProviderInfos()) {
        const profile: ProviderProfile = { id: 'saved-' + info.id, name: info.name, presetId: info.id,
          protocol: info.protocol, baseUrl: 'http://192.168.1.10:11434/v1', models: ['local-model'],
          enabled: true, noApiKey: true, credentialAlias: '' };
        const provider = profileProvider(profile, effects);
        expect(provider.endpoint(profile.baseUrl).startsWith(profile.baseUrl)).assertTrue();
        for (const invalid of ['', 'ftp://host/v1', 'http://user:pass@host/v1', 'http://host/v1?key=x', 'http://host/v1#key']) {
          rejects(() => { provider.endpoint(invalid); });
        }
      }
    });
    it('initializesTheProductionEditorFromPresets', 0, () => {
      const infos = builtinProviderInfos(); const editor = new ProviderEditorViewModel();
      editor.baseUrl = 'https://old.example/v1'; editor.models = 'old-model';
      editor.reset(undefined, infos.find((info) => info.id === 'ollama'));
      expect(editor.baseUrl).assertEqual(''); expect(editor.models).assertEqual(''); expect(editor.noApiKey).assertTrue();
      editor.reset(undefined, infos.find((info) => info.id === 'dashscope'));
      expect(editor.baseUrl).assertEqual('https://dashscope.aliyuncs.com/compatible-mode/v1');
      expect(editor.modelList[0]).assertEqual('qwen-plus'); expect(editor.noApiKey).assertFalse();
      editor.reset(undefined, infos.find((info) => info.id === 'openai-compatible'));
      expect(editor.baseUrl).assertEqual(''); expect(editor.models).assertEqual('');
    });
    it('replaysVendorReasoningOnlyWhenTheAdapterOptsIn', 0, () => {
      const messages: ModelMessage[] = [
        { role: 'assistant', content: '', reasoningContent: 'fixture context',
          toolCalls: [{ id: 'call_1', type: 'function', function: { name: 'read_file', arguments: '{"path":"a"}' } }] },
        { role: 'tool', content: 'result', toolCallId: 'call_1' }
      ];
      const standard = JSON.stringify(chatRequest('gpt-4.1', messages, []));
      expect(standard.includes('reasoning_content')).assertFalse();
      expect(standard.includes('tool_choice')).assertFalse();
      expect(standard.includes('"tools":')).assertFalse();
      const tools: ToolDefinition[] = [{ type: 'function', function: { name: 'read_file', description: 'read',
        parameters: { type: 'object', properties: {}, required: [], additionalProperties: false } } }];
      const reasoning = chatRequest('glm-5.3', messages, tools, { replayReasoning: true });
      expect(reasoning.messages[0].reasoning_content).assertEqual('fixture context');
      expect(reasoning.messages[1].tool_call_id).assertEqual('call_1');
      expect(reasoning.tool_choice).assertEqual('auto');
      expect(reasoning.tools?.length).assertEqual(1);
      expect(messages[0].reasoningContent).assertEqual('fixture context');
    });
  });
}
