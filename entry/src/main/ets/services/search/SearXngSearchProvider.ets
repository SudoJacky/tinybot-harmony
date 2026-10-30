import { ToolFailure, parseToolResponse } from '../../model/ToolFailure';
import { SearchConfig, SearchResult, SearchSource } from '../../model/WebSearch';
import { SearchProvider, SearchHttpRequest } from './SearchProvider';

interface SearXngItem { url: string; title?: string; content?: string; publishedDate?: string; }
interface SearXngResponse { results?: SearXngItem[]; unresponsive_engines?: string[][]; }

export class SearXngSearchProvider implements SearchProvider {
  request(config: SearchConfig, query: string, _maximum: number, _key: string): SearchHttpRequest {
    // SearXNG accepts form data, not JSON. Result limits are applied locally; its API pages results.
    return { endpoint: config.baseUrl!.replace(/\/+$/, '') + '/search',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'Accept': 'application/json' },
      body: 'q=' + encodeURIComponent(query) + '&format=json&categories=general' };
  }
  parse(body: string, maximum: number): SearchResult {
    const response = parseToolResponse(body) as SearXngResponse;
    if (!Array.isArray(response?.results)) {
      throw new ToolFailure('INVALID_RESPONSE', 'SearXNG returned no structured search results. Enable json in search.formats in settings.yml.', 'inspect_service');
    }
    const warnings: string[] = [];
    if (response.unresponsive_engines !== undefined) {
      if (!Array.isArray(response.unresponsive_engines)) { throw new ToolFailure('INVALID_RESPONSE', 'Invalid SearXNG engine errors.', 'inspect_service'); }
      for (const engine of response.unresponsive_engines) {
        if (!Array.isArray(engine) || typeof engine[0] !== 'string' || typeof engine[1] !== 'string') {
          throw new ToolFailure('INVALID_RESPONSE', 'Invalid SearXNG engine error.', 'inspect_service');
        }
        warnings.push('SearXNG engine ' + engine[0] + ': ' + engine[1]);
      }
    }
    const sources: SearchSource[] = []; const seen = new Set<string>();
    for (const item of response.results) {
      if (typeof item?.url !== 'string' || !/^https?:\/\/[^\s/?#@\\]+(?:[/?#][^\s\\]*)?$/.test(item.url)) {
        throw new ToolFailure('INVALID_RESPONSE', 'Invalid search source URL.', 'inspect_service');
      }
      if (seen.has(item.url)) { continue; } seen.add(item.url);
      if (sources.length >= maximum) { continue; }
      sources.push({ url: item.url, title: typeof item.title === 'string' && item.title.trim() ? item.title : item.url,
        snippet: typeof item.content === 'string' ? item.content : '',
        publishedAt: typeof item.publishedDate === 'string' && item.publishedDate ? item.publishedDate : undefined });
    }
    if (!sources.length && warnings.length) { throw new ToolFailure('REMOTE_TOOL_ERROR', warnings.join('; '), 'inspect_service'); }
    return warnings.length ? { sources: sources, warnings: warnings } : { sources: sources };
  }
}
