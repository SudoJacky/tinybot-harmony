import { SearchConfig, SearchResult } from '../../model/WebSearch';

export interface SearchHttpRequest { endpoint: string; headers: Record<string, string>; body: string; }
// Providers translate the wire protocol; transport owns cancellation, credentials and I/O.
export interface SearchProvider {
  request(config: SearchConfig, query: string, maximum: number, key: string): SearchHttpRequest;
  parse(body: string, maximum: number): SearchResult;
}
