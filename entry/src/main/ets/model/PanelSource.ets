import { PanelInputs } from './PanelContract';
import { PanelSourceTransform, pointerParts, validatePanelSourceTransform } from './PanelTransform';
import { MailQuery, validateMailQuery } from './Mail';
export interface PanelOAuth { clientId: string; authorizationEndpoint: string; tokenEndpoint: string; scopes?: string[]; resource?: string; }
export interface PanelAuth { type: string; name?: string; in?: string; prefix?: string; oauth?: PanelOAuth; }
export interface PanelSource {
  type: string; url?: string; path?: string; pointer?: string; method?: string; headers?: Record<string, string>;
  body?: Object; auth?: PanelAuth; transform?: PanelSourceTransform;
  prompt?: string; query?: Record<string, string>;
  mail?: MailQuery;
  workspaceId?: string;
  providerIds?: string[];
}
function fields(value: Object, allowed: string[]): void {
  if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).some((key: string) => !allowed.includes(key))) { throw new Error('Invalid source fields'); }
}
export function panelHttps(address: string): string {
  if (typeof address !== 'string' || !/^https:\/\/[^\s/?#@\\]+(?:[/?][^\s#\\]*)?$/.test(address)) { throw new Error('API endpoints require HTTPS without credentials or fragments'); } return address;
}
export function validatePanelSource(source: PanelSource): void {
  fields(source, ['type', 'url', 'path', 'pointer', 'method', 'headers', 'body', 'auth', 'transform', 'prompt', 'mail', 'workspaceId', 'query', 'providerIds']);
  if (source.type === 'provider-balance') {
    if (Object.keys(source).some((key) => !['type', 'providerIds'].includes(key)) || !Array.isArray(source.providerIds) ||
      !source.providerIds.length || source.providerIds.length > 100 || new Set(source.providerIds).size !== source.providerIds.length ||
      source.providerIds.some((id: string) => typeof id !== 'string' || !/^[a-z0-9][a-z0-9_-]{0,63}$/.test(id))) {
      throw new Error('Provider balance source requires only type and 1–100 unique configured providerIds');
    }
    return;
  }
  if (source.providerIds !== undefined) { throw new Error('providerIds requires source type provider-balance'); }
  if (source.query !== undefined && (!['api', 'json-url'].includes(source.type) || !source.query || typeof source.query !== 'object' || Array.isArray(source.query) || Object.keys(source.query).length > 16 || Object.keys(source.query).some((key: string) => !/^[A-Za-z][A-Za-z0-9_]{0,63}$/.test(key) || typeof source.query![key] !== 'string'))) { throw new Error('query maps up to 16 URL query names to declared input names'); }
  if (source.workspaceId !== undefined && (source.type !== 'workspace-json' || typeof source.workspaceId !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(source.workspaceId))) { throw new Error('source.workspaceId requires a valid workspace-json owner'); }
  if (source.type === 'mail') {
    if (Object.keys(source).some((key: string) => !['type', 'mail', 'pointer', 'transform'].includes(key))) { throw new Error('Mail source accepts only mail query, pointer and transform'); }
    validateMailQuery(source.mail!);
    if (source.pointer !== undefined) { pointerParts(source.pointer); }
    if (source.transform !== undefined) { validatePanelSourceTransform(source.transform); } return;
  }
  if (source.mail !== undefined) { throw new Error('mail requires source type mail'); }
  if (source.type === 'agent') {
    if (typeof source.prompt !== 'string' || !source.prompt.trim() || source.prompt.length > 4000 ||
      Object.keys(source).some((key: string) => !['type', 'prompt'].includes(key))) { throw new Error('Agent source requires only type:agent and a prompt of 1–4000 characters'); }
    return;
  }
  if (source.prompt !== undefined) { throw new Error('prompt requires source type agent'); }
  if (source.type === 'workspace-json') {
    if (typeof source.path !== 'string' || !source.path.endsWith('.json') || source.url !== undefined) { throw new Error('Workspace source requires a JSON path'); }
  } else if (['api', 'json-url'].includes(source.type)) {
    panelHttps(source.url!); if (source.path !== undefined) { throw new Error('Remote API sources cannot include a workspace path'); }
  } else { throw new Error('Unsupported panel source type'); }
  if (source.type !== 'api' && [source.method, source.headers, source.body, source.auth].some((field: Object | undefined) => field !== undefined)) { throw new Error('Request options require source type api'); }
  if (source.method !== undefined && !['GET', 'POST'].includes(source.method)) { throw new Error('Only GET and POST query APIs are supported'); }
  if (source.body !== undefined && (source.method !== 'POST' || JSON.stringify(source.body).length > 64 * 1024)) { throw new Error('JSON body requires POST and a maximum of 64 KiB'); }
  if (source.headers !== undefined) {
    if (!source.headers || typeof source.headers !== 'object' || Array.isArray(source.headers) || Object.keys(source.headers).length > 16) { throw new Error('Expected up to 16 custom headers'); }
    const seen: Set<string> = new Set<string>();
    for (const name of Object.keys(source.headers)) {
      const key = name.toLowerCase(), value = source.headers[name];
      if (!/^[A-Za-z0-9!#$%&'*+.^_`|~-]+$/.test(name) || seen.has(key) ||
        ['authorization', 'proxy-authorization', 'cookie', 'host', 'content-length', 'connection', 'transfer-encoding', 'x-api-key'].includes(key) ||
        typeof value !== 'string' || value.length > 2048 || /[\r\n]/.test(value)) { throw new Error('Invalid, duplicate or credential-bearing custom header'); }
      if (key === 'content-type' && value.toLowerCase() !== 'application/json') { throw new Error('POST body uses application/json'); }
      seen.add(key);
    }
  }
  if (source.auth !== undefined) {
    const auth = source.auth; fields(auth, ['type', 'name', 'in', 'prefix', 'oauth']);
    if (!['api-key', 'bearer', 'oauth'].includes(auth.type)) { throw new Error('Unsupported API authentication'); }
    if (auth.type === 'api-key') {
      if (!['header', 'query'].includes(auth.in || '') || typeof auth.name !== 'string' || !/^[A-Za-z0-9_-]{1,80}$/.test(auth.name) || auth.oauth !== undefined) { throw new Error('API key requires in:header/query and a parameter name'); }
      if (auth.in === 'header' && ['host', 'content-length', 'connection', 'transfer-encoding', 'content-type'].includes(auth.name.toLowerCase())) { throw new Error('Invalid API key header'); }
      if (auth.in === 'header' && source.headers && Object.keys(source.headers).some((key: string) => key.toLowerCase() === auth.name!.toLowerCase())) { throw new Error('Authentication header conflicts with custom headers'); }
      if (auth.in === 'query' && (source.url!.split('?')[1] || '').split('&').some((part: string) => decodeURIComponent(part.split('=')[0].replace(/\+/g, ' ')) === auth.name)) { throw new Error('Remove the credential query parameter from the configured URL; it is injected from secure storage'); }
      if (auth.prefix !== undefined && (typeof auth.prefix !== 'string' || auth.prefix.length > 32 || /[\r\n]/.test(auth.prefix))) { throw new Error('Invalid API key prefix'); }
    } else {
      if (auth.name !== undefined || auth.in !== undefined || auth.prefix !== undefined) { throw new Error('Bearer/OAuth use Authorization: Bearer'); }
    }
    if (auth.type === 'oauth') {
      const oauth = auth.oauth!; fields(oauth, ['clientId', 'authorizationEndpoint', 'tokenEndpoint', 'scopes', 'resource']);
      if (typeof oauth.clientId !== 'string' || !oauth.clientId.trim() || oauth.clientId.length > 512) { throw new Error('OAuth requires a registered public client ID'); }
      panelHttps(oauth.authorizationEndpoint); panelHttps(oauth.tokenEndpoint);
      if (oauth.resource !== undefined) { panelHttps(oauth.resource); }
      if (oauth.scopes !== undefined && (!Array.isArray(oauth.scopes) || oauth.scopes.length > 32 || oauth.scopes.some((scope: string) => typeof scope !== 'string' || !/^[\x21\x23-\x5B\x5D-\x7E]{1,128}$/.test(scope)))) { throw new Error('Invalid OAuth scopes'); }
    } else if (auth.oauth !== undefined) { throw new Error('OAuth configuration requires auth type oauth'); }
  }
  if (source.pointer !== undefined) { pointerParts(source.pointer); }
  if (source.transform !== undefined) { validatePanelSourceTransform(source.transform); }
}

export function panelQueryAddress(source: PanelSource, inputs: PanelInputs = {}): string {
  let address = source.url!;
  for (const key of Object.keys(source.query || ({} as Record<string, string>))) {
    const value = inputs[source.query![key]];
    if (value === undefined) { throw new Error('Missing query input: ' + source.query![key]); }
    if ((address.split('?')[1] || '').split('&').some((part: string) => decodeURIComponent(part.split('=')[0]) === key) || source.auth?.in === 'query' && source.auth.name === key) { throw new Error('Query input conflicts with configured URL or authentication: ' + key); }
    address += (address.includes('?') ? '&' : '?') + encodeURIComponent(key) + '=' + encodeURIComponent(String(value));
  }
  return address;
}
