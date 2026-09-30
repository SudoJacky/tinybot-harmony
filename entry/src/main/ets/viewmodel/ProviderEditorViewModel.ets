import { ProviderProfile } from '../model/ProviderProfiles';
import { ProviderInfo } from '../model/Provider';

@Observed
export class ProviderEditorViewModel {
  id: string = '';
  name: string = '';
  presetId?: string;
  protocol: string = 'chat-completions';
  baseUrl: string = '';
  apiKey: string = '';
  noApiKey: boolean = false;
  hasSavedKey: boolean = false;
  enabled: boolean = true;
  models: string = '';
  contextWindow: string = '32768';
  error: string = '';

  reset(profile?: ProviderProfile, preset?: ProviderInfo): void {
    this.id = profile?.id || '';
    this.name = profile?.name || preset?.name || '';
    this.presetId = profile?.presetId || preset?.id;
    this.protocol = profile?.protocol || preset?.protocol || 'chat-completions';
    this.baseUrl = profile?.baseUrl || preset?.defaultBaseUrl || '';
    this.apiKey = '';
    this.hasSavedKey = (profile?.credentialAlias || '').length > 0;
    this.noApiKey = profile?.noApiKey === undefined ? preset?.noApiKey === true : profile.noApiKey;
    this.enabled = profile?.enabled === undefined ? true : profile.enabled;
    this.models = profile ? profile.models.join('\n') : (preset?.models || []).join('\n');
    this.contextWindow = (profile?.contextWindow || 32768).toString();
    this.error = '';
  }
}
