import { getLocale } from '../model/I18n';
import { DetailedError } from '../model/DetailedError';
import { BalanceSettings } from '../model/BalanceSettings';
import { ProviderProfile } from '../model/ProviderProfiles';
import { ProviderDraft } from './ProfileSettings';
import { ProviderBalance, queryProviderBalance } from './ProviderBalance';

export interface BalanceQueryState { result?: ProviderBalance; error: string; loading: boolean; }
interface BalanceCacheEntry {
  key: string;
  state: BalanceQueryState;
  attemptedAt: number;
  pending?: Promise<void>;
  listeners: Array<(state: BalanceQueryState) => void>;
}
export const BALANCE_CACHE_MS: number = 5 * 60 * 1000;

function settingsKey(value?: BalanceSettings): string {
  return JSON.stringify([value?.mode || 'auto', value?.credential || 'provider', value?.userId, value?.auth || 'bearer',
    value?.path, value?.remainingField, value?.totalField, value?.usedField, value?.successField, value?.unit, value?.divisor]);
}

export function balanceProfileDraft(profile: ProviderProfile): ProviderDraft {
  return { id: profile.id, name: profile.name, protocol: profile.protocol, baseUrl: profile.baseUrl,
    apiKey: '', noApiKey: profile.noApiKey, enabled: profile.enabled, models: profile.models.join('\n'),
    contextWindow: profile.contextWindow === undefined ? '' : String(profile.contextWindow), balance: profile.balance };
}

// Draft secrets never enter cache keys. Unsaved queries remain local to their editor.
export function savedBalanceProfile(draft: ProviderDraft, profiles: ProviderProfile[]): ProviderProfile | undefined {
  if (draft.apiKey.trim() || draft.balanceApiKey?.trim()) { return undefined; }
  return profiles.find((profile) => profile.id === draft.id && profile.protocol === draft.protocol &&
    profile.baseUrl === draft.baseUrl && profile.noApiKey === draft.noApiKey &&
    settingsKey(profile.balance) === settingsKey(draft.balance));
}

export function failedBalanceState(previous: ProviderBalance | undefined, error: Error): BalanceQueryState {
  const details = error as DetailedError;
  const discard = details.httpStatus === 401 || details.httpStatus === 403 || details.code === 'INVALID_RESPONSE' || details.stage === 'credential_read';
  return { result: discard ? undefined : previous, error: error.message, loading: false };
}

// One entry per provider, in memory only. Identity checks discard completions after replacement/deletion.
export class ProviderBalanceCache {
  private entries: Map<string, BalanceCacheEntry> = new Map<string, BalanceCacheEntry>();
  private entry(profile: ProviderProfile): BalanceCacheEntry {
    const key = JSON.stringify([profile.protocol, profile.baseUrl, profile.credentialAlias, profile.noApiKey,
      profile.balanceCredentialAlias, settingsKey(profile.balance), getLocale()]);
    let entry = this.entries.get(profile.id);
    if (!entry || entry.key !== key) {
      entry = { key: key, state: { error: '', loading: false }, attemptedAt: 0, listeners: [] };
      this.entries.set(profile.id, entry);
    }
    return entry;
  }
  subscribe(profile: ProviderProfile, listener: (state: BalanceQueryState) => void): () => void {
    const entry = this.entry(profile);
    entry.listeners.push(listener); listener(entry.state);
    return () => { entry.listeners = entry.listeners.filter((item) => item !== listener); };
  }
  invalidate(id: string): void { this.entries.delete(id); }
  private publish(entry: BalanceCacheEntry): void { entry.listeners.forEach((listener) => listener(entry.state)); }
  async refresh(profile: ProviderProfile, force: boolean = false): Promise<void> {
    const entry = this.entry(profile);
    if (entry.pending) { return entry.pending; }
    if (!force && entry.attemptedAt > 0 && Date.now() - entry.attemptedAt < BALANCE_CACHE_MS) { return; }
    entry.attemptedAt = Date.now();
    entry.state = { result: entry.state.result, error: '', loading: true };
    this.publish(entry);
    const pending = this.perform(profile, entry);
    entry.pending = pending;
    await pending;
  }
  private async perform(profile: ProviderProfile, entry: BalanceCacheEntry): Promise<void> {
    try {
      const result = await queryProviderBalance(balanceProfileDraft(profile), [profile]);
      if (this.entries.get(profile.id) !== entry) { return; }
      entry.state = { result: result, error: '', loading: false };
    } catch (error) {
      if (this.entries.get(profile.id) !== entry) { return; }
      entry.state = failedBalanceState(entry.state.result, error as Error);
    } finally {
      entry.pending = undefined;
      if (this.entries.get(profile.id) === entry) { this.publish(entry); }
    }
  }
}
export const providerBalanceCache: ProviderBalanceCache = new ProviderBalanceCache();
