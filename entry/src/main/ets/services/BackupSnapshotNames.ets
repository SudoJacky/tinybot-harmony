import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';

export function backupDeviceId(context: common.UIAbilityContext): string {
  const store = preferences.getPreferencesSync(context, { name: 'tinybot-backup-origin' });
  let id = store.getSync('deviceId', '') as string;
  if (!id) { id = util.generateRandomUUID(); store.putSync('deviceId', id); store.flushSync(); }
  if (!/^[0-9a-f-]{36}$/.test(id)) { throw new Error('Invalid backup device identity'); }
  return id;
}
export function newBackupSnapshot(context: common.UIAbilityContext, previousCreatedAt: number = 0): string {
  const createdAt = Math.max(Date.now(), previousCreatedAt + 1);
  return 'tinybot-config-' + backupDeviceId(context) + '-' + createdAt + '-' + util.generateRandomUUID() + '.tinybot';
}
