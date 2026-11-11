import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { abilityConnectionManager as connection } from '@kit.DistributedServiceKit';
import { Diagnostics } from '../model/Diagnostics';

const BUNDLE = 'com.sudojacky.tinybot';
const SERVICE = 'TinybotConversation';
const PROTOCOL = 'tinybotConversation';
const VERSION = '1';
const HEADER = 8;
const PART = 4088;
const MAX_BYTES = 8 * 1024 * 1024;
const CONNECT_TIMEOUT = 12000;

export class NearbyConnectionFailure extends Error {
  readonly retryable: boolean;
  constructor(code?: connection.ConnectErrorCode) {
    super('Collaboration status ' + String(code));
    this.retryable = code === connection.ConnectErrorCode.CONNECTED_SESSION_EXISTS ||
      code === connection.ConnectErrorCode.SYSTEM_INTERNAL_ERROR;
  }
}

export class NearbyConversationLink {
  readonly id: number;
  readonly deviceId: string;
  private closed = false;
  private incoming = new Uint8Array(0);
  private offset = 0;
  private sendTail: Promise<void> = Promise.resolve();
  private receiveTail: Promise<void> = Promise.resolve();
  private receive: (link: NearbyConversationLink, text: string) => Promise<void>;
  private disconnected: (link: NearbyConversationLink) => void;
  private ready: Promise<void>;
  private markReady: () => void = () => {};

  constructor(context: common.UIAbilityContext, peer: connection.PeerInfo, options: connection.ConnectOptions,
    receive: (link: NearbyConversationLink, text: string) => Promise<void>, disconnected: (link: NearbyConversationLink) => void) {
    this.deviceId = peer.deviceId;
    this.receive = receive;
    this.disconnected = disconnected;
    this.ready = new Promise<void>((resolve) => { this.markReady = resolve; });
    this.id = connection.createAbilityConnectionSession(SERVICE, context, peer, options);
    try {
      connection.on('disconnect', this.id, () => this.close(false));
      connection.on('receiveData', this.id, (event) => {
        if (event.data && !this.closed) { this.read(event.data); }
      });
    } catch (error) {
      this.close();
      throw error as Error;
    }
  }

  async open(token?: string): Promise<void> {
    let timer = -1;
    try {
      const opening = token !== undefined ? connection.acceptConnect(this.id, token) : connection.connect(this.id).then((result) => {
        if (!result.isConnected) {
          Diagnostics.log('warn', 'sync', 'conversation_connect_failed', { code: result.errorCode });
          throw new NearbyConnectionFailure(result.errorCode);
        }
      });
      const timeout = new Promise<void>((_resolve, reject) => {
        timer = setTimeout(() => reject(new Error('Nearby conversation connection timed out')), CONNECT_TIMEOUT);
      });
      await Promise.race([opening, timeout]);
      this.checkOpen();
      this.markReady();
    } catch (error) {
      this.close();
      throw error as Error;
    } finally { if (timer >= 0) { clearTimeout(timer); } }
  }

  send(text: string): Promise<void> {
    const result = this.sendTail.then(async () => {
      await this.ready;
      this.checkOpen();
      const bytes = new util.TextEncoder().encodeInto(text);
      if (bytes.length > MAX_BYTES) { throw new Error('Nearby conversation message is too large'); }
      for (let offset = 0; offset < bytes.length; offset += PART) {
        this.checkOpen();
        const part = bytes.subarray(offset, offset + PART);
        const packet = new Uint8Array(HEADER + part.length);
        const header = new DataView(packet.buffer);
        header.setUint32(0, bytes.length); header.setUint32(4, offset);
        packet.set(part, HEADER);
        try { await connection.sendData(this.id, packet.buffer as ArrayBuffer); }
        catch (error) { this.close(); throw error as Error; }
      }
    });
    this.sendTail = result.catch(() => {});
    return result;
  }

  private read(packet: ArrayBuffer): void {
    if (packet.byteLength <= HEADER || packet.byteLength > HEADER + PART) { this.invalidPacket(packet.byteLength); return; }
    const header = new DataView(packet);
    const size = header.getUint32(0), offset = header.getUint32(4), length = packet.byteLength - HEADER;
    if (size > MAX_BYTES || offset !== this.offset || offset + length > size ||
      (offset > 0 && size !== this.incoming.length)) { this.invalidPacket(packet.byteLength); return; }
    if (offset === 0) { this.incoming = new Uint8Array(size); }
    this.incoming.set(new Uint8Array(packet, HEADER), offset);
    this.offset += length;
    if (this.offset !== size) { return; }
    const bytes = this.incoming;
    this.incoming = new Uint8Array(0); this.offset = 0;
    this.receiveTail = this.receiveTail.then(async () => {
      await this.ready;
      this.checkOpen();
      await this.receive(this, util.TextDecoder.create('utf-8').decodeToString(bytes));
    }).catch((error: Error) => {
      if (!this.closed) { Diagnostics.log('warn', 'sync', 'conversation_receive_failed', undefined, error); }
      this.close();
    });
  }

  private invalidPacket(bytes: number): void {
    Diagnostics.log('warn', 'sync', 'conversation_frame_invalid', { bytes: bytes });
    this.close();
  }

  private checkOpen(): void {
    if (this.closed) { throw new Error('Nearby conversation disconnected'); }
  }

  close(disconnect: boolean = true): void {
    if (this.closed) { return; }
    this.closed = true; this.markReady();
    this.incoming = new Uint8Array(0);
    try { if (disconnect) { connection.disconnect(this.id); } }
    catch (error) { Diagnostics.log('warn', 'sync', 'conversation_disconnect_failed', undefined, error as Error); }
    try { connection.destroyAbilityConnectionSession(this.id); }
    catch (error) { Diagnostics.log('warn', 'sync', 'conversation_destroy_failed', undefined, error as Error); }
    this.disconnected(this);
  }
}

export function nearbyConversationPeer(deviceId: string): connection.PeerInfo {
  return { deviceId: deviceId, bundleName: BUNDLE, moduleName: 'entry', abilityName: 'EntryAbility', serviceName: SERVICE };
}

export function nearbyConversationOptions(): connection.ConnectOptions {
  return { needSendData: true, parameters: { 'tinybotConversation': VERSION } };
}

export interface NearbyConversationInvite {
  peer: connection.PeerInfo;
  options: connection.ConnectOptions;
  token: string;
}

export function nearbyConversationInvite(want: Record<string, Object>): NearbyConversationInvite | undefined {
  const params = want['ohos.extra.param.key.supportCollaborateIndex'] as Record<string, Object> | undefined;
  const peer = params?.['PeerInfo'] as connection.PeerInfo | undefined;
  const options = params?.['ConnectOption'] as connection.ConnectOptions | undefined;
  const token = params?.['ohos.dms.collabToken'];
  if (!peer || peer.bundleName !== BUNDLE || !peer.deviceId || !options?.needSendData ||
    options.parameters?.[PROTOCOL] !== VERSION || typeof token !== 'string') { return undefined; }
  return { peer: peer, options: options, token: token };
}
