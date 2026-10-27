import { SearchSource } from './WebSearch';

export type BingPageState = 'results' | 'empty' | 'verification' | 'pending' | 'unexpected_page' | 'invalid_results';
export interface BingSearchPage {
  state: BingPageState;
  sources: SearchSource[];
  candidates: number;
  invalid: number;
}

// Fixed, read-only extraction. Search terms are data, never executable page code.
export function bingSearchScript(query: string, maximum: number): string {
  return `(() => {
    const query = ${JSON.stringify(query)}, maximum = ${maximum};
    const sources = [], seen = new Set();
    let candidates = 0, invalid = 0;
    const result = state => JSON.stringify({ state, sources, candidates, invalid });
    const page = new URL(location.href);
    const bingHost = host => host === 'bing.com' || host === 'www.bing.com' || host === 'cn.bing.com';
    if (page.protocol !== 'https:' || !bingHost(page.hostname)) return result('unexpected_page');
    const visible = node => !!node && node.getClientRects().length > 0 && getComputedStyle(node).visibility !== 'hidden';
    const challenge = [...document.querySelectorAll('#b_captcha, #b_captcha_container, #turnstile-widget, #challenge-form, iframe[src*="captcha"], iframe[src*="challenge"], input[name="captcha"]')].some(visible);
    if (challenge || page.pathname.startsWith('/turing/')) return result('verification');
    if (page.pathname !== '/search' || page.searchParams.get('q')?.trim() !== query) return result('unexpected_page');
    const root = document.querySelector('#b_results');
    if (!root) return result('pending');
    const items = [...root.querySelectorAll('li.b_algo')].filter(visible);
    candidates = items.length;
    for (const item of items) {
      const heading = item.querySelector('h2');
      // Desktop nests the link in h2; mobile ArkWeb results wrap h2 in the link.
      const anchor = heading?.querySelector('a[href]') || heading?.closest('a[href]');
      const title = heading?.textContent.trim();
      if (!anchor || !item.contains(anchor) || !title) { invalid++; continue; }
      try {
        let target = new URL(anchor.href);
        if (bingHost(target.hostname) && target.pathname === '/ck/a') {
          const encoded = target.searchParams.get('u');
          if (!encoded || !encoded.startsWith('a1')) throw new Error('Unknown Bing redirect');
          const bytes = atob(encoded.slice(2).replace(/-/g, '+').replace(/_/g, '/'));
          target = new URL(decodeURIComponent([...bytes].map(c => '%' + c.charCodeAt(0).toString(16).padStart(2, '0')).join('')));
        }
        if (!['http:', 'https:'].includes(target.protocol) || target.username || target.password ||
            (bingHost(target.hostname) && ['/ck/a', '/aclick', '/search'].includes(target.pathname))) throw new Error('Invalid source URL');
        const url = target.href;
        if (seen.has(url)) continue;
        seen.add(url);
        if (sources.length < maximum) sources.push({ url, title: title.slice(0, 500),
          snippet: (item.querySelector('.b_caption p')?.textContent || '').trim().slice(0, 4000) });
      } catch (_) { invalid++; }
    }
    if (invalid) return result('invalid_results');
    if (sources.length) return result('results');
    if (visible(root.querySelector('.b_no'))) return result('empty');
    return result('pending');
  })()`;
}
