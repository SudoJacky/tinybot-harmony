import { socket, connection } from '@kit.NetworkKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { t } from '../model/I18n';
import { Diagnostics } from '../model/Diagnostics';
import { CollaborationPacket } from '../model/DeviceCollaboration';
import { CollaborationLink, DeviceCollaboration } from './DeviceCollaboration';
import { LanCollaborationCrypto, parseLanInvitation, privateLanAddress } from './LanCollaborationCrypto';

type LanSocket = socket.TCPSocket | socket.TCPSocketConnection;
interface Challenge { challenge: string; }

class LanConnection implements CollaborationLink {
  private channel: LanSocket;
  private crypto: LanCollaborationCrypto = new LanCollaborationCrypto();
  private challenge: string = '';
  private host: boolean;
  private alive: boolean = true;
  private authenticated: boolean = false;
  private outgoing: number = 0;
  private incoming: number = 0;
  private buffer: string = '';
  private sendLane: Promise<void> = Promise.resolve();
  private receiveLane: Promise<void> = Promise.resolve();
  private deadline: number = -1;
  private model: DeviceCollaboration;
  private opened: () => void;
  private ended: (error?: Error) => void;
  constructor(channel: LanSocket, host: boolean, model: DeviceCollaboration, opened: () => void, ended: (error?: Error) => void) {
    this.channel = channel; this.host = host; this.model = model; this.opened = opened; this.ended = ended;
  }
  async start(secret: string): Promise<void> {
    const initialized = this.crypto.initialize(secret); this.receiveLane = initialized;
    this.channel.on('message', (info) => this.received(info.message));
    this.channel.on('close', () => this.close());
    this.channel.on('error', (error) => this.close(new Error(t('局域网连接异常：{0}', [error.code]))));
    this.deadline = setTimeout(() => this.close(new Error(t('局域网配对超时，请检查连接码和网络。'))), 10000);
    await initialized;
    if (!this.alive) { this.crypto.dispose(); return; }
    if (this.host) {
      this.challenge = util.generateRandomUUID(); const challenge: Challenge = { challenge: this.challenge };
      await this.channel.send({ data: JSON.stringify(challenge) + '\n' });
    }
  }
  private received(data: ArrayBuffer): void {
    if (!this.alive) { return; }
    this.buffer += new util.TextDecoder().decodeToString(new Uint8Array(data));
    let newline = this.buffer.indexOf('\n');
    while (newline >= 0) {
      if (newline > 12 * 1024 * 1024) { this.close(new Error('LAN frame too large.')); return; }
      const line = this.buffer.slice(0, newline); this.buffer = this.buffer.slice(newline + 1);
      const received = this.receiveLane.then(() => this.line(line));
      this.receiveLane = received.catch((error: Error) => this.close(error));
      newline = this.buffer.indexOf('\n');
    }
    if (this.buffer.length > 12 * 1024 * 1024) { this.close(new Error('LAN frame too large.')); }
  }
  private async line(text: string): Promise<void> {
    if (!this.alive) { return; }
    if (!this.challenge) {
      const challenge = JSON.parse(text) as Challenge;
      if (this.host || !challenge || typeof challenge.challenge !== 'string' || !/^[a-f0-9-]{36}$/.test(challenge.challenge)) {
        throw new Error('Invalid LAN challenge.');
      }
      this.challenge = challenge.challenge;
      await this.send({ version: 1, kind: 'hello', name: this.model.localName }); return;
    }
    const packet = await this.crypto.decrypt(text, this.challenge, this.host ? 'guest' : 'host', this.incoming++);
    if (!this.alive) { return; }
    if (!this.authenticated) {
      if (packet.kind !== 'hello') { throw new Error('LAN authentication requires hello.'); }
      this.authenticated = true; clearTimeout(this.deadline); this.opened();
      this.model.opened(this, this.model.localName);
    }
    this.model.receive(packet);
  }
  send(packet: CollaborationPacket): Promise<void> {
    const sent = this.sendLane.then(async () => {
      if (!this.alive || !this.challenge) { throw new Error(t('执行设备未连接。')); }
      const encrypted = await this.crypto.encrypt(packet, this.challenge, this.host ? 'host' : 'guest', this.outgoing++);
      if (!this.alive) { throw new Error(t('执行设备未连接。')); }
      await this.channel.send({ data: encrypted });
    });
    this.sendLane = sent.catch((error: Error) => this.close(error));
    return sent;
  }
  close(error?: Error, deliberate: boolean = false): void {
    if (!this.alive) { return; }
    this.alive = false; clearTimeout(this.deadline); this.crypto.dispose(); this.buffer = '';
    this.channel.close().catch((failure: Error) => Diagnostics.log('error', 'collaboration', 'cleanup_failed', undefined, failure));
    this.ended(error || (!this.authenticated && !deliberate ? new Error('LAN authentication was not completed.') : undefined));
  }
}

