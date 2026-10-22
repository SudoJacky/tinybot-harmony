import { ProviderEffects } from './Provider';
import { ProtocolProvider } from './ProtocolProvider';
import { ProviderProfile, validateProfile } from '../../model/ProviderProfiles';
import { ProviderInfo, builtinProviderInfos } from '../../model/Provider';

export function profileProvider(profile: ProviderProfile, effects: ProviderEffects): ProtocolProvider {
  validateProfile(profile);
  const info: ProviderInfo = { id: profile.id, name: profile.name, protocol: profile.protocol,
    promptCaching: profile.protocol === 'anthropic-messages' && builtinProviderInfos().some((preset) =>
      preset.id === profile.presetId && preset.promptCaching === true),
    defaultBaseUrl: profile.baseUrl, defaultModel: profile.models[0], models: profile.models,
    noApiKey: profile.noApiKey };
  return new ProtocolProvider(info, effects, { allowHttp: true,
    replayReasoning: profile.presetId !== 'openai' && profile.presetId !== 'ollama' });
}
