import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { AppearanceOptions, validateAppearance } from '../model/Appearance';
import { RequestUsage } from '../model/Usage';
import { languagePreference } from '../model/I18n';
import { UsageLedger } from './UsageLedger';

export interface BackupDeviceState {
  appearance?: AppearanceOptions; language?: string; automaticBackup?: boolean; reviewHistory?: string;
  seenAnnouncements?: string[]; feedbackSeen?: Record<string, string>;
  usage: RequestUsage[];
}
export function validateBackupDeviceState(state: BackupDeviceState): void {
  if (!state || typeof state !== 'object' || !Array.isArray(state.usage)) { throw new Error('Invalid backup device state'); }
  if (state.appearance) { validateAppearance(state.appearance); }
  if (state.language !== undefined && !['system', 'zh-CN', 'en'].includes(state.language)) { throw new Error('Invalid backup language'); }
  if (state.automaticBackup !== undefined && typeof state.automaticBackup !== 'boolean') { throw new Error('Invalid backup preference'); }
  if (state.seenAnnouncements !== undefined && (!Array.isArray(state.seenAnnouncements) || state.seenAnnouncements.some((id) => typeof id !== 'string'))) { throw new Error('Invalid announcement history'); }
  if (state.feedbackSeen !== undefined && (!state.feedbackSeen || typeof state.feedbackSeen !== 'object' || Array.isArray(state.feedbackSeen) ||
    Object.keys(state.feedbackSeen).some((id) => typeof state.feedbackSeen![id] !== 'string'))) { throw new Error('Invalid feedback view state'); }
  if (state.reviewHistory !== undefined) {
    const value = JSON.parse(state.reviewHistory) as ReviewHistory;
    if (!Number.isFinite(value.completedTasks) || !Number.isFinite(value.lastAskedAt) || typeof value.stopped !== 'boolean') { throw new Error('Invalid review history'); }
  }
  const ids = new Set<string>();
  for (const item of state.usage) {
    if (!item || typeof item.id !== 'string' || !item.id || ids.has(item.id) || typeof item.provider !== 'string' || typeof item.model !== 'string' ||
      !Number.isFinite(item.startedAt) || !Number.isFinite(item.durationMs) || typeof item.status !== 'string') { throw new Error('Invalid backup usage record'); }
    ids.add(item.id);
  }
}
interface ReviewHistory { completedTasks: number; lastAskedAt: number; stopped: boolean; }
let refreshPreferences: () => void = () => {};
export function configureBackupPreferenceRefresh(refresh: () => void): void { refreshPreferences = refresh; }
export async function captureBackupDeviceState(context: common.UIAbilityContext): Promise<BackupDeviceState> {
  const store = preferences.getPreferencesSync(context, { name: 'tinybot-ui' });
  const state: BackupDeviceState = { usage: await UsageLedger.backup(context.getApplicationContext().filesDir) };
  const appearance = store.getSync('appearance', '') as string, language = store.getSync('language', '') as string;
  if (appearance) { state.appearance = JSON.parse(appearance) as AppearanceOptions; }
  if (language) { state.language = languagePreference(language); }
  const review = store.getSync('reviewInvitation', '') as string;
  if (review) { state.reviewHistory = review; }
  state.seenAnnouncements = store.getSync('seenAnnouncementIds', []) as string[];
  state.feedbackSeen = JSON.parse(preferences.getPreferencesSync(context, { name: 'tinybot-feedback' }).getSync('seenReplies', '{}') as string) as Record<string, string>;
  validateBackupDeviceState(state); return state;
}
export async function mergeBackupDeviceState(context: common.UIAbilityContext, state: BackupDeviceState | undefined): Promise<void> {
  if (!state) { return; }
  validateBackupDeviceState(state);
  await UsageLedger.restoreBackup(context.getApplicationContext().filesDir, state.usage);
  const store = preferences.getPreferencesSync(context, { name: 'tinybot-ui' });
  const changes: PreferenceChange[] = [];
  const add = (key: string, value: string | boolean | string[] | undefined): void => {
    if (value !== undefined && store.getSync(key, 'missing') === 'missing') { changes.push({ key: key, value: value }); }
  };
  add('appearance', state.appearance ? JSON.stringify(state.appearance) : undefined);
  add('language', state.language); add('reviewInvitation', state.reviewHistory);
  const seen = store.getSync('seenAnnouncementIds', []) as string[];
  const mergedSeen = Array.from(new Set(seen.concat(state.seenAnnouncements || [])));
  if (mergedSeen.length !== seen.length) { changes.push({ key: 'seenAnnouncementIds', value: mergedSeen }); }
  if (changes.length) {
    try { changes.forEach((item: PreferenceChange) => store.putSync(item.key, item.value)); store.flushSync(); }
    catch (error) { changes.forEach((item: PreferenceChange) => {
      if (item.key === 'seenAnnouncementIds') { store.putSync(item.key, seen); } else { store.deleteSync(item.key); }
    }); store.flushSync(); throw error as Error; }
  }
  const feedback = preferences.getPreferencesSync(context, { name: 'tinybot-feedback' });
  const original = feedback.getSync('seenReplies', '{}') as string, replies = JSON.parse(original) as Record<string, string>;
  const savedReplies: Record<string, string> = state.feedbackSeen || {};
  for (const id of Object.keys(savedReplies)) { if (replies[id] === undefined) { replies[id] = savedReplies[id]; } }
  if (JSON.stringify(replies) !== original) {
    try { feedback.putSync('seenReplies', JSON.stringify(replies)); feedback.flushSync(); }
    catch (error) { feedback.putSync('seenReplies', original); feedback.flushSync(); throw error as Error; }
  }
  refreshPreferences();
}
interface PreferenceChange { key: string; value: string | boolean | string[]; }
