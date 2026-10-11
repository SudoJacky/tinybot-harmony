import { ToolFailure, toolHttpFailure } from '../model/ToolFailure';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { SearchConfig, SearchResult, validateSearchConfig, searchCredentialAlias } from '../model/WebSearch';
import { ProviderProfile } from '../model/ProviderProfiles';
import { SearchProvider, SearchHttpRequest } from './search/SearchProvider';
import { DeepSeekSearchProvider } from './search/DeepSeekSearchProvider';
import { TavilySearchProvider } from './search/TavilySearchProvider';
import { RequestUsage, UsageStream } from '../model/Usage';
import { Cancellation, RunCancelledError } from './Cancellation';
import { CredentialReader } from './providers/Provider';
import { SearchTransport } from './WebSearchTools';

class RejectSearchRedirect implements http.HttpInterceptor {
  interceptorType: http.InterceptorType = http.InterceptorType.REDIRECTION;
  async interceptorHandle(_request: http.HttpRequestContext, _response: http.HttpResponse): Promise<boolean> { return false; }
}

export class NativeSearchTransport implements SearchTransport {
  private config: SearchConfig;
  private credentials: CredentialReader;
  private threadId: string;
  private recordUsage: (record: RequestUsage) => void;
  private profiles: () => ProviderProfile[];
  private provider: SearchProvider;
  constructor(config: SearchConfig, credentials: CredentialReader, threadId: string, recordUsage: (record: RequestUsage) => void,
    profiles: () => ProviderProfile[]) {
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
    if (!key) { throw new ToolFailure('AUTH_REQUIRED', 'Configure the search API Key in search settings.', 'check_credentials'); }
    const request = this.provider.request(this.config, query, maximum, key);
    const record: RequestUsage = { id: util.generateRandomUUID(), provider: this.config.provider + '-search', model: this.config.model || 'search',
      startedAt: Date.now(), durationMs: 0, status: 'running_or_unknown', origin: { threadId: this.threadId, purpose: 'web_search' } };
    this.recordUsage(record);
    try {
      const body = await this.request(request, cancellation);
      const usage = new UsageStream(); usage.push('data: ' + body.replace(/\r?\n/g, '') + '\n\n'); record.tokens = usage.result();
      const result = this.provider.parse(body, maximum); record.status = 'complete'; return result;
    } catch (error) { record.status = cancellation.cancelled ? 'cancelled' : 'failed'; throw error as Error; }
    finally { record.durationMs = Date.now() - record.startedAt; this.recordUsage(record); }
  }
  private request(input: SearchHttpRequest, cancellation: Cancellation): Promise<string> {
    const request = http.createHttp();
    return new Promise<string>((resolve, reject) => {
      let settled = false; let timer = -1; let unsubscribe = (): void => {};
      const finish = (body: string, error?: Error | ToolFailure | RunCancelledError): void => {
        if (settled) { return; } settled = true; clearTimeout(timer); unsubscribe(); request.destroy();
        if (error) { reject(error); } else { resolve(body); }
      };
      timer = setTimeout(() => finish('', new ToolFailure('TIMEOUT', 'Search timed out after 60 seconds.', 'check_connection')), 60000);
      unsubscribe = cancellation.onCancel(() => finish('', new RunCancelledError() as Error));
      if (settled) { return; }
      try {
        const chain = new http.HttpInterceptorChain();
        if (!chain.addChain([new RejectSearchRedirect()]) || !chain.apply(request)) { throw new ToolFailure('INTERNAL_ERROR', 'Unable to prevent search redirects.', 'inspect_error'); }
        request.request(input.endpoint, {
          method: http.RequestMethod.POST, usingCache: false, expectDataType: http.HttpDataType.STRING,
          maxLimit: 1024 * 1024, maxRedirects: 5, connectTimeout: 15000, readTimeout: 60000,
          header: input.headers, extraData: input.body
        }, (error: BusinessError, response: http.HttpResponse) => {
          if (error) { finish('', new ToolFailure('NETWORK_ERROR', 'Search network error (' + error.code + ').', 'check_connection', { nativeCode: error.code })); return; }
          if (response.responseCode !== 200) { finish('', toolHttpFailure(response.responseCode, 'Search HTTP ' + response.responseCode + '. Check search endpoint, model and API Key.', 'search')); return; }
          if (typeof response.result !== 'string') { finish('', new ToolFailure('INVALID_RESPONSE', 'Search returned invalid data.', 'inspect_service')); return; }
          finish(response.result);
        });
      } catch (error) { finish('', error as Error); }
    });
  }
}
