import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ImapTransport } from './ImapClient';
import { Diagnostics } from '../model/Diagnostics';
export class NativeImapTransport implements ImapTransport {
  private tls: socket.TLSSocket = socket.constructTLSSocketInstance();
  private closed: boolean = false;
  listen(data: (bytes: Uint8Array) => void, failed: (error: Error) => void): void {
    this.tls.on('message', (event: socket.SocketMessageInfo) => data(new Uint8Array(event.message)));
    this.tls.on('error', (error: BusinessError) => {
      Diagnostics.log('error', 'mail', 'transport_failed', { code: error.code });
      failed(new Error('IMAP TLS connection failed; check the server, network and certificate'));
    });
    this.tls.on('close', () => { if (!this.closed) { failed(new Error('IMAP connection closed unexpectedly')); } });
  }
  async connect(host: string, port: number): Promise<void> {
    try {
      await this.tls.bind({ address: '0.0.0.0', port: 0, family: 1 });
      if (this.closed) { throw new Error('IMAP transport is closed'); }
      await this.tls.connect({ address: { address: host, port: port, family: 1 }, secureOptions: {}, skipRemoteValidation: false });
    } catch (error) {
      Diagnostics.log('error', 'mail', 'transport_failed', { code: (error as BusinessError).code });
      throw new Error('IMAP TLS connection failed; check the server, network and certificate');
    }
  }
  async send(text: string): Promise<void> {
    if (this.closed) { throw new Error('IMAP transport is closed'); }
    try { await this.tls.send(text); }
    catch (error) {
      Diagnostics.log('error', 'mail', 'transport_failed', { code: (error as BusinessError).code }); throw new Error('IMAP command could not be sent');
    }
  }
  async close(): Promise<void> {
    if (this.closed) { return; } this.closed = true;
    try { await this.tls.close(); }
    catch (error) { Diagnostics.log('warn', 'mail', 'cleanup_failed', { code: (error as BusinessError).code }); }
  }
}
