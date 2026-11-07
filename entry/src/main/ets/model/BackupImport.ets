import { AppData } from './Conversation';
import { SessionImportCandidate } from '../services/SessionCandidates';
import { Diagnostics } from './Diagnostics';
import { t } from './I18n';

export async function rollbackBackupActions(actions: (() => Promise<void>)[]): Promise<void> {
  let failure: Error | undefined;
  for (const action of actions) {
    try { await action(); }
    catch (error) {
      if (!failure) { failure = error as Error; } else { failure.message += '; ' + (error as Error).message; }
    }
  }
  if (failure) { throw failure; }
}
export async function rollbackBackupFailure(error: Error, rollback: () => Promise<void>): Promise<void> {
  try { await rollback(); }
  catch (cleanup) {
    Diagnostics.log('error', 'backup', 'rollback_failed', undefined, cleanup as Error);
    error.message += t('；备份回滚未完成：{0}', [(cleanup as Error).message]);
  }
  throw error;
}

// Native backup side effects stay attached to this import, never to persisted chat data.
export interface BackupImportActions {
  prepare(candidate: SessionImportCandidate): Promise<() => Promise<void>>;
  finish(): Promise<void>;
  discard(): Promise<void>;
}
const imports = new WeakMap<AppData, BackupImportActions>();
export function attachBackupImport(data: AppData, actions: BackupImportActions): void { imports.set(data, actions); }
export async function prepareBackupImport(data: AppData, candidate: SessionImportCandidate): Promise<() => Promise<void>> {
  const actions = imports.get(data);
  return actions ? actions.prepare(candidate) : async (): Promise<void> => {};
}
export async function finishBackupImport(data: AppData): Promise<void> {
  const actions = imports.get(data);
  if (actions) { await actions.finish(); imports.delete(data); }
}
export async function discardBackupImport(data: AppData): Promise<void> {
  const actions = imports.get(data);
  if (actions) { await actions.discard(); imports.delete(data); }
}
