import { validateWebAddress } from '../services/WebTools';

export function browserAddress(input: string): string {
  const value = input.trim();
  // Preserve explicit HTTP addresses, including links to local development servers.
  if (/^https?:\/\//i.test(value)) { return validateWebAddress(value); }
  const authority = value.split(/[/?#]/)[0];
  const local = /^(localhost|127(?:\.\d{1,3}){3}|\[::1\])(?::\d+)?$/i.test(authority);
  const host = /^(?:[a-z\d](?:[a-z\d-]*[a-z\d])?\.)+[a-z\d](?:[a-z\d-]*[a-z\d])?(?::\d+)?$/i.test(authority);
  if (local || host) { return validateWebAddress((local ? 'http://' : 'https://') + value); }
  if (!value || value.length > 4096 || /[\u0000-\u001f\\]/.test(value) || /^[a-z][a-z\d+.-]*:/i.test(value)) {
    return validateWebAddress(value);
  }
  return validateWebAddress('https://www.bing.com/search?q=' + encodeURIComponent(value));
}

export interface BrowserStartPreview {
  id: string;
  messageId: string;
  title: string;
}
