import { AppData } from '../model/Conversation';
import { Diagnostics } from '../model/Diagnostics';
import { ModelReference, ProviderProfile, modelConfig } from '../model/ProviderProfiles';
import { isOnboardingCandidate } from '../model/Onboarding';
import { t } from '../model/I18n';
import { CredentialVault } from './ProfileSettings';
import { SessionImportCandidate } from './SessionCandidates';

export interface ProviderKey { profile: ProviderProfile; apiKey: string; }
export interface BackupKeyPayload { providers: ProviderKey[]; selected?: ModelReference; }
// Secrets travel from the reader to the committing service in memory only, never in AppData.
const restoredKeys = new WeakMap<AppData, BackupKeyPayload>();
export function attachBackupKeys(data: AppData, payload: BackupKeyPayload): void { restoredKeys.set(data, payload); }

// Local matching providers always win. New credentials are rolled back if the snapshot commit fails.
export async function commitBackupKeys(local: AppData, imported: AppData, candidate: SessionImportCandidate,
  vault: CredentialVault, createId: () => string, commit: (data: AppData) => Promise<void>): Promise<void> {
  const payload = restoredKeys.get(imported);
  if (!payload) { await commit(candidate.data); return; }
  const created: string[] = [];
  try {
    for (const item of payload.providers) {
      const id = candidate.providerIds.get(item.profile.id);
      if (!id || (local.providerProfiles || []).some((entry) => entry.id === id)) { continue; }
      const index = (candidate.data.providerProfiles || []).findIndex((entry) => entry.id === id);
      if (index < 0) { throw new Error(t('备份密钥与模型服务配置不一致。')); }
      const profile = JSON.parse(JSON.stringify(item.profile)) as ProviderProfile;
      profile.id = id; profile.credentialAlias = '';
      if (!profile.noApiKey) {
        profile.credentialAlias = 'tinybot-' + createId(); created.push(profile.credentialAlias);
        await vault.write(profile.credentialAlias, item.apiKey);
      }
      (candidate.data.providerProfiles as ProviderProfile[])[index] = profile;
    }
    if (isOnboardingCandidate(local) && payload.selected) {
      const id = candidate.providerIds.get(payload.selected.providerId);
      const profile = candidate.data.providerProfiles?.find((entry) => entry.id === id && entry.enabled && entry.models.includes(payload.selected?.modelId || ''));
      if (profile) {
        const reference: ModelReference = { providerId: profile.id, modelId: payload.selected.modelId };
        candidate.data.config = modelConfig(candidate.data.providerProfiles || [], reference, candidate.data.config);
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
