import { MailAccount, MailQuery, MailSnapshot, MailMessage, MailBody } from '../model/Mail';
import { ImapFrame, ImapFramer, imapQuote, imapNumber, imapSearch } from '../model/ImapWire';
import { mailBinary, mailHeader, mailHeaders, mailBodyText, imapFolder } from '../model/MailMime';
import { Cancellation, RunCancelledError } from './Cancellation';
import { Diagnostics } from '../model/Diagnostics';
export interface ImapTransport {
  listen(data: (bytes: Uint8Array) => void, failed: (error: Error) => void): void;
  connect(host: string, port: number): Promise<void>;
  send(text: string): Promise<void>;
  close(): Promise<void>;
}
interface ImapWaiter { tag: string; operation: string; frames: ImapFrame[]; resolve: (frames: ImapFrame[]) => void; reject: (error: Error) => void; timer: number; }
export class ImapClient {
  private transport: ImapTransport;
  private framer: ImapFramer = new ImapFramer();
  private waiter?: ImapWaiter;
  private failure?: Error;
  private serial: number = 0;
  private remove: () => void;
  private deadline: number;
  constructor(transport: ImapTransport, cancellation: Cancellation) {
    this.transport = transport;
    transport.listen((bytes: Uint8Array) => {
      try { for (const frame of this.framer.push(mailBinary(bytes))) { this.receive(frame); } }
      catch (error) { this.fail(error as Error); }
    }, (error: Error) => this.fail(error));
    this.deadline = setTimeout(() => this.fail(new Error('IMAP operation timed out after 60 seconds')), 60000);
    this.remove = cancellation.onCancel(() => this.fail(new RunCancelledError() as Error));
  }
  private fail(error: Error): void {
    if (this.failure) { return; } this.failure = error;
    const waiter = this.waiter; this.waiter = undefined;
    if (waiter) { clearTimeout(waiter.timer); waiter.reject(error); }
    this.transport.close().catch((cleanup: Error) => Diagnostics.log('warn', 'mail', 'cleanup_failed', {}, cleanup));
  }
  private receive(frame: ImapFrame): void {
    if (/^\* BYE(?: |$)/i.test(frame.text)) { this.fail(new Error('IMAP server closed the session')); return; }
    const waiter = this.waiter; if (!waiter) { return; }
    if (!waiter.tag) {
      if (!/^\* OK(?: |$)/i.test(frame.text)) { this.fail(new Error('Expected IMAP OK greeting')); return; }
    } else if (!frame.text.startsWith(waiter.tag + ' ')) {
      if (frame.text.startsWith('+')) { this.fail(new Error('Unexpected IMAP continuation')); return; }
      waiter.frames.push(frame); return;
    }
    clearTimeout(waiter.timer); this.waiter = undefined;
    if (waiter.tag && !frame.text.toUpperCase().startsWith(waiter.tag + ' OK')) {
      const bad = frame.text.toUpperCase().startsWith(waiter.tag + ' BAD');
      Diagnostics.log('error', 'mail', 'command_failed', { operation: waiter.operation, code: bad ? 2 : 1 });
      waiter.reject(new Error('IMAP ' + waiter.operation + ' command was rejected; check authorization, folder access and server settings'));
    } else { waiter.frames.push(frame); waiter.resolve(waiter.frames); }
  }
  private wait(tag: string, send: () => Promise<void>, operation: string = 'connect'): Promise<ImapFrame[]> {
    if (this.failure) { return Promise.reject(this.failure); }
    if (this.waiter) { return Promise.reject(new Error('Concurrent commands on one IMAP session are prohibited')); }
    return new Promise<ImapFrame[]>((resolve, reject) => {
      this.waiter = { tag: tag, operation: operation, frames: [], resolve: resolve, reject: reject,
        timer: setTimeout(() => this.fail(new Error('IMAP command timed out')), 15000) };
      send().catch((error: Error) => this.fail(error));
    });
  }
  private command(command: string): Promise<ImapFrame[]> {
    const tag = 'T' + (++this.serial);
    const operation = command.startsWith('UID FETCH ') ? 'fetch' : command.startsWith('UID SEARCH ') ? 'search' :
      command.startsWith('LOGIN ') ? 'login' : command.startsWith('EXAMINE ') ? 'examine' : command.startsWith('ID ') ? 'identify' : 'capability';
    return this.wait(tag, () => this.transport.send(tag + ' ' + command + '\r\n'), operation);
  }
  async login(account: MailAccount, secret: string): Promise<void> {
    await this.wait('', () => this.transport.connect(account.host, account.port));
    const capabilities = (await this.command('CAPABILITY')).map((frame: ImapFrame) => frame.text).join(' ').toUpperCase();
    if (/\bLOGINDISABLED\b/.test(capabilities)) { throw new Error('This mailbox does not support IMAP LOGIN with an app password'); }
    await this.command('LOGIN ' + imapQuote(account.username) + ' ' + imapQuote(secret));
    // Some providers require client identification, but ID must only be sent when advertised.
    const authenticated = (await this.command('CAPABILITY')).map((frame: ImapFrame) => frame.text).join(' ').toUpperCase();
    if (/(?:^| )ID(?: |$)/.test(authenticated)) { await this.command('ID ("name" "Tinybot" "version" "1.0")'); }
  }
  private async examine(folder: string): Promise<number> {
    const frames = await this.command('EXAMINE ' + imapQuote(imapFolder(folder)));
    const text = frames.map((frame: ImapFrame) => frame.text).join('\n'), match = /\[UIDVALIDITY (\d+)\]/i.exec(text);
    if (!match) { throw new Error('IMAP server did not provide UIDVALIDITY'); } return imapNumber(Number(match[1]));
  }
  private message(frame: ImapFrame, folder: string, validity: number): MailMessage {
    const uid = /(?:\(| )UID (\d+)(?: |\))/i.exec(frame.text), size = /RFC822\.SIZE (\d+)/i.exec(frame.text), flags = /FLAGS \(([^)]*)\)/i.exec(frame.text);
    if (!uid || !size || !flags || frame.literals.length !== 1) { throw new Error('Incomplete IMAP message metadata'); }
    const number = imapNumber(Number(uid[1])), headers = mailHeaders(frame.literals[0]);
    return { id: validity + ':' + number, uid: number, uidValidity: validity, folder: folder,
      subject: mailHeader(headers['subject'] || ''), from: mailHeader(headers['from'] || ''), to: mailHeader(headers['to'] || ''),
      date: headers['date'] || '', unread: !/(?:^| )\\Seen(?: |$)/i.test(flags[1]), size: Number(size[1]) };
  }
  private async fetch(uids: number[], folder: string, validity: number): Promise<MailMessage[]> {
    if (!uids.length) { return []; }
    const frames = await this.command('UID FETCH ' + uids.join(',') + ' (UID FLAGS RFC822.SIZE BODY.PEEK[HEADER])');
    const messages: MailMessage[] = [];
    for (const frame of frames) {
      if (!/^\* \d+ FETCH /i.test(frame.text) || !frame.literals.length) { continue; }
      const message = this.message(frame, folder, validity); if (uids.includes(message.uid)) { messages.push(message); }
    }
    return messages.sort((a: MailMessage, b: MailMessage) => b.uid - a.uid);
  }
  async query(query: MailQuery): Promise<MailSnapshot> {
    const validity = await this.examine(query.folder);
    const all = imapSearch(await this.command('UID SEARCH ALL'));
    const unseen = imapSearch(await this.command('UID SEARCH UNSEEN'));
    let criteria = query.unreadOnly ? 'UNSEEN' : 'ALL';
    if (query.from) { criteria += ' FROM ' + imapQuote(query.from); }
    if (query.subject) { criteria += ' SUBJECT ' + imapQuote(query.subject); }
    const filtered = query.from || query.subject ? imapSearch(await this.command('UID SEARCH CHARSET UTF-8 ' + criteria)) : query.unreadOnly ? unseen : all;
    const selected = filtered.slice(-(query.limit || 10));
    const messages = await this.fetch(selected, query.folder, validity);
    // SEARCH/FETCH may race with server-side deletions. Report the actual returned window.
    return { accountId: query.accountId, folder: query.folder, uidValidity: validity, total: all.length, unread: unseen.length,
      matched: filtered.length, limited: filtered.length > selected.length || messages.length < selected.length, checkedAt: Date.now(), messages: messages };
  }
  async read(folder: string, uidValidity: number, uid: number): Promise<MailBody> {
    imapNumber(uid); imapNumber(uidValidity);
    const current = await this.examine(folder);
    if (current !== uidValidity) { throw new Error('Mailbox UIDVALIDITY changed; search again before reading this email'); }
    const metadata = await this.fetch([uid], folder, current);
    if (metadata.length !== 1) { throw new Error('Email no longer exists; search again'); }
    if (metadata[0].size > 512 * 1024) { throw new Error('Email exceeds the 512 KiB read limit; open it in your mail app'); }
    const frames = await this.command('UID FETCH ' + uid + ' (UID BODY.PEEK[])');
    const frame = frames.find((item: ImapFrame) => /^\* \d+ FETCH /i.test(item.text) && new RegExp('(?:\\(| )UID ' + uid + '(?: |\\))', 'i').test(item.text) && item.literals.length === 1);
    if (!frame) { throw new Error('Email body is unavailable'); }
    return { message: metadata[0], text: mailBodyText(frame.literals[0]) };
  }
  async close(): Promise<void> {
    clearTimeout(this.deadline); this.remove();
    if (this.waiter) { this.fail(new Error('IMAP session closed')); }
    await this.transport.close();
  }
}
