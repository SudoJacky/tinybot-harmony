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
    cancellation.check(); validateSearchConfig(this.config);
    if (!this.config.enabled) { throw new Error('Web search is disabled.'); }
    const key = await this.credentials.read(searchCredentialAlias(this.config, this.profiles())); cancellation.check();
    if (!key) { throw new Error('Configure the search API Key in search settings.'); }
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
      const finish = (body: string, error?: Error): void => {
        if (settled) { return; } settled = true; clearTimeout(timer); unsubscribe(); request.destroy();
        if (error) { reject(error); } else { resolve(body); }
      };
      timer = setTimeout(() => finish('', new Error('Search timed out after 60 seconds.')), 60000);
      unsubscribe = cancellation.onCancel(() => finish('', new RunCancelledError() as Error));
      if (settled) { return; }
      try {
        const chain = new http.HttpInterceptorChain();
        if (!chain.addChain([new RejectSearchRedirect()]) || !chain.apply(request)) { throw new Error('Unable to prevent search redirects.'); }
        request.request(input.endpoint, {
          method: http.RequestMethod.POST, usingCache: false, expectDataType: http.HttpDataType.STRING,
          maxLimit: 1024 * 1024, maxRedirects: 5, connectTimeout: 15000, readTimeout: 60000,
          header: input.headers, extraData: input.body
        }, (error: BusinessError, response: http.HttpResponse) => {
          if (error) { finish('', new Error('Search network error (' + error.code + ').')); return; }
          if (response.responseCode !== 200) { finish('', new Error('Search HTTP ' + response.responseCode + '. Check search endpoint, model and API Key.')); return; }
          if (typeof response.result !== 'string') { finish('', new Error('Search returned invalid data.')); return; }
          finish(response.result);
        });
      } catch (_) { finish('', new Error('Unable to create search request.')); }
    });
  }
}
