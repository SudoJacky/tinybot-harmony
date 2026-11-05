import { util } from '@kit.ArkTS';
import { MailAccount, mailId, validateMailAccount } from '../model/Mail';
import { CredentialStore } from './CredentialStore';
import { withFileMutation } from './FileMutationQueue';
import { Cancellation } from './Cancellation';
import { Diagnostics } from '../model/Diagnostics';
interface StoredMailAccount { account: MailAccount; secret: string; revision: string; }
const INDEX: string = 'tinybot-mail-index-v1';
const active: Map<string, Set<Cancellation>> = new Map<string, Set<Cancellation>>();
// The account index, settings and authorization codes are all device-local secure assets.
// No mailbox credentials or connection metadata are written into chat/workspace backups.
export class MailAccounts {
  private vault: CredentialStore = new CredentialStore();
  private async ids(): Promise<string[]> {
    const raw = await this.vault.readOptional(INDEX); if (raw === undefined) { return []; }
    const ids = JSON.parse(raw) as string[];
    if (!Array.isArray(ids) || ids.length > 8 || new Set(ids).size !== ids.length) { throw new Error('Invalid saved mailbox index'); }
    ids.forEach((id: string) => mailId(id)); return ids;
  }
  private async index(ids: string[]): Promise<void> {
    if (await this.vault.readOptional(INDEX) === undefined) { await this.vault.write(INDEX, JSON.stringify(ids)); }
    else { await this.vault.update(INDEX, JSON.stringify(ids)); }
  }
  async connection(id: string): Promise<StoredMailAccount> {
    mailId(id); if (!(await this.ids()).includes(id)) { throw new Error('Mailbox connection no longer exists'); }
    const raw = await this.vault.readOptional('tinybot-mail-' + id); if (!raw) { throw new Error('Mailbox connection is unavailable; reconnect in Settings'); }
    const stored = JSON.parse(raw) as StoredMailAccount; validateMailAccount(stored.account);
    if (stored.account.id !== id || typeof stored.secret !== 'string' || !stored.secret || typeof stored.revision !== 'string') { throw new Error('Invalid saved mailbox connection'); }
    return stored;
  }
  async list(): Promise<MailAccount[]> {
    const result: MailAccount[] = [];
    for (const id of await this.ids()) { result.push((await this.connection(id)).account); } return result;
  }
  private revoke(id: string): void { active.get(id)?.forEach((signal: Cancellation) => signal.cancel()); }
  watch(id: string, signal: Cancellation): () => void {
    let signals = active.get(id); if (!signals) { signals = new Set<Cancellation>(); active.set(id, signals); }
    signals.add(signal);
    return () => { signals!.delete(signal); if (!signals!.size) { active.delete(id); } };
  }
  async save(account: MailAccount, secret: string): Promise<void> {
    validateMailAccount(account);
    await withFileMutation(INDEX, async () => {
      const ids = await this.ids(), exists = ids.includes(account.id), before = exists ? await this.connection(account.id) : undefined;
      const sameServer = before && before.account.host === account.host && before.account.port === account.port && before.account.username === account.username;
      if (!secret && !sameServer) { throw new Error('Enter an authorization code when adding a mailbox or changing its server/account'); }
      const value: StoredMailAccount = { account: account, secret: secret || before!.secret, revision: util.generateRandomUUID() };
      if (/[\u0000-\u001f\u007f]/.test(value.secret)) { throw new Error('Authorization code must not contain control characters'); }
      const text = JSON.stringify(value);
      if (new util.TextEncoder().encodeInto(text).length > 1024) { throw new Error('Mailbox settings exceed the secure storage limit; shorten the name or folder list'); }
      if (!exists && ids.length >= 8) { throw new Error('A maximum of eight mailbox connections is supported'); }
      this.revoke(account.id);
      const alias = 'tinybot-mail-' + account.id;
      if (exists) { await this.vault.update(alias, text); }
      else {
        await this.vault.write(alias, text);
        try { await this.index(ids.concat([account.id])); }
        catch (error) {
          try { await this.vault.remove(alias); } catch (cleanup) { Diagnostics.log('error', 'mail', 'cleanup_failed', {}, cleanup as Error); }
          throw error as Error;
        }
      }
      Diagnostics.log('info', 'mail', 'account_saved', { serverId: account.id, enabled: account.enabled });
    });
  }
  async remove(id: string): Promise<void> {
    mailId(id); await withFileMutation(INDEX, async () => {
      const ids = await this.ids(); this.revoke(id);
      await this.index(ids.filter((value: string) => value !== id));
      await this.vault.remove('tinybot-mail-' + id);
      Diagnostics.log('info', 'mail', 'account_removed', { serverId: id });
    });
  }
}
