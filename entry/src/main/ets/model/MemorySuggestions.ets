import { t } from './I18n';
export function memoryKey(text: string): string { return text.trim().replace(/\s+/g, ' ').toLocaleLowerCase(); }

export function validateMemorySuggestions(items: string[]): string[] {
  if (!Array.isArray(items) || items.length > 5 || items.some((item) => typeof item !== 'string' || !item.trim() || item.trim().length > 200)) {
    throw new Error(t("每次最多保存 5 条记忆，每条需为 1–200 字符。"));
  }
  const keys = new Set<string>();
  return items.map((item) => item.trim()).filter((item) => {
    const key = memoryKey(item); if (keys.has(key)) { return false; } keys.add(key); return true;
  });
}

export function parseMemorySuggestions(text: string): string[] {
  return validateMemorySuggestions(JSON.parse(text.trim().replace(/^```(?:json)?\s*|\s*```$/g, '')) as string[]);
}
