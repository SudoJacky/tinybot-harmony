import { EN_MESSAGES, ZH_MESSAGES } from './LocaleCatalog';

export type AppLanguage = 'system' | 'zh-CN' | 'en';
let currentLocale: string = 'zh-CN';

export function languagePreference(value: string): AppLanguage {
  return value === 'zh-CN' || value === 'en' ? value : 'system';
}
export function resolveLocale(preference: AppLanguage, systemLanguage: string): string {
  const language = preference === 'system' ? systemLanguage : preference;
  return language.toLowerCase().replace(/_/g, '-').split('-')[0] === 'zh' ? 'zh-CN' : 'en';
}
export function setLocale(locale: string): void { currentLocale = resolveLocale('system', locale); }
export function getLocale(): string { return currentLocale; }

// Translate only application-owned message IDs. Never pass user text or model responses here.
// A replacement callback keeps '$&', braces and other characters in arguments literal.
export function t(message: string, values: (string | number)[] = []): string {
  const catalog = currentLocale === 'zh-CN' ? ZH_MESSAGES : EN_MESSAGES;
  const text = catalog[message] !== undefined ? catalog[message] : ZH_MESSAGES[message] !== undefined ? ZH_MESSAGES[message] : message;
  return text.replace(/\{(\d+)\}/g, (match: string, index: string): string => {
    const value = values[Number(index)];
    return value === undefined ? match : String(value);
  });
}
