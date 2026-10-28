// Merge JSON records without Object.assign (restricted in ArkTS). Explicitly edited
// keys, including undefined removals, win; fields owned by newer builds survive.
export function mergeSavedConfiguration<T>(previous: T | undefined, edited: T): T {
  const before = previous as Object as Record<string, Object>;
  const after = edited as Object as Record<string, Object>;
  const editedKeys = Object.keys(after);
  const keys = Array.from(new Set((previous === undefined ? [] : Object.keys(before)).concat(editedKeys)));
  const parts: string[] = [];
  for (const key of keys) {
    const text = JSON.stringify(editedKeys.includes(key) ? after[key] : before[key]);
    if (text !== undefined) { parts.push(JSON.stringify(key) + ':' + text); }
  }
  return JSON.parse('{' + parts.join(',') + '}') as T;
}
