import { BingSearchPage } from '../model/BingSearch';
import { SearchResult } from '../model/WebSearch';
import { ToolFailure, ToolFailureDetails } from '../model/ToolFailure';
import { t } from '../model/I18n';
import { BrowserSession } from './BrowserSession';
import { Cancellation, RunCancelledError } from './Cancellation';
import { SearchTransport } from './WebSearchTools';

export class BrowserSearchTransport implements SearchTransport {
  private browser?: BrowserSession;
  private threadId: string;
  private running: boolean = false;
  constructor(browser: BrowserSession | undefined, threadId: string) { this.browser = browser; this.threadId = threadId; }
  async search(query: string, maximum: number, cancellation: Cancellation): Promise<SearchResult> {
    cancellation.check();
    if (!this.browser) { throw new ToolFailure('BROWSER_UNAVAILABLE', 'Built-in search requires the in-app browser.', 'check_settings'); }
    if (this.running) { throw new ToolFailure('BROWSER_BUSY', 'A built-in search is already running.', 'wait_for_owner'); }
    this.running = true;
    try {
      await this.browser.acquire(this.threadId, 'https://www.bing.com/search?q=' + encodeURIComponent(query),
        t('内置搜索需要使用浏览器访问必应并读取搜索结果。'), cancellation);
      cancellation.check();
      let deadline = Date.now() + 10000;
      let handedOff = false;
      while (true) {
        const page = await this.browser.readBingSearch(query, maximum, cancellation);
        if (page.state === 'results' || page.state === 'empty') { return { sources: page.sources }; }
        if (page.state === 'verification' && !handedOff) {
          await this.browser.requestHandoff(t('必应需要验证。请在浏览器中完成验证，保留当前搜索页面，然后交还控制。'), cancellation);
          handedOff = true; deadline = Date.now() + 10000; continue;
        }
        if (page.state !== 'pending' || Date.now() >= deadline) { throw this.failure(page); }
        await this.delay(cancellation);
      }
    } finally { this.running = false; }
  }
  private failure(page: BingSearchPage): ToolFailure {
    const details: ToolFailureDetails = { service: 'bing-browser', version: '1', result: page };
    if (page.state === 'verification') {
      return new ToolFailure('SEARCH_VERIFICATION_REQUIRED', 'Bing verification is still present after handoff.', 'complete_browser_verification', details);
    }
    if (page.state === 'unexpected_page') {
      return new ToolFailure('SEARCH_PAGE_CHANGED', 'The browser is no longer showing the requested Bing search.', 'inspect_browser_before_retry', details);
    }
    return new ToolFailure('SEARCH_LAYOUT_CHANGED', 'Bing results could not be extracted (extractor=1, candidates=' + page.candidates +
      ', invalid=' + page.invalid + '). Inspect the search page; this is not an empty result.', 'inspect_browser', details);
  }
  private delay(cancellation: Cancellation): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => { remove(); resolve(); }, 250);
      const remove = cancellation.onCancel(() => { clearTimeout(timer); reject(new RunCancelledError()); });
    });
  }
}
