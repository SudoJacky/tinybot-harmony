import { MailAccount, MailQuery, MailSnapshot, MailBody, validateMailQuery } from '../model/Mail';
import { MailAccounts } from './MailAccounts';
import { ImapClient, ImapTransport } from './ImapClient';
import { NativeImapTransport } from './NativeImapTransport';
import { Cancellation } from './Cancellation';
import { NetworkTransfers } from './NetworkTransfers';
import { Diagnostics } from '../model/Diagnostics';
import { imapNumber } from '../model/ImapWire';
export class MailService {
  private accounts: MailAccounts;
  private createTransport: () => ImapTransport;
  constructor(accounts: MailAccounts = new MailAccounts(), createTransport: () => ImapTransport = () => new NativeImapTransport()) { this.accounts = accounts; this.createTransport = createTransport; }
  async available(): Promise<MailAccount[]> { return (await this.accounts.list()).filter((account: MailAccount) => account.enabled); }
  private async run<T>(id: string, body: boolean, cancellation: Cancellation, operation: (client: ImapClient) => Promise<T>): Promise<T> {
    cancellation.check(); const signal = new Cancellation(), unlink = cancellation.onCancel(() => signal.cancel()), unwatch = this.accounts.watch(id, signal);
    let client: ImapClient | undefined; let end: () => Promise<void> = async (): Promise<void> => {};
    const started = Date.now();
    try {
      const connection = await this.accounts.connection(id); signal.check();
      if (!connection.account.enabled) { throw new Error('Mailbox access is disabled in Settings'); }
      if (body && !connection.account.allowBody) { throw new Error('Email body access is disabled in Settings'); }
      end = await NetworkTransfers.begin(signal); signal.check();
      client = new ImapClient(this.createTransport(), signal);
      Diagnostics.log('info', 'mail', 'query_started', { serverId: id });
      await client.login(connection.account, connection.secret);
      const result = await operation(client); signal.check();
      if ((await this.accounts.connection(id)).revision !== connection.revision) { throw new Error('Mailbox settings changed; query again'); }
      signal.check(); Diagnostics.log('info', 'mail', 'query_complete', { serverId: id, elapsedMs: Date.now() - started }); return result;
    } catch (error) {
      Diagnostics.log('error', 'mail', 'query_failed', { serverId: id, cancelled: signal.cancelled, elapsedMs: Date.now() - started }, error as Error);
      throw error as Error;
    } finally { try { await client?.close(); } finally { unlink(); unwatch(); await end(); } }
  }
  async query(query: MailQuery, cancellation: Cancellation): Promise<MailSnapshot> {
    validateMailQuery(query); return this.run(query.accountId, false, cancellation, (client: ImapClient) => client.query(query));
  }
  async read(id: string, folder: string, uidValidity: number, uid: number, cancellation: Cancellation): Promise<MailBody> {
    validateMailQuery({ accountId: id, folder: folder }); imapNumber(uidValidity); imapNumber(uid);
    return this.run(id, true, cancellation, (client: ImapClient) => client.read(folder, uidValidity, uid));
  }
}
