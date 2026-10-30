import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { Diagnostics } from '../model/Diagnostics';
import { util } from '@kit.ArkTS';
import { AppData } from '../model/Conversation';
import { ModelReference, ProviderProfile, validateProfile } from '../model/ProviderProfiles';
import { t } from '../model/I18n';
import { CredentialVault } from './ProfileSettings';
import { BackupKeyPayload, ProviderKey } from './BackupKeyRestore';

export interface EncryptedBackupKeys { version: number; salt: string; iv: string; ciphertext: string; }
const ITERATIONS = 600000;
function aad(version: number): Uint8Array { return new util.TextEncoder().encodeInto('tinybot-provider-keys-v' + version); }

async function derive(accountInput: string, salt: Uint8Array): Promise<cryptoFramework.SymKey> {
  const params: cryptoFramework.PBKDF2Spec = { algName: 'PBKDF2', password: accountInput, salt: salt,
    iterations: ITERATIONS, keySize: 32 };
  const material = await cryptoFramework.createKdf('PBKDF2|SHA256').generateSecret(params);
  try { return await cryptoFramework.createSymKeyGenerator('AES256').convertKey(material); }
  finally { material.data.fill(0); }
}
export async function encryptBackupKeys(data: AppData, openID: string, vault: CredentialVault): Promise<EncryptedBackupKeys> {
  if (!openID) { throw new Error(t('请登录创建备份时使用的华为账号。')); }
  const providers: ProviderKey[] = [];
  for (const source of data.providerProfiles || []) {
    const profile = JSON.parse(JSON.stringify(source)) as ProviderProfile;
    const secret = source.noApiKey ? '' : await vault.read(source.credentialAlias);
    if (!source.noApiKey && !secret) { throw new Error(t('无法读取模型服务的 API Key，备份未创建。')); }
    profile.credentialAlias = '';
    providers.push({ profile: profile, apiKey: secret });
  }
  const selected: ModelReference | undefined = data.config.configured ? { providerId: data.config.providerId, modelId: data.config.model } : undefined;
  const payload: BackupKeyPayload = { providers: providers, selected: selected };
  const random = cryptoFramework.createRandom();
  const salt = (await random.generateRandom(16)).data; const iv = (await random.generateRandom(12)).data;
  const key = await derive('tinybot-backup-openid-v2:' + openID, salt);
  const plaintext = new util.TextEncoder().encodeInto(JSON.stringify(payload));
  try {
    const params: cryptoFramework.GcmParamsSpec = { algName: 'GcmParamsSpec', iv: { data: iv },
      aad: { data: aad(2) }, authTag: { data: new Uint8Array(16) } };
    const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
    await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, key, params);
    const result = await cipher.doFinal({ data: plaintext });
    const base64 = new util.Base64Helper();
    return { version: 2, salt: base64.encodeToStringSync(salt), iv: base64.encodeToStringSync(iv), ciphertext: base64.encodeToStringSync(result.data) };
  } finally { plaintext.fill(0); key.clearMem(); }
}
export async function decryptBackupKeys(value: EncryptedBackupKeys, credential: string, data: AppData): Promise<BackupKeyPayload> {
  if (!value || value.version !== 2 || typeof value.salt !== 'string' || typeof value.iv !== 'string' || typeof value.ciphertext !== 'string') {
    throw new Error(t('备份密钥格式无效。'));
  }
  if (!credential) { throw new Error(t('请登录创建备份时使用的华为账号。')); }
  const base64 = new util.Base64Helper();
  const salt = base64.decodeSync(value.salt), iv = base64.decodeSync(value.iv), bytes = base64.decodeSync(value.ciphertext);
  if (salt.length !== 16 || iv.length !== 12 || bytes.length <= 16) { throw new Error(t('备份密钥格式无效。')); }
  const key = await derive('tinybot-backup-openid-v2:' + credential, salt);
  let plaintext: Uint8Array;
  try {
    const params: cryptoFramework.GcmParamsSpec = { algName: 'GcmParamsSpec', iv: { data: iv },
      aad: { data: aad(value.version) }, authTag: { data: bytes.slice(-16) } };
    const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
    await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, key, params);
    try { plaintext = (await cipher.doFinal({ data: bytes.slice(0, -16) })).data; }
    catch (error) {
      Diagnostics.log('error', 'backup', 'key_decrypt_failed', undefined, error as Error);
      throw new Error(t('当前华为账号与备份不匹配，或加密的 API Key 已损坏。'));
    }
  } finally { key.clearMem(); }
  let payload: BackupKeyPayload;
  try { payload = JSON.parse(new util.TextDecoder('utf-8', { fatal: true }).decodeToString(plaintext)) as BackupKeyPayload; }
  finally { plaintext.fill(0); }
  if (!payload || !Array.isArray(payload.providers) || payload.providers.length !== (data.providerProfiles || []).length) {
    throw new Error(t('备份密钥格式无效。'));
  }
  const ids = new Set<string>();
  for (const item of payload.providers) {
    if (!item || !item.profile || typeof item.apiKey !== 'string') { throw new Error(t('备份密钥格式无效。')); }
    const profile = item.profile;
    profile.credentialAlias = profile.noApiKey ? '' : 'pending-backup-key';
    validateProfile(profile, true);
    const visible = data.providerProfiles?.find((entry) => entry.id === profile.id);
    // Authenticate the destination as well as the key: edits to the public metadata must not redirect secrets.
    if (ids.has(profile.id) || !visible || visible.protocol !== profile.protocol || visible.baseUrl !== profile.baseUrl ||
      (profile.noApiKey ? item.apiKey.length !== 0 : item.apiKey.length === 0)) { throw new Error(t('备份密钥与模型服务配置不一致。')); }
    ids.add(profile.id);
  }
  if (payload.selected && (!ids.has(payload.selected.providerId) || typeof payload.selected.modelId !== 'string')) {
    throw new Error(t('备份密钥格式无效。'));
  }
  return payload;
}
