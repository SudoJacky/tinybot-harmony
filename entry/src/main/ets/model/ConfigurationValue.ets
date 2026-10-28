// Stored enum values can come from a newer build. Invalid types remain corruption.
export function isConfigurationName(value: string): boolean {
  return typeof value === 'string' && /^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,79}$/.test(value);
}