@Observed
export class LanDeviceCollaboration {
  active: boolean = false;
  busy: boolean = false;
  invitation: string = '';
  input: string = '';
  error: string = '';
  private model: DeviceCollaboration;
  private server?: socket.TCPSocketServer;
  private link?: LanConnection;
  private pending?: socket.TCPSocket;
  private expiry: number = -1;
  private generation: number = 0;
  constructor(model: DeviceCollaboration) { this.model = model; }
  async host(): Promise<void> {
    this.stop(); const generation = this.generation; this.busy = true; this.error = '';
    try {
      const properties = await connection.getConnectionProperties(await connection.getDefaultNet());
      const address = properties.linkAddresses.map((item) => item.address.address).find((item) => privateLanAddress(item));
      if (!address) { throw new Error(t('请连接同一局域网后重试。')); }
      const secret = await LanCollaborationCrypto.secret();
      if (generation !== this.generation) { return; }
      const server = socket.constructTCPSocketServerInstance(); this.server = server;
      server.on('error', (error) => { if (this.server === server) { this.failed(new Error(t('局域网连接异常：{0}', [error.code]))); this.stop(); } });
      await server.listen({ address: address, family: 1, port: 0 });
      if (generation !== this.generation) { await server.close(); return; }
      server.on('connect', (channel: socket.TCPSocketConnection) => {
        if (generation !== this.generation || this.link || !this.invitation) {
          channel.close().catch((error: Error) => this.failed(error)); return;
        }
        this.attach(channel, true, secret);
      });
      const local = await server.getLocalAddress();
      if (generation !== this.generation) { return; }
      this.invitation = 'tinybot-lan://' + address + ':' + local.port + '/' + secret;
      this.expiry = setTimeout(() => this.expire(), 5 * 60 * 1000);
    } catch (error) { if (generation === this.generation) { this.failed(error as Error); this.stop(); } }
    finally { if (generation === this.generation) { this.busy = false; } }
  }
  async join(): Promise<void> {
    this.stop(); const generation = this.generation; this.busy = true; this.error = '';
    try {
      const invitation = parseLanInvitation(this.input);
      const channel = socket.constructTCPSocketInstance(); this.pending = channel;
      channel.on('error', (error) => { if (this.pending === channel) { this.failed(new Error(t('局域网连接异常：{0}', [error.code]))); this.stop(); } });
      this.attach(channel, false, invitation.secret);
      await channel.bind({ address: '0.0.0.0', family: 1, port: 0 });
      if (generation !== this.generation || !this.link) { return; }
      await channel.connect({ address: { address: invitation.address, port: invitation.port, family: 1 }, timeout: 8000 });
      if (generation !== this.generation) { return; }
      this.pending = undefined;
    } catch (error) { if (generation === this.generation) { this.failed(error as Error); this.stop(); } }
    finally { if (generation === this.generation && !this.link) { this.busy = false; } }
  }
  private attach(channel: LanSocket, host: boolean, secret: string): void {
    const link = new LanConnection(channel, host, this.model, () => {
      if (this.link === link) { this.active = true; this.busy = false; this.error = ''; }
    }, (error?: Error) => {
      if (this.link !== link) { return; }
      this.link = undefined; this.active = false; this.busy = false;
      this.model.disconnected(t('设备连接已断开，远端状态尚未更新。'));
      if (error) { this.failed(error); }
    });
    this.link = link; this.busy = true;
    link.start(secret).catch((error: Error) => link.close(error));
  }
  async copyInvitation(): Promise<void> {
    if (!this.invitation) { return; }
    try { await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.invitation)); }
    catch (error) { this.failed(error as Error); }
  }
  disconnect(): void { this.link?.close(undefined, true); }
  stop(): void {
    this.generation++; this.busy = false; this.disconnect();
    const pending = this.pending; this.pending = undefined;
    pending?.close().catch((error: Error) => this.failed(error));
    this.expire();
  }
  private expire(): void {
    clearTimeout(this.expiry); this.expiry = -1; this.invitation = '';
    const server = this.server; this.server = undefined;
    server?.close().catch((error: Error) => this.failed(error));
  }
  private failed(error: Error): void {
    this.error = t('局域网连接失败，请确认连接码有效且两端处于同一网络。');
    Diagnostics.log('error', 'collaboration', 'lan_failed', undefined, error);
  }
}
