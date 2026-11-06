import { ProviderProfile } from '../model/ProviderProfiles';
import { PanelInputs } from '../model/PanelContract';
import { t } from '../model/I18n';
import { BalanceAmount, supportsProviderBalance } from './ProviderBalance';
import { BalanceQueryState, providerBalanceCache } from './ProviderBalanceCache';
import { Cancellation } from './Cancellation';

export interface BalancePanelAccount { id: string; name: string; presetId?: string; }
export interface BalancePanelData {
  accounts: BalancePanelAccount[]; providerId: string; providerName: string;
  amounts: BalanceAmount[]; checkedAt: number; available?: boolean; notice?: string;
}
function identity(profile: ProviderProfile): string {
  return JSON.stringify([profile.protocol, profile.baseUrl, profile.credentialAlias, profile.noApiKey,
    profile.balanceCredentialAlias, profile.balance, profile.enabled]);
}

// Only the native composition root installs profiles. HTML and agent tools receive metadata/results, never credentials.
export class ProviderBalanceSource {
  private static profiles: ProviderProfile[] = [];
  static configure(profiles: ProviderProfile[]): void {
    ProviderBalanceSource.profiles = JSON.parse(JSON.stringify(profiles)) as ProviderProfile[];
  }
  static accounts(): BalancePanelAccount[] {
    return ProviderBalanceSource.profiles.filter((profile) => profile.enabled &&
      supportsProviderBalance(profile.protocol, profile.baseUrl, profile.balance))
      .map((profile): BalancePanelAccount => ({ id: profile.id, name: profile.name, presetId: profile.presetId }));
  }
  static async read(ids: string[], inputs: PanelInputs, cancellation: Cancellation): Promise<BalancePanelData> {
    cancellation.check();
    const selected = inputs['providerId'];
    if (typeof selected !== 'string' || !ids.includes(selected)) { throw new Error(t('请选择卡片允许查询的模型服务。')); }
    const accounts = ProviderBalanceSource.accounts().filter((account) => ids.includes(account.id));
    const profile = ProviderBalanceSource.profiles.find((item) => item.id === selected);
    if (!profile || !accounts.some((account) => account.id === selected)) { throw new Error(t('此模型服务已移除、停用或未配置余额查询。')); }
    const scope = identity(profile);
    let state: BalanceQueryState = { error: '', loading: true };
    const unsubscribe = providerBalanceCache.subscribe(profile, (next: BalanceQueryState) => { state = next; });
    try {
      // The panel scheduler decides when to refresh. Share any in-flight request with the settings UI.
      await providerBalanceCache.refresh(profile, true);
      cancellation.check();
      const current = ProviderBalanceSource.profiles.find((item) => item.id === selected);
      if (!current || identity(current) !== scope) { throw new Error(t('余额查询配置已改变，请重新刷新。')); }
      if (state.error) { throw new Error(state.error); }
      if (!state.result || state.loading) { throw new Error(t('余额查询未完成，请重新刷新。')); }
      const data: BalancePanelData = { accounts: accounts, providerId: profile.id, providerName: profile.name, amounts: state.result.amounts,
        checkedAt: state.result.checkedAt, available: state.result.available, notice: state.result.notice };
      // Panel schemas validate JSON values; optional undefined fields are absent on this boundary.
      return JSON.parse(JSON.stringify(data)) as BalancePanelData;
    } finally { unsubscribe(); }
  }
}
