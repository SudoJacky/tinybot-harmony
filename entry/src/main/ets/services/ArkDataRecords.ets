import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';

export interface StoredRecord { scope: string; id: string; text?: string; }
export interface RecordSize { id: string; bytes: number; }
export type RecordSource = 'local' | 'peer';
type WriteRecord = (record: StoredRecord) => Promise<void>;
const CHUNK_LENGTH = 128 * 1024;
export const LOCAL_DATABASE = 'tinybot.db';
export const DATABASE_KEY_UNAVAILABLE = 14800020;

// A record may hold a long transcript. Keep each SQL row below the ResultSet
// limit, including for UTF-8 text, and never split a UTF-16 surrogate pair.
function chunks(text: string): string[] {
  const parts: string[] = [];
  let start = 0;
  do {
    let end = Math.min(start + CHUNK_LENGTH, text.length);
    const last = text.charCodeAt(end - 1);
    if (end < text.length && last >= 0xd800 && last <= 0xdbff) { end--; }
    parts.push(text.slice(start, end));
    start = end;
  } while (start < text.length);
  return parts;
}

export class ArkDataRecords {
  onCommitted?: (records: StoredRecord[], source: RecordSource) => void;
  private store: relationalStore.RdbStore;
  private writes: Promise<void> = Promise.resolve();

  private constructor(store: relationalStore.RdbStore) { this.store = store; }

  static async open(context: common.UIAbilityContext, name: string = LOCAL_DATABASE): Promise<ArkDataRecords> {
    const store = await relationalStore.getRdbStore(context, {
      name: name, securityLevel: relationalStore.SecurityLevel.S3, encrypt: true
    });
    await store.executeSql('CREATE TABLE IF NOT EXISTS records (scope TEXT NOT NULL, record_id TEXT NOT NULL, part INTEGER NOT NULL, part_count INTEGER NOT NULL, body TEXT NOT NULL, PRIMARY KEY (scope, record_id, part))');
    return new ArkDataRecords(store);
  }

  async read(scope: string, id: string): Promise<string | undefined> {
    const rows = await this.store.querySql('SELECT part, part_count, body FROM records WHERE scope = ? AND record_id = ? ORDER BY part', [scope, id]);
    return this.readParts(rows);
  }

  private readParts(rows: relationalStore.ResultSet): string | undefined {
    try {
      const parts: string[] = [];
      let count = 0;
      while (rows.goToNextRow()) {
        if (!parts.length) { count = rows.getLong(1); }
        if (rows.getLong(0) !== parts.length || rows.getLong(1) !== count) { throw new Error('Invalid ArkData record chunks'); }
        parts.push(rows.getString(2));
      }
      if (parts.length !== count) { throw new Error('Incomplete ArkData record'); }
      return parts.length ? parts.join('') : undefined;
    } finally { rows.close(); }
  }

  async ids(scope: string): Promise<string[]> {
    const rows = await this.store.querySql('SELECT record_id FROM records WHERE scope = ? AND part = 0 ORDER BY record_id', [scope]);
    try {
      const ids: string[] = [];
      while (rows.goToNextRow()) { ids.push(rows.getString(0)); }
      return ids;
    } finally { rows.close(); }
  }

  async sizes(scope: string): Promise<RecordSize[]> {
    const rows = await this.store.querySql('SELECT record_id, SUM(length(CAST(body AS BLOB))) FROM records WHERE scope = ? GROUP BY record_id', [scope]);
    try {
      const result: RecordSize[] = [];
      while (rows.goToNextRow()) { result.push({ id: rows.getString(0), bytes: rows.getLong(1) }); }
      return result;
    } finally { rows.close(); }
  }

  commit(records: StoredRecord[], source: RecordSource = 'local'): Promise<void> {
    if (!records.length) { return Promise.resolve(); }
    const operation = this.writes.then(() => this.transact(async (transaction) => {
      for (const record of records) { await this.replace(transaction, record); }
    })).then(() => { this.onCommitted?.(records, source); });
    this.writes = operation.catch(() => {});
    return operation;
  }

  // A crash leaves either the complete import and its marker, or an empty store.
  async importLegacy(source: (write: WriteRecord) => Promise<void>): Promise<boolean> {
    const version = await this.read('migration', 'version');
    if (version === '1') { return false; }
    if (version !== undefined) { throw new Error('Unsupported ArkData storage version'); }
    return this.transact(async (transaction) => {
      const marker = await transaction.querySql('SELECT part, part_count, body FROM records WHERE scope = ? AND record_id = ? ORDER BY part',
        ['migration', 'version']);
      const current = this.readParts(marker);
      if (current === '1') { return false; }
      if (current !== undefined) { throw new Error('Unsupported ArkData storage version'); }
      await source(async (record) => {
        await this.replace(transaction, record);
        const rows = await transaction.querySql('SELECT part, part_count, body FROM records WHERE scope = ? AND record_id = ? ORDER BY part',
          [record.scope, record.id]);
        if (this.readParts(rows) !== record.text) { throw new Error('ArkData migration readback mismatch'); }
      });
      await this.replace(transaction, { scope: 'migration', id: 'version', text: '1' });
      return true;
    });
  }

  private async transact<T>(write: (transaction: relationalStore.Transaction) => Promise<T>): Promise<T> {
    const transaction = await this.store.createTransaction();
    try {
      const value = await write(transaction);
      await transaction.commit();
      return value;
    } catch (error) {
      try { await transaction.rollback(); }
      catch (rollback) { throw new Error((error as Error).message + ' | rollback: ' + (rollback as Error).message); }
      throw error as Error;
    }
  }

  private async replace(transaction: relationalStore.Transaction, record: StoredRecord): Promise<void> {
    await transaction.execute('DELETE FROM records WHERE scope = ? AND record_id = ?', [record.scope, record.id]);
    if (record.text === undefined) { return; }
    const parts = chunks(record.text);
    for (let part = 0; part < parts.length; part++) {
      await transaction.execute('INSERT INTO records (scope, record_id, part, part_count, body) VALUES (?, ?, ?, ?, ?)',
        [record.scope, record.id, part, parts.length, parts[part]]);
    }
  }
}
