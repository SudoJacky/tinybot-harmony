import { describe, expect, it } from '@ohos/hypium';
import { ModelMessage, ToolDefinition } from '../main/ets/model/Agent';
import { defaultConfig } from '../main/ets/model/Conversation';
import { builtinProviderInfos, providerDraft } from '../main/ets/model/Provider';
import { createProviderRegistry } from '../main/ets/services/providers/DefaultProviders';
import { chatRequest } from '../main/ets/services/providers/ChatCompletionsProtocol';

function rejects(action: () => void): void {
  let rejected = false;
  try { action(); } catch (_) { rejected = true; }
  expect(rejected).assertTrue();
}

export default function providerTests(): void {
  describe('BuiltInProviders', () => {
    it('registersDesktopPresetsAndKeepsUserFacingCatalogIndependent', 0, () => {
      const registry = createProviderRegistry();
      expect(registry.list().map((info) => info.id).join(',')).assertEqual('deepseek,dashscope,openai,zai,ollama,openai-compatible,openai-responses,anthropic');
      const info = registry.require(defaultConfig().providerId).info;
      expect(defaultConfig().baseUrl).assertEqual(info.defaultBaseUrl);
      expect(defaultConfig().model).assertEqual(info.defaultModel);
      const copy = registry.list();
      copy[0].models?.push('changed');
      expect(registry.require('deepseek').info.models?.indexOf('changed')).assertEqual(-1);
      expect(registry.require('dashscope').endpoint(registry.require('dashscope').info.defaultBaseUrl))
        .assertEqual('https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions');
      expect(registry.require('zai').endpoint(registry.require('zai').info.defaultBaseUrl))
        .assertEqual('https://open.bigmodel.cn/api/paas/v4/chat/completions');
    });
    it('allowsHttpOnlyForTheExplicitOllamaRegistration', 0, () => {
      const registry = createProviderRegistry();
      const localUrl = 'http://192.168.1.10:11434/v1';
      expect(registry.require('ollama').endpoint(localUrl)).assertEqual(localUrl + '/chat/completions');
      expect(registry.require('ollama').endpoint('https://ollama.example/v1/')).assertEqual('https://ollama.example/v1/chat/completions');
      for (const info of registry.list()) {
        if (info.id !== 'ollama') { rejects(() => { registry.require(info.id).endpoint(localUrl); }); }
      }
      for (const invalid of ['', 'ftp://host/v1', 'http://user:pass@host/v1', 'http://host/v1?key=x',
        'http://host/v1#key', 'http://host\\@other/v1']) {
        rejects(() => { registry.require('ollama').endpoint(invalid); });
      }
    });
    it('clearsCloudDefaultsForOllamaAndRetainsExplicitCustomDrafts', 0, () => {
      const infos = builtinProviderInfos();
      const local = providerDraft(infos[4], 'https://old.example/v1', 'old-model');
      expect(local.baseUrl).assertEqual('');
      expect(local.model).assertEqual('');
      expect(local.noApiKey).assertTrue();
      const cloud = providerDraft(infos[1], 'http://local:11434/v1', 'local-model');
      expect(cloud.baseUrl).assertEqual(infos[1].defaultBaseUrl);
      expect(cloud.model).assertEqual('qwen-plus');
      expect(cloud.noApiKey).assertFalse();
      const custom = providerDraft(infos[5], 'https://proxy.example/v1', 'custom-model');
      expect(custom.baseUrl).assertEqual('https://proxy.example/v1');
      expect(custom.model).assertEqual('custom-model');
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
