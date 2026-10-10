import { t } from '../model/I18n';
import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { CredentialStore } from './CredentialStore';
import { McpServer } from '../model/Productivity';
import { Cancellation, RunCancelledError } from './Cancellation';
interface ResourceMetadata { resource: string; authorization_servers: string[]; scopes_supported?: string[]; }
interface AuthMetadata { issuer: string; authorization_endpoint: string; token_endpoint: string; registration_endpoint?: string; code_challenge_methods_supported?: string[]; }
interface Registration { client_id: string; }
interface OAuthTokens { access_token: string; refresh_token?: string; expires_in?: number; token_type: string; }
interface StoredOAuth { resource: string; clientId: string; tokenEndpoint: string; accessToken: string; refreshToken?: string; expiresAt: number; }
const REDIRECT = 'tinybot-harmony://oauth/callback';
function secure(address: string): string {
  if (!/^https:\/\/[^\s/?#@\\]+(?:\/[^\s#\\]*)?$/.test(address)) { throw new Error(t("OAuth 端点必须使用 HTTPS，且不能包含账号或片段。")); }
  return address;
}
function origin(address: string): string { secure(address); return /^https:\/\/[^/]+/.exec(address)?.[0] || ''; }
function encode(values: Record<string, string>): string { return Object.keys(values).map((key) => encodeURIComponent(key) + '=' + encodeURIComponent(values[key])).join('&'); }
export async function oauthJson(address: string, body?: Object | string): Promise<Object> {
  secure(address); const request = http.createHttp();
  try {
    const response = await request.request(address, { method: body === undefined ? http.RequestMethod.GET : http.RequestMethod.POST,
      header: { 'Accept': 'application/json', 'Content-Type': typeof body === 'string' ? 'application/x-www-form-urlencoded' : 'application/json' },
      extraData: body === undefined ? undefined : typeof body === 'string' ? body : JSON.stringify(body), usingCache: false,
      maxRedirects: 0, maxLimit: 1024 * 1024, connectTimeout: 15000, readTimeout: 30000, expectDataType: http.HttpDataType.STRING });
    if (response.responseCode < 200 || response.responseCode >= 300) { throw new Error('OAuth HTTP ' + response.responseCode + t("。请核对服务或已注册的客户端 ID。")); }
    return JSON.parse(response.result as string) as Object;
  } finally { request.destroy(); }
}
async function resourceMetadata(address: string): Promise<ResourceMetadata> {
  const host = origin(address); const path = address.slice(host.length).split('?')[0];
  const request = http.createHttp(); let metadataUrl = '';
  try {
    const response = await request.request(address, { method: http.RequestMethod.GET, maxRedirects: 0, usingCache: false,
      connectTimeout: 15000, readTimeout: 15000, maxLimit: 1024 * 1024, expectDataType: http.HttpDataType.STRING });
    const headers = response.header as Record<string, string>;
    const name = Object.keys(headers).find((key) => key.toLowerCase() === 'www-authenticate');
    if (name && typeof headers[name] === 'string') { metadataUrl = /resource_metadata="([^"]+)"/.exec(headers[name])?.[1] || ''; }
  } finally { request.destroy(); }
  let result: ResourceMetadata;
  if (metadataUrl) { result = await oauthJson(metadataUrl) as ResourceMetadata; }
  else {
    try { result = await oauthJson(host + '/.well-known/oauth-protected-resource' + path) as ResourceMetadata; }
    catch (_) { result = await oauthJson(host + '/.well-known/oauth-protected-resource') as ResourceMetadata; }
  }
  if (!result || result.resource.replace(/\/$/, '') !== address.replace(/\/$/, '') || !Array.isArray(result.authorization_servers) || !result.authorization_servers.length) {
    throw new Error(t("OAuth 资源元数据与当前 MCP 地址不匹配。"));
  }
  return result;
}
function base64url(bytes: Uint8Array): string { return new util.Base64Helper().encodeToStringSync(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, ''); }
export class McpOAuth {
  private static callback?: (value: string) => void;
  private static refreshing: Map<string, Promise<string>> = new Map<string, Promise<string>>();
  static receive(uri: string): void {
    if (uri.startsWith(REDIRECT + '?') && McpOAuth.callback) { try { McpOAuth.callback(uri); } catch (_) { /* Ignore malformed callbacks without consuming the pending login. */ } }
  }
  static async login(server: McpServer, context: common.UIAbilityContext, clientId: string = '', cancellation: Cancellation = new Cancellation()): Promise<string> {
    cancellation.check();
    if (McpOAuth.callback) { throw new Error(t("已有 OAuth 登录正在进行。")); }
    const resource = await resourceMetadata(server.url); const issuer = secure(resource.authorization_servers[0]).replace(/\/$/, '');
    const host = origin(issuer); const path = issuer.slice(host.length);
    let metadata: AuthMetadata;
    try { metadata = await oauthJson(host + '/.well-known/oauth-authorization-server' + path) as AuthMetadata; }
    catch (_) { metadata = await oauthJson(issuer + '/.well-known/openid-configuration') as AuthMetadata; }
    if (metadata.issuer?.replace(/\/$/, '') !== issuer || !metadata.code_challenge_methods_supported?.includes('S256')) { throw new Error(t("OAuth 颁发者不匹配，或服务未声明支持 PKCE S256。")); }
    secure(metadata.authorization_endpoint); secure(metadata.token_endpoint);
    if (!clientId) {
      if (!metadata.registration_endpoint) { throw new Error(t("此服务不支持动态注册，请填写已注册的公开客户端 ID，回调地址为 ") + REDIRECT); }
      const registration: Record<string, Object> = { 'client_name': 'Tinybot Harmony', 'redirect_uris': [REDIRECT],
        'grant_types': ['authorization_code', 'refresh_token'], 'response_types': ['code'], 'token_endpoint_auth_method': 'none' };
      clientId = (await oauthJson(metadata.registration_endpoint, registration) as Registration).client_id;
      if (typeof clientId !== 'string' || !clientId) { throw new Error(t("OAuth 客户端注册未返回 ID。")); }
    }
    const verifier = base64url((await cryptoFramework.createRandom().generateRandom(32)).data);
    const state = base64url((await cryptoFramework.createRandom().generateRandom(32)).data);
    const hash = cryptoFramework.createMd('SHA256'); await hash.update({ data: new util.TextEncoder().encodeInto(verifier) });
    const challenge = base64url((await hash.digest()).data);
    const params: Record<string, string> = { 'response_type': 'code', 'client_id': clientId, 'redirect_uri': REDIRECT,
      'code_challenge': challenge, 'code_challenge_method': 'S256', 'state': state, 'resource': server.url };
    if (resource.scopes_supported?.length) { params['scope'] = resource.scopes_supported.join(' '); }
    const authorization = metadata.authorization_endpoint + (metadata.authorization_endpoint.includes('?') ? '&' : '?') + encode(params);
    cancellation.check();
    const callback = await new Promise<string>((resolve, reject) => {
      let remove = (): void => {};
      const timeout = setTimeout(() => { remove(); McpOAuth.callback = undefined; reject(new Error(t("OAuth 登录等待超过 5 分钟，请重新登录。"))); }, 300000);
      McpOAuth.callback = (value: string) => {
        const values = new Map<string, string>();
        for (const part of value.slice(value.indexOf('?') + 1).split('&')) { const index = part.indexOf('='); if (index > 0) { values.set(decodeURIComponent(part.slice(0, index)), decodeURIComponent(part.slice(index + 1))); } }
        if (values.get('state') !== state) { return; }
        clearTimeout(timeout); remove(); McpOAuth.callback = undefined; resolve(value);
      };
      remove = cancellation.onCancel(() => { clearTimeout(timeout); McpOAuth.callback = undefined; reject(new RunCancelledError()); });
      context.startAbility({ action: 'ohos.want.action.viewData', uri: authorization }).catch(() => { clearTimeout(timeout); remove(); McpOAuth.callback = undefined; reject(new Error(t("无法打开系统浏览器。"))); });
    });
    cancellation.check();
    const code = /[?&]code=([^&]+)/.exec(callback)?.[1];
    if (!code) { throw new Error(t("OAuth 授权被取消或未返回授权码。")); }
    const tokens = await oauthJson(metadata.token_endpoint, encode({ 'grant_type': 'authorization_code', 'client_id': clientId,
      'code': decodeURIComponent(code), 'redirect_uri': REDIRECT, 'code_verifier': verifier, 'resource': server.url })) as OAuthTokens;
    if (!tokens.access_token || tokens.token_type?.toLowerCase() !== 'bearer') { throw new Error(t("OAuth 未返回有效 Bearer 凭据。")); }
    cancellation.check();
    const stored: StoredOAuth = { resource: server.url, clientId: clientId, tokenEndpoint: metadata.token_endpoint,
      accessToken: tokens.access_token, refreshToken: tokens.refresh_token, expiresAt: tokens.expires_in ? Date.now() + tokens.expires_in * 1000 : 0 };
    const alias = 'tinybot-oauth-' + util.generateRandomUUID(); await new CredentialStore().write(alias, JSON.stringify(stored)); return alias;
  }
  static async bearer(server: McpServer): Promise<string> {
    if (server.authType !== 'oauth') { return new CredentialStore().read(server.credentialAlias); }
    const pending = McpOAuth.refreshing.get(server.credentialAlias); if (pending) { return pending; }
    const promise = McpOAuth.refresh(server); McpOAuth.refreshing.set(server.credentialAlias, promise);
    try { return await promise; } finally { McpOAuth.refreshing.delete(server.credentialAlias); }
  }
  private static async refresh(server: McpServer): Promise<string> {
    const vault = new CredentialStore(); const stored = JSON.parse(await vault.read(server.credentialAlias)) as StoredOAuth;
    if (stored.resource !== server.url || !stored.accessToken) { throw new Error(t("OAuth 凭据与服务地址不匹配，请重新登录。")); }
    if (!stored.expiresAt || stored.expiresAt > Date.now() + 60000) { return stored.accessToken; }
    if (!stored.refreshToken) { throw new Error(t("OAuth 凭据已到期，请重新登录。")); }
    const result = await oauthJson(stored.tokenEndpoint, encode({ 'grant_type': 'refresh_token', 'refresh_token': stored.refreshToken,
      'client_id': stored.clientId, 'resource': stored.resource })) as OAuthTokens;
    if (!result.access_token || result.token_type?.toLowerCase() !== 'bearer') { throw new Error(t("OAuth 刷新失败，请重新登录。")); }
    stored.accessToken = result.access_token; stored.refreshToken = result.refresh_token || stored.refreshToken;
    stored.expiresAt = result.expires_in ? Date.now() + result.expires_in * 1000 : 0;
    await vault.update(server.credentialAlias, JSON.stringify(stored)); return stored.accessToken;
  }
}
