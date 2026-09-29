import { ProviderRegistry } from './ProviderRegistry';
import { ChatCompletionsProvider } from './ChatCompletionsProvider';
import { builtinProviderInfos } from '../../model/Provider';

// Explicit composition, not module-load global registration or model-name guessing.
export function createProviderRegistry(): ProviderRegistry {
  const registry = new ProviderRegistry();
  for (const info of builtinProviderInfos()) {
    registry.register(new ChatCompletionsProvider(info, {
      allowHttp: info.id === 'ollama',
      replayReasoning: ['deepseek', 'dashscope', 'zai', 'openai-compatible'].indexOf(info.id) >= 0
    }));
  }
  return registry;
}
