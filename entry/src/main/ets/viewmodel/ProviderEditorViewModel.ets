import { ProviderProfile, modelIds } from '../model/ProviderProfiles';
import { ProviderInfo, builtinProviderInfos } from '../model/Provider';
import { ProviderDraft } from '../services/ProfileSettings';
import { protocolUrl, sameCredentialScope } from '../model/ProviderEndpoint';
import { t } from '../model/I18n';
import { BalanceSettings, balanceCredentialScope, usesBalanceCredential } from '../model/BalanceSettings';

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
  modelInput: string = '';
  contextWindow: string = '';
  balanceMode: string = 'auto';
  balancePath: string = '/user/balance';
  balanceRemaining: string = 'data.balance';
  balanceTotal: string = '';
  balanceUsed: string = '';
  balanceSuccess: string = '';
  balanceUnit: string = 'USD';
  balanceDivisor: string = '1';
  balanceAuth: string = 'bearer';
  balanceCredential: string = 'provider';
  balanceApiKey: string = '';
  balanceUserId: string = '';
  hasSavedBalanceKey: boolean = false;
  private originalBalanceScope: string = '';
  error: string = '';
  private originalProtocol: string = '';
  private originalUrl: string = '';
  private initial: string = '';

  get apiKeyUrl(): string {
    return this.noApiKey ? '' : builtinProviderInfos().find((info) => info.id === this.presetId)?.apiKeyUrl || '';
  }

  get modelList(): string[] { return this.models.split(/[\n,，]/).map((id: string) => id.trim()).filter((id: string) => id.length > 0); }
  get hasChanges(): boolean { return this.modelInput.trim().length > 0 || JSON.stringify(this.snapshot()) !== this.initial; }
  get canKeepKey(): boolean {
    return this.hasSavedKey && sameCredentialScope(this.originalProtocol, this.originalUrl, this.protocol, this.baseUrl);
  }
  get canKeepBalanceKey(): boolean {
    return this.hasSavedBalanceKey && sameCredentialScope(this.originalProtocol, this.originalUrl, this.protocol, this.baseUrl) &&
      this.originalBalanceScope === balanceCredentialScope(this.balanceSettings());
  }
  get canQueryBalance(): boolean {
    if (this.balanceMode === 'custom' && this.balanceAuth === 'none') { return true; }
    return usesBalanceCredential(this.balanceSettings()) ? !!this.balanceApiKey.trim() || this.canKeepBalanceKey :
      !this.noApiKey && (!!this.apiKey.trim() || this.canKeepKey);
  }
  changeProtocol(protocol: string): void {
    if (protocol === this.protocol) { return; }
    try {
      const endpoint = protocolUrl(this.protocol, this.baseUrl, true);
      // A full endpoint was entered: carry its service root to the new protocol.
      if (/\/(chat\/completions|responses|messages)$/.test(this.baseUrl.trim().replace(/\/+$/, ''))) {
        this.baseUrl = protocolUrl(protocol, endpoint.replace(/\/(chat\/completions|responses|messages)$/, ''), true);
      }
    } catch (_) { /* Keep invalid input visible for the normal URL validation. */ }
    this.protocol = protocol;
  }
  addModels(values: string): void {
    const additions = modelIds(values);
    const next = Array.from(new Set(this.modelList.concat(additions))).join('\n');
    if (next.length > 10000) { throw new Error(t('模型列表过长，请减少选择。')); }
    this.models = next;
  }
  removeModel(id: string): void { this.models = this.modelList.filter((value) => value !== id).join('\n'); }
  fieldError(field: string): string {
    if (field === 'name' && !this.name.trim()) { return t('请填写服务名称。'); }
    if (field === 'url') {
      try { protocolUrl(this.protocol, this.baseUrl, true); } catch (error) { return (error as Error).message; }
    }
    if (field === 'key' && !this.noApiKey && !this.apiKey.trim() && !this.canKeepKey) {
      return this.hasSavedKey ? t('服务基础地址已改变，请重新填写密钥。') : t('请填写 API Key，或在高级设置中选择无需密钥。');
    }
    if (field === 'models') { try { modelIds(this.models); } catch (error) { return (error as Error).message; } }
    if (field === 'context' && this.contextWindow.trim() && (!Number.isInteger(Number(this.contextWindow)) || Number(this.contextWindow) < 8192 || Number(this.contextWindow) > 2000000)) {
      return t('上下文窗口需为 8192–2000000 的整数。');
    }
    return '';
  }

  snapshot(): ProviderDraft {
    return { id: this.id, name: this.name, presetId: this.presetId, protocol: this.protocol, baseUrl: this.baseUrl,
      apiKey: this.apiKey, noApiKey: this.noApiKey, enabled: this.enabled, models: this.models, contextWindow: this.contextWindow,
      balance: this.balanceSettings(), balanceApiKey: this.balanceApiKey };
  }

  balanceSettings(): BalanceSettings | undefined {
    const credential = this.balanceCredential === 'separate' ? 'separate' : undefined;
    if (this.balanceMode === 'auto' && !credential) { return undefined; }
    if (this.balanceMode !== 'custom') { return { mode: this.balanceMode, credential: credential,
      userId: this.balanceMode === 'newapi-account' ? this.balanceUserId.trim() : undefined }; }
    return { mode: 'custom', path: this.balancePath.trim(), remainingField: this.balanceRemaining.trim(),
      totalField: this.balanceTotal.trim() || undefined, usedField: this.balanceUsed.trim() || undefined,
      successField: this.balanceSuccess.trim() || undefined, unit: this.balanceUnit.trim(),
      divisor: Number(this.balanceDivisor), auth: this.balanceAuth, credential: credential };
  }

  get balanceScope(): string {
    return JSON.stringify([this.balanceMode, this.balancePath, this.balanceRemaining, this.balanceTotal,
      this.balanceUsed, this.balanceSuccess, this.balanceUnit, this.balanceDivisor, this.balanceAuth,
      this.balanceCredential, this.balanceApiKey, this.balanceUserId]);
  }

  reset(profile?: ProviderProfile, preset?: ProviderInfo): void {
    this.id = profile?.id || '';
    this.name = profile?.name || preset?.name || '';
    this.presetId = profile?.presetId || preset?.id;
    this.protocol = profile?.protocol || preset?.protocol || 'chat-completions';
    this.baseUrl = profile?.baseUrl || preset?.defaultBaseUrl || '';
    this.apiKey = '';
    this.modelInput = '';
    this.hasSavedKey = (profile?.credentialAlias || '').length > 0;
    this.noApiKey = profile?.noApiKey === undefined ? preset?.noApiKey === true : profile.noApiKey;
    this.enabled = profile?.enabled === undefined ? true : profile.enabled;
    this.models = profile ? profile.models.join('\n') : (preset?.models || []).join('\n');
    this.contextWindow = profile?.contextWindow === undefined ? '' : String(profile.contextWindow);
    this.balanceMode = profile?.balance?.mode || 'auto';
    this.balancePath = profile?.balance?.path || '/user/balance';
    this.balanceRemaining = profile?.balance?.remainingField || 'data.balance';
    this.balanceTotal = profile?.balance?.totalField || '';
    this.balanceUsed = profile?.balance?.usedField || '';
    this.balanceSuccess = profile?.balance?.successField || '';
    this.balanceUnit = profile?.balance?.unit || 'USD';
    this.balanceDivisor = String(profile?.balance?.divisor === undefined ? 1 : profile.balance.divisor);
    this.balanceAuth = profile?.balance?.auth || 'bearer';
    this.balanceCredential = profile?.balance?.credential || 'provider';
    this.balanceApiKey = '';
    this.balanceUserId = profile?.balance?.userId || '';
    this.hasSavedBalanceKey = usesBalanceCredential(profile?.balance) && !!profile?.balanceCredentialAlias;
    this.originalBalanceScope = balanceCredentialScope(profile?.balance);
    this.error = '';
    this.originalProtocol = this.protocol; this.originalUrl = this.baseUrl;
    this.initial = JSON.stringify(this.snapshot());
  }
}
