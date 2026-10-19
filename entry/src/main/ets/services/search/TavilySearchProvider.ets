import { ToolFailure, parseToolResponse } from '../../model/ToolFailure';
import { SearchConfig, SearchResult, SearchSource } from '../../model/WebSearch';
import { SearchProvider, SearchHttpRequest } from './SearchProvider';

interface TavilyItem { url: string; title?: string; content?: string; published_date?: string; }
interface TavilyResponse { results?: TavilyItem[]; }
export class TavilySearchProvider implements SearchProvider {
  request(config: SearchConfig, query: string, maximum: number, key: string): SearchHttpRequest {
    return { endpoint: config.baseUrl!.replace(/\/+$/, '') + '/search',
      headers: { 'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json', 'Accept': 'application/json' },
      body: JSON.stringify({ query: query, max_results: maximum, search_depth: 'basic',
        include_answer: false, include_raw_content: false, include_images: false }) };
  }
  parse(body: string, maximum: number): SearchResult {
    const response = parseToolResponse(body) as TavilyResponse;
    if (!Array.isArray(response?.results)) { throw new ToolFailure('INVALID_RESPONSE', 'Tavily returned no structured search results.', 'inspect_service'); }
    const sources: SearchSource[] = []; const seen = new Set<string>();
    for (const item of response.results) {
      if (typeof item?.url !== 'string' || !/^https?:\/\/[^\s/?#@\\]+(?:[/?#][^\s\\]*)?$/.test(item.url)) { throw new ToolFailure('INVALID_RESPONSE', 'Invalid search source URL.', 'inspect_service'); }
      if (seen.has(item.url)) { continue; } seen.add(item.url);
      if (sources.length >= maximum) { continue; }
      const title = typeof item.title === 'string' ? item.title : item.url;
      const snippet = typeof item.content === 'string' ? item.content : '';
      sources.push({ url: item.url, title: title, snippet: snippet,
        publishedAt: typeof item.published_date === 'string' ? item.published_date : undefined });
    }
    return { sources: sources };
  }
}
