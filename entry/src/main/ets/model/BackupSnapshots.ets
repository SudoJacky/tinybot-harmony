export interface BackupSnapshot { name: string; deviceId: string; createdAt: number; }
const SNAPSHOT = /^tinybot-device-([0-9a-f-]{36})-(\d{13})-([0-9a-f-]{36})\.tinybot$/;
export function backupSnapshot(name: string): BackupSnapshot | undefined {
  const match = name.match(SNAPSHOT);
  return match ? { name: name, deviceId: match[1], createdAt: Number(match[2]) } : undefined;
}
export function expiredBackupSnapshots(names: string[], deviceId: string, retain: number = 3): string[] {
  const snapshots: BackupSnapshot[] = [];
  for (const name of names) { const item = backupSnapshot(name); if (item?.deviceId === deviceId) { snapshots.push(item); } }
  return snapshots.sort((a, b) => b.createdAt - a.createdAt || b.name.localeCompare(a.name)).slice(retain).map((item) => item.name);
}
