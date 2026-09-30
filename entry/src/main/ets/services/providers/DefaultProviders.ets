import { ProviderRegistry } from './ProviderRegistry';
import { ProtocolProvider } from './ProtocolProvider';
import { builtinProviderInfos } from '../../model/Provider';
import { ProviderProfile, validateProfile } from '../../model/ProviderProfiles';
import { ProviderInfo } from '../../model/Provider';

export function profileProvider(profile: ProviderProfile): ProtocolProvider {
  validateProfile(profile);
  const info: ProviderInfo = { id: profile.id, name: profile.name, protocol: profile.protocol,
    defaultBaseUrl: profile.baseUrl, defaultModel: profile.models[0], models: profile.models,
    noApiKey: profile.noApiKey };
  return new ProtocolProvider(info, { allowHttp: true,
    replayReasoning: profile.presetId !== 'openai' && profile.presetId !== 'ollama' });
}

// Explicit composition, not module-load global registration or model-name guessing.
export function createProviderRegistry(): ProviderRegistry {
  const registry = new ProviderRegistry();
  for (const info of builtinProviderInfos()) {
    registry.register(new ProtocolProvider(info, {
      allowHttp: info.id === 'ollama',
      replayReasoning: ['deepseek', 'dashscope', 'zai', 'openai-compatible'].indexOf(info.id) >= 0
    }));
  }
  return registry;
}
