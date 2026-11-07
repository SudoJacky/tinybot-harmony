import { t } from '../model/I18n';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { common } from '@kit.AbilityKit';
import { PanelSource, validatePanelSource } from '../model/PanelSource';
import { CredentialStore } from './CredentialStore';
import { McpOAuth, OAuthConfiguration } from './McpOAuth';
import { Cancellation } from './Cancellation';
import { withFileMutation } from './FileMutationQueue';
interface PanelCredential { scope: string; secret?: string; oauthAlias?: string; }
export interface PanelConnectionSecret { secret?: string; oauth?: string; }
interface CredentialScope {
  url: string; method: string; type: string; name: string; location: string; prefix: string;
  clientId: string; authorizationEndpoint: string; tokenEndpoint: string; scopes: string[]; resource: string;
}
function scope(source: PanelSource): string {
  validatePanelSource(source);
  if (source.type !== 'api' || !source.auth) { throw new Error('This panel has no API authentication'); }
  const auth = source.auth, oauth = auth.oauth;
  const value: CredentialScope = { url: source.url!, method: source.method || 'GET', type: auth.type,
    name: auth.in === 'header' ? (auth.name || '').toLowerCase() : auth.name || '', location: auth.in || '', prefix: auth.prefix || '',
    clientId: oauth?.clientId || '', authorizationEndpoint: oauth?.authorizationEndpoint || '', tokenEndpoint: oauth?.tokenEndpoint || '',
    scopes: (oauth?.scopes || []).slice().sort(), resource: oauth?.resource || '' };
  return JSON.stringify(value);
}
// Plaintext credentials stay in the vault; portable backups carry them only inside account encryption.
export class PanelCredentials {
  private namespace: string;
  private vault: CredentialStore = new CredentialStore();
  constructor(namespace: string) { this.namespace = namespace; }
  private async alias(id: string): Promise<string> {
    const digest = cryptoFramework.createMd('SHA256');
    await digest.update({ data: new util.TextEncoder().encodeInto(this.namespace + '/' + id) });
    return 'tinybot-panel-' + Array.from((await digest.digest()).data).map((value: number) => value.toString(16).padStart(2, '0')).join('');
  }
  private async read(id: string, source: PanelSource): Promise<PanelCredential | undefined> {
    const expected = scope(source), raw = await this.vault.readOptional(await this.alias(id));
    if (raw === undefined) { return undefined; }
    const stored = JSON.parse(raw) as PanelCredential;
    if (stored.scope !== expected) { return undefined; }
    return stored;
  }
  async connected(id: string, source: PanelSource): Promise<boolean> {
    const stored = await this.read(id, source);
    if (!stored) { return false; }
    return source.auth!.type === 'oauth' ? !!stored.oauthAlias && (await this.vault.readOptional(stored.oauthAlias)) !== undefined : !!stored.secret;
  }
  async backup(id: string, source: PanelSource): Promise<PanelConnectionSecret | undefined> {
    const stored = await this.read(id, source);
    if (!stored) { return undefined; }
    if (stored.oauthAlias) { return { oauth: await this.vault.read(stored.oauthAlias) }; }
    return stored.secret ? { secret: stored.secret } : undefined;
  }
  async restore(id: string, source: PanelSource, value: PanelConnectionSecret): Promise<boolean> {
    if (await this.vault.readOptional(await this.alias(id)) !== undefined) { return false; }
    if (source.auth?.type === 'oauth') {
      if (!value.oauth) { throw new Error('Missing backed-up OAuth connection'); }
      const saved = JSON.parse(value.oauth) as OAuthBackupResource;
      if (saved.resource !== source.url || saved.tokenEndpoint !== source.auth.oauth?.tokenEndpoint || saved.clientId !== source.auth.oauth?.clientId ||
        typeof saved.accessToken !== 'string' || !saved.accessToken || !Number.isFinite(saved.expiresAt)) { throw new Error('OAuth backup scope mismatch'); }
      const alias = 'tinybot-oauth-' + util.generateRandomUUID();
      await this.vault.write(alias, value.oauth);
      try { await this.store(id, { scope: scope(source), oauthAlias: alias }); }
      catch (error) { await this.vault.remove(alias); throw error as Error; }
    } else { await this.save(id, source, value.secret || ''); }
    return true;
  }
  async secret(id: string, source: PanelSource): Promise<string> {
    const stored = await this.read(id, source);
    if (!stored) { throw new Error(t('API 尚未连接，请在卡片选项中打开「API 连接」。')); }
    if (source.auth!.type === 'oauth') {
      if (!stored.oauthAlias) { throw new Error(t('OAuth 连接不可用，请重新连接卡片。')); }
      try { return await McpOAuth.bearer({ url: source.url!, authType: 'oauth', credentialAlias: stored.oauthAlias }); }
      catch (_) { throw new Error(t('OAuth 凭据无法读取或续期，请重新连接卡片。')); }
    }
    if (!stored.secret) { throw new Error(t('API 凭据不可用，请重新连接卡片。')); } return stored.secret;
  }
  async save(id: string, source: PanelSource, secret: string): Promise<void> {
    if (!['api-key', 'bearer'].includes(source.auth?.type || '') || !secret.trim() || secret.length > 8192 || /[\r\n]/.test(secret)) { throw new Error(t('请输入有效的 API Key 或 Bearer Token，不能包含换行。')); }
    await this.store(id, { scope: scope(source), secret: secret.trim() });
  }
  async login(id: string, source: PanelSource, context: common.UIAbilityContext, cancellation: Cancellation): Promise<void> {
    scope(source);
    if (source.auth?.type !== 'oauth' || !source.auth.oauth) { throw new Error('Missing OAuth configuration'); }
    const oauth = source.auth.oauth;
    const config: OAuthConfiguration = { clientId: oauth.clientId, authorizationEndpoint: oauth.authorizationEndpoint,
      tokenEndpoint: oauth.tokenEndpoint, scopes: oauth.scopes, resource: oauth.resource };
    const alias = await McpOAuth.loginConfigured(source.url!, config, context, cancellation);
    try { await this.store(id, { scope: scope(source), oauthAlias: alias }); }
    catch (error) { await this.vault.remove(alias); throw error as Error; }
  }
  private async store(id: string, value: PanelCredential): Promise<void> {
    const alias = await this.alias(id);
    await withFileMutation(alias, async () => {
      const raw = await this.vault.readOptional(alias), previous = raw ? JSON.parse(raw) as PanelCredential : undefined;
      if (raw === undefined) { await this.vault.write(alias, JSON.stringify(value)); }
      else { await this.vault.update(alias, JSON.stringify(value)); }
      if (previous?.oauthAlias && previous.oauthAlias !== value.oauthAlias) { await this.vault.remove(previous.oauthAlias); }
    });
  }
  async disconnect(id: string): Promise<void> {
    const alias = await this.alias(id);
    await withFileMutation(alias, async () => {
      const raw = await this.vault.readOptional(alias), stored = raw ? JSON.parse(raw) as PanelCredential : undefined;
      if (stored?.oauthAlias) { await this.vault.remove(stored.oauthAlias); }
      await this.vault.remove(alias);
    });
  }
}
interface OAuthBackupResource { resource: string; tokenEndpoint: string; clientId: string; accessToken: string; expiresAt: number; }
