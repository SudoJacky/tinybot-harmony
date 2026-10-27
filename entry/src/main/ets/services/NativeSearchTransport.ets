import { ToolFailure, toolHttpFailure } from '../model/ToolFailure';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { SearchConfig, SearchResult, SEARCH_REQUEST_MODEL, validateSearchConfig, searchCredentialAlias } from '../model/WebSearch';
import { ProviderProfile } from '../model/ProviderProfiles';
import { SearchProvider, SearchHttpRequest } from './search/SearchProvider';
import { DeepSeekSearchProvider } from './search/DeepSeekSearchProvider';
import { TavilySearchProvider } from './search/TavilySearchProvider';
import { RequestUsage } from '../model/Usage';
import { Cancellation, RunCancelledError } from './Cancellation';
import { CredentialReader } from './providers/Provider';
import { SearchTransport } from './WebSearchTools';
import { CompatHttp, CompatResponse } from './CompatHttp';

export class NativeSearchTransport implements SearchTransport {
  private config: SearchConfig;
  private credentials: CredentialReader;
  private threadId: string;
  private recordUsage: (record: RequestUsage) => void;
  private profiles: () => ProviderProfile[];
  private provider: SearchProvider;
  constructor(config: SearchConfig, credentials: CredentialReader, threadId: string, recordUsage: (record: RequestUsage) => void,
    profiles: () => ProviderProfile[]) {
    validateSearchConfig(config);
    if (config.provider === 'bing-browser') { throw new Error('Built-in Bing search requires the browser transport.'); }
    this.config = JSON.parse(JSON.stringify(config)) as SearchConfig; this.credentials = credentials; this.threadId = threadId; this.recordUsage = recordUsage;
    this.profiles = profiles; this.provider = config.provider === 'tavily' ? new TavilySearchProvider() : new DeepSeekSearchProvider();
  }
  async search(query: string, maximum: number, cancellation: Cancellation): Promise<SearchResult> {
    cancellation.check();
    try { validateSearchConfig(this.config); } catch (error) { throw new ToolFailure('NOT_CONFIGURED', (error as Error).message, 'check_settings'); }
    if (!this.config.enabled) { throw new ToolFailure('NOT_CONFIGURED', 'Web search is disabled.', 'check_settings'); }
    let alias: string;
    try { alias = searchCredentialAlias(this.config, this.profiles()); } catch (error) { throw new ToolFailure('NOT_CONFIGURED', (error as Error).message, 'check_settings'); }
    const key = await this.credentials.read(alias); cancellation.check();
    if (!key.trim()) { throw new ToolFailure('AUTH_REQUIRED', 'Configure the API Key in the selected provider settings.', 'check_credentials'); }
    const request = this.provider.request(this.config, query, maximum, key);
    // Billing is per request rather than per token, so no usage stream is parsed.
    const record: RequestUsage = { id: util.generateRandomUUID(), provider: this.config.provider + '-search', model: SEARCH_REQUEST_MODEL,
      startedAt: Date.now(), durationMs: 0, status: 'running_or_unknown', origin: { threadId: this.threadId, purpose: 'web_search' } };
    this.recordUsage(record);
    try {
      const body = await this.request(request, cancellation);
      const result = this.provider.parse(body, maximum); record.status = 'complete'; return result;
    } catch (error) { record.status = cancellation.cancelled ? 'cancelled' : 'failed'; throw error as Error; }
    finally { record.durationMs = Date.now() - record.startedAt; this.recordUsage(record); }
  }
  // The search key must never reach a redirect target, so the request refuses redirects on every
  // supported system and a 3xx therefore surfaces as an ordinary HTTP failure.
  private request(input: SearchHttpRequest, cancellation: Cancellation): Promise<string> {
    return new Promise<string>((resolve, reject) => {
      let settled = false; let timer = -1; let unsubscribe = (): void => {}; let abort = (): void => {};
      const finish = (body: string, error?: Error | ToolFailure | RunCancelledError): void => {
        if (settled) { return; } settled = true; clearTimeout(timer); unsubscribe();
        if (error) { abort(); reject(error); } else { resolve(body); }
      };
      timer = setTimeout(() => finish('', new ToolFailure('TIMEOUT', 'Search timed out after 60 seconds.', 'check_connection')), 60000);
      unsubscribe = cancellation.onCancel(() => finish('', new RunCancelledError() as Error));
      if (settled) { return; }
      CompatHttp.request({
        url: input.endpoint, method: 'POST', headers: input.headers, body: input.body,
        connectTimeout: 15000, readTimeout: 60000, maxBytes: 1024 * 1024, dataType: 'string', redirect: 'refuse'
      }, (stop: () => void) => { abort = stop; }).then((response: CompatResponse) => {
        if (response.status === 402) { finish('', new ToolFailure('QUOTA_EXHAUSTED', 'Search was rejected because the account balance is insufficient.', 'check_quota')); return; }
        if (response.status !== 200) { finish('', toolHttpFailure(response.status, 'Search HTTP ' + response.status + '. Check the search service configuration and API Key.', 'search')); return; }
        finish(response.text);
      }).catch((error: Error) => {
        const failure = error as BusinessError;
        finish('', new ToolFailure('NETWORK_ERROR', 'Search network error (' + failure.code + ').', 'check_connection', { nativeCode: failure.code }));
      });
    });
  }
}
