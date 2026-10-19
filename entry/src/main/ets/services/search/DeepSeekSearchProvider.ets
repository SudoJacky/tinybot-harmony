import { ToolFailure, parseToolResponse } from '../../model/ToolFailure';
import { DEEPSEEK_SEARCH_ENDPOINT, SearchConfig, SearchResult, SearchSource } from '../../model/WebSearch';
import { SearchProvider, SearchHttpRequest } from './SearchProvider';
interface SearchItem { url?: string; title?: string; snippet?: string; summary?: string; date?: string | null; }
interface SearchErrorBody { code?: string; message?: string; }
interface SearchResponse { results?: SearchItem[]; error?: SearchErrorBody; }
interface SearchQuery { query: string; count: number; need_content: boolean; }

// The Search API returns ranked pages and their own digests; no model answer is treated as evidence.
export function parseSearchResponse(body: string, maximum: number): SearchResult {
  const response = parseToolResponse(body) as SearchResponse;
  if (response?.error) {
    const message = typeof response.error.message === 'string' ? response.error.message.slice(0, 200) : 'unknown error';
    throw new ToolFailure('REMOTE_TOOL_ERROR', 'DeepSeek search failed: ' + message, 'inspect_service');
  }
  if (!Array.isArray(response?.results)) {
    throw new ToolFailure('INVALID_RESPONSE', 'DeepSeek search returned no structured results.', 'inspect_service');
  }
  const sources: SearchSource[] = []; const seen = new Set<string>();
  for (const item of response.results) {
    if (typeof item?.url !== 'string' || !/^https?:\/\/[^\s/?#@\\]+(?:[/?#][^\s\\]*)?$/.test(item.url)) {
      throw new ToolFailure('INVALID_RESPONSE', 'Invalid search source URL.', 'inspect_service');
    }
    if (seen.has(item.url)) { continue; } seen.add(item.url);
    // The requested count is the only limit; titles and digests are passed on as the service returned them.
    if (sources.length >= maximum) { continue; }
    const title = typeof item.title === 'string' && item.title.trim() ? item.title : item.url;
    // `summary` is the long digest written for models; `snippet` is the short display text.
    const snippet = typeof item.summary === 'string' && item.summary ? item.summary :
      typeof item.snippet === 'string' ? item.snippet : '';
    sources.push({ url: item.url, title: title, snippet: snippet,
      publishedAt: typeof item.date === 'string' && item.date ? item.date : undefined });
  }
  return { sources: sources };
}

export function searchRequest(query: string, maximum: number): string {
  const count = Math.min(Math.max(Math.trunc(maximum), 1), 50);
  // Full text is only fetched by read_web, so search responses stay small.
  const body: SearchQuery = { query: query, count: count, need_content: false };
  return JSON.stringify(body);
}

export class DeepSeekSearchProvider implements SearchProvider {
  request(_config: SearchConfig, query: string, maximum: number, key: string): SearchHttpRequest {
    return { endpoint: DEEPSEEK_SEARCH_ENDPOINT,
      headers: { 'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json', 'Accept': 'application/json' },
      body: searchRequest(query, maximum) };
  }
  parse(body: string, maximum: number): SearchResult { return parseSearchResponse(body, maximum); }
}
