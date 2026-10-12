import { ToolFailure, parseToolResponse } from '../../model/ToolFailure';
import { DEEPSEEK_SEARCH_BASE_URL, DEEPSEEK_SEARCH_MODEL, SearchConfig, SearchResult, SearchSource } from '../../model/WebSearch';
import { SearchProvider, SearchHttpRequest } from './SearchProvider';
interface SearchItem { type: string; url: string; title?: string; page_age?: string; }
interface Citation { url?: string; cited_text?: string; }
interface SearchBlock { type: string; content?: SearchItem[]; citations?: Citation[]; }
interface SearchResponse { content?: SearchBlock[]; }


interface SearchText { type: string; text: string; }
interface SearchMessage { role: string; content: SearchText[]; }
interface SearchTool { type: string; name: string; max_uses: number; }
interface DeepSeekSearchRequest { model: string; max_tokens: number; messages: SearchMessage[]; tools: SearchTool[]; }
export function parseSearchResponse(body: string, maximum: number): SearchResult {
  const response = parseToolResponse(body) as SearchResponse;
  if (!Array.isArray(response?.content)) { throw new ToolFailure('INVALID_RESPONSE', 'DeepSeek search returned no structured content.', 'inspect_service'); }
  const blocks = response.content.filter((block) => block?.type === 'web_search_tool_result');
  if (!blocks.length) { throw new ToolFailure('CAPABILITY_UNAVAILABLE', 'DeepSeek did not return native web search results. Check the selected DeepSeek provider and account search capability.', 'check_settings'); }
  const snippets = new Map<string, string>();
  for (const block of response.content) {
    if (block?.type !== 'text' || !Array.isArray(block.citations)) { continue; }
    for (const citation of block.citations) {
      if (typeof citation?.url === 'string' && typeof citation.cited_text === 'string' && !snippets.has(citation.url)) {
        snippets.set(citation.url, citation.cited_text);
      }
    }
  }
  const sources: SearchSource[] = []; const seen = new Set<string>(); let truncated = false;
  for (const block of blocks) {
    if (!Array.isArray(block.content)) { throw new ToolFailure('INVALID_RESPONSE', 'DeepSeek native web search failed or returned invalid results.', 'inspect_service'); }
    for (const item of block.content) {
      if (item?.type !== 'web_search_result') { throw new ToolFailure('REMOTE_TOOL_ERROR', 'DeepSeek native web search returned a tool error.', 'inspect_service'); }
      if (typeof item.url !== 'string' || !/^https?:\/\/[^\s/?#@\\]+(?:[/?#][^\s\\]*)?$/.test(item.url)) { throw new ToolFailure('INVALID_RESPONSE', 'Invalid search source URL.', 'inspect_service'); }
      if (seen.has(item.url)) { continue; } seen.add(item.url);
      if (sources.length >= maximum) { truncated = true; continue; }
      const title = typeof item.title === 'string' ? item.title : item.url;
      const snippet = snippets.get(item.url) || '';
      if (title.length > 300 || snippet.length > 1500) { truncated = true; }
      sources.push({ url: item.url, title: title.slice(0, 300), snippet: snippet.slice(0, 1500),
        publishedAt: typeof item.page_age === 'string' ? item.page_age.slice(0, 120) : undefined });
    }
  }
  return { sources: sources, truncated: truncated };
}

// Same native server tool contract as DeepSeek Harness; no free-form answer is used as evidence.
export function searchRequest(query: string): string {
  const body: DeepSeekSearchRequest = { model: DEEPSEEK_SEARCH_MODEL, max_tokens: 4096,
    messages: [{ role: 'user', content: [{ type: 'text', text: 'Perform a web search for the query: ' + query }] }],
    tools: [{ type: 'web_search_20250305', name: 'web_search', max_uses: 5 }] };
  return JSON.stringify(body);
}

export class DeepSeekSearchProvider implements SearchProvider {
  request(_config: SearchConfig, query: string, _maximum: number, key: string): SearchHttpRequest {
    return { endpoint: DEEPSEEK_SEARCH_BASE_URL + '/messages',
      headers: { 'x-api-key': key, 'Authorization': 'Bearer ' + key, 'anthropic-version': '2023-06-01',
        'Content-Type': 'application/json', 'Accept': 'application/json' }, body: searchRequest(query) };
  }
  parse(body: string, maximum: number): SearchResult { return parseSearchResponse(body, maximum); }
}
