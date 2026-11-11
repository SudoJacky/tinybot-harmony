import { AppData } from '../model/Conversation';
import { Diagnostics } from '../model/Diagnostics';
import { ModelReference, ProviderProfile, modelConfig } from '../model/ProviderProfiles';
import { isOnboardingCandidate } from '../model/Onboarding';
import { t } from '../model/I18n';
import { CredentialVault } from './ProfileSettings';
import { SessionImportCandidate } from './SessionCandidates';
import { BackupConnections } from '../model/BackupConnections';
import { sameCredentialScope } from '../model/ProviderEndpoint';
import { canKeepBalanceCredential } from '../model/BalanceSettings';

export interface ProviderKey { profile: ProviderProfile; apiKey: string; balanceApiKey?: string; }
export interface BackupKeyPayload { providers: ProviderKey[]; selected?: ModelReference; connections?: BackupConnections; }
// Secrets travel from the reader to the committing service in memory only, never in AppData.
const restoredKeys = new WeakMap<AppData, BackupKeyPayload>();
export function attachBackupKeys(data: AppData, payload: BackupKeyPayload): void { restoredKeys.set(data, payload); }

// Existing settings and readable credentials win. Only repair missing assets for the same provider and credential scope.
export async function commitBackupKeys(local: AppData, imported: AppData, candidate: SessionImportCandidate,
  vault: CredentialVault, createId: () => string, commit: (data: AppData) => Promise<void>): Promise<void> {
  const payload = restoredKeys.get(imported);
  if (!payload) { await commit(candidate.data); return; }
  const created: string[] = [];
  const write = async (prefix: string, secret: string): Promise<string> => {
    const alias = prefix + createId();
    await vault.write(alias, secret); created.push(alias);
    return alias;
  };
  try {
    for (const item of payload.providers) {
      const id = candidate.providerIds.get(item.profile.id);
      if (!id) { continue; }
      const index = (candidate.data.providerProfiles || []).findIndex((entry) => entry.id === id);
      if (index < 0) { throw new Error(t('备份密钥与模型服务配置不一致。')); }
      const existing = (local.providerProfiles || []).find((entry) => entry.id === id);
      if (existing) {
        if (existing.id !== item.profile.id ||
          !sameCredentialScope(existing.protocol, existing.baseUrl, item.profile.protocol, item.profile.baseUrl)) { continue; }
        const profile = (candidate.data.providerProfiles as ProviderProfile[])[index];
        if (!existing.noApiKey && item.apiKey && await vault.readOptional(existing.credentialAlias) === undefined) {
          profile.credentialAlias = await write('tinybot-', item.apiKey);
          if (candidate.data.config.providerId === id && candidate.data.config.credentialAlias === existing.credentialAlias) {
            candidate.data.config.credentialAlias = profile.credentialAlias;
          }
        }
        if (item.balanceApiKey && canKeepBalanceCredential(existing, item.profile.protocol, item.profile.baseUrl, item.profile.balance) &&
          await vault.readOptional(existing.balanceCredentialAlias!) === undefined) {
          profile.balanceCredentialAlias = await write('tinybot-balance-', item.balanceApiKey);
        }
        continue;
      }
      const profile = JSON.parse(JSON.stringify(item.profile)) as ProviderProfile;
      profile.id = id; profile.credentialAlias = ''; profile.balanceCredentialAlias = undefined;
      if (!profile.noApiKey) {
        profile.credentialAlias = await write('tinybot-', item.apiKey);
      }
      if (item.balanceApiKey) {
        profile.balanceCredentialAlias = await write('tinybot-balance-', item.balanceApiKey);
      }
      (candidate.data.providerProfiles as ProviderProfile[])[index] = profile;
    }
    if (isOnboardingCandidate(local) && payload.selected) {
      const id = candidate.providerIds.get(payload.selected.providerId);
      const profile = candidate.data.providerProfiles?.find((entry) => entry.id === id && entry.enabled && entry.models.includes(payload.selected?.modelId || ''));
      if (profile) {
        const reference: ModelReference = { providerId: profile.id, modelId: payload.selected.modelId };
        const settings = candidate.data.config;
        candidate.data.config = modelConfig(candidate.data.providerProfiles || [], reference, candidate.data.config);
        candidate.data.config.contextWindow = settings.contextWindow ?? candidate.data.config.contextWindow;
        candidate.data.config.reasoning = settings.reasoning; candidate.data.config.images = settings.images;
        candidate.data.config.requestUsage = settings.requestUsage;
        const active = candidate.data.threads.find((thread) => thread.id === candidate.data.activeThreadId);
        if (active && !active.modelRef) { active.modelRef = reference; }
      }
    }
    await commit(candidate.data);
    restoredKeys.delete(imported);
  } catch (error) {
    Diagnostics.log('error', 'backup', 'restore_failed', { credentialScope: 'backup' }, error as Error);
    let message = (error as Error).message;
    for (const alias of created) {
      try { await vault.remove(alias); }
      catch (cleanupError) {
        Diagnostics.log('error', 'resources', 'credential_rollback_failed', { credentialScope: 'backup' }, cleanupError as Error);
        message += t('；未生效的备份密钥清理失败。');
      }
    }
    throw new Error(message);
  }
}
