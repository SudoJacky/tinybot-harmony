import { abilityAccessCtrl, bundleManager, common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { abilityConnectionManager, distributedDeviceManager } from '@kit.DistributedServiceKit';
import { Diagnostics } from '../model/Diagnostics';

export const LIVE_SYNC_PROBE = 'tinybotLiveSyncProbe';
const SERVICE = 'TinybotLiveSyncProbe';
const BUNDLE = 'com.sudojacky.tinybot';
const PERMISSION = 'ohos.permission.DISTRIBUTED_DATASYNC';
const COUNT = 32;
const SAMPLE = '测试数据'.repeat(72);

interface SampleFrame { run: number; index: number; sent: number; ack: boolean; payload?: string; }

// The opt-in debug probe carries only synthetic data and never touches the app databases.
class LiveSyncProbe {
  private armed: boolean = false;
  private session: number = -1;
  private connected: boolean = false;
  private sending: boolean = false;
  private run: number = 0;
  private waiting: Map<number, number> = new Map();
  private roundTrips: number[] = [];

  private status(text: string): void { AppStorage.setOrCreate('tinybot.probe.status', text); }

  private error(stage: string, error: Error): void {
    const code = (error as BusinessError).code;
    Diagnostics.log('warn', 'sync', 'probe_failed', { phase: stage, code: code }, error);
    this.status(stage + ' failed: ' + String(code ?? error.message));
  }

  async arm(context: common.UIAbilityContext): Promise<void> {
    const access = abilityAccessCtrl.createAtManager();
    const bundle = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
    if (access.checkAccessTokenSync(bundle.appInfo.accessTokenId, PERMISSION) !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
      const permission = await access.requestPermissionsFromUser(context, [PERMISSION]);
      if (permission.authResults[0] !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) { this.status('Nearby permission denied'); return; }
    }
    this.armed = true;
    AppStorage.setOrCreate('tinybot.probe.armed', true);
    this.status('Ready to connect');
  }

  async connect(context: common.UIAbilityContext): Promise<void> {
    if (!this.armed || this.session >= 0) { return; }
    const discovery = distributedDeviceManager.createDeviceManager(BUNDLE);
    let peers: distributedDeviceManager.DeviceBasicInfo[];
    try { peers = discovery.getAvailableDeviceListSync().filter((item) => !!item.networkId); }
    finally { distributedDeviceManager.releaseDeviceManager(discovery); }
    if (peers.length !== 1) { this.status('Expected one trusted peer. Found ' + peers.length); return; }
    const peer: abilityConnectionManager.PeerInfo = { deviceId: peers[0].networkId!, bundleName: BUNDLE,
      moduleName: 'entry', abilityName: 'EntryAbility', serviceName: SERVICE };
    const options: abilityConnectionManager.ConnectOptions = { needSendData: true,
      parameters: { 'tinybotLiveSyncProbe': '1' } };
    const started = Date.now();
    this.status('Connecting');
    const id = this.open(context, peer, options);
    try {
      const result = await abilityConnectionManager.connect(id);
      if (!result.isConnected) {
        throw new Error('collaboration code ' + String(result.errorCode ?? 'unknown'));
      }
      this.ready(id, 'source', started);
    } catch (error) { this.close(); this.error('connect', error as Error); }
  }

  accept(context: common.UIAbilityContext, want: Record<string, Object>): boolean {
    const parameters = want['ohos.extra.param.key.supportCollaborateIndex'] as Record<string, Object> | undefined;
    const peer = parameters?.['PeerInfo'] as abilityConnectionManager.PeerInfo | undefined;
    const options = parameters?.['ConnectOption'] as abilityConnectionManager.ConnectOptions | undefined;
    const token = parameters?.['ohos.dms.collabToken'];
    if (!this.armed || this.session >= 0 || !peer || !options || typeof token !== 'string' ||
      (options.parameters?.[LIVE_SYNC_PROBE] !== '1' && peer.serviceName !== SERVICE) ||
      (peer.bundleName && peer.bundleName !== BUNDLE)) {
      Diagnostics.log('info', 'sync', 'probe_declined', { enabled: this.armed, ready: !!peer && !!options && typeof token === 'string' });
      return false;
    }
    try {
      const started = Date.now(), id = this.open(context, peer, options);
      abilityConnectionManager.acceptConnect(id, token).then(() => this.ready(id, 'sink', started)).catch((error: Error) => {
        this.close(); this.error('accept', error);
      });
      return true;
    } catch (error) { this.close(); this.error('accept', error as Error); return false; }
  }

  private open(context: common.UIAbilityContext, peer: abilityConnectionManager.PeerInfo,
    options: abilityConnectionManager.ConnectOptions): number {
    const id = abilityConnectionManager.createAbilityConnectionSession(SERVICE, context, peer, options);
    this.session = id;
    abilityConnectionManager.on('disconnect', id, () => {
      if (this.session === id) { this.close(false); this.status('Disconnected'); }
    });
    abilityConnectionManager.on('receiveData', id, (event) => {
      if (this.session === id && event.data) { this.receive(id, event.data).catch((error: Error) => this.error('receive', error)); }
    });
    return id;
  }

  private ready(id: number, role: string, started: number): void {
    if (this.session !== id) { return; }
    this.connected = true;
    AppStorage.setOrCreate('tinybot.probe.connected', true);
    this.status('Connected (' + role + ') in ' + (Date.now() - started) + ' ms');
    Diagnostics.log('info', 'sync', 'probe_connected', { phase: role, durationMs: Date.now() - started });
  }

  private send(id: number, frame: SampleFrame): Promise<void> {
    return abilityConnectionManager.sendData(id, new util.TextEncoder().encodeInto(JSON.stringify(frame)).buffer as ArrayBuffer);
  }

  async sample(): Promise<void> {
    if (!this.connected || this.sending) { return; }
    const id = this.session;
    this.sending = true;
    this.run = Date.now(); this.waiting.clear(); this.roundTrips = [];
    AppStorage.setOrCreate('tinybot.probe.results', 'Sending samples');
    try {
      for (let index = 1; index <= COUNT && this.session === id; index++) {
        const sent = Date.now();
        this.waiting.set(index, sent);
        await this.send(id, { run: this.run, index: index, sent: sent, ack: false, payload: SAMPLE });
        await new Promise<void>((resolve) => { setTimeout(resolve, 200); });
      }
    } catch (error) { this.error('send', error as Error); }
    finally { this.sending = false; }
  }

  private async receive(id: number, bytes: ArrayBuffer): Promise<void> {
    if (!this.armed || bytes.byteLength > 2048) { return; }
    const frame = JSON.parse(util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(bytes))) as SampleFrame;
    if (!frame || !Number.isSafeInteger(frame.index) || frame.index < 1 || frame.index > COUNT ||
      !Number.isSafeInteger(frame.run) || !Number.isSafeInteger(frame.sent)) { return; }
    if (frame.ack === true) {
      if (frame.run !== this.run || this.waiting.get(frame.index) !== frame.sent) { return; }
      this.waiting.delete(frame.index);
      const elapsed = Date.now() - frame.sent;
      this.roundTrips.push(elapsed);
      const sorted = this.roundTrips.slice().sort((a, b) => a - b);
      const median = sorted[Math.floor((sorted.length - 1) / 2)], p95 = sorted[Math.ceil(sorted.length * 0.95) - 1];
      AppStorage.setOrCreate('tinybot.probe.results', sorted.length + '/' + COUNT + ' ACK · p50 ' + median + ' ms · p95 ' + p95 + ' ms');
      Diagnostics.log('info', 'sync', 'probe_acknowledged', { count: frame.index, durationMs: elapsed });
    } else if (frame.ack === false && frame.payload === SAMPLE) {
      const phase = frame.index === COUNT ? 'Complete' : frame.index === 21 ? 'Tool complete' : frame.index >= 11 && frame.index < 21 ? 'Tool running' : 'Streaming';
      AppStorage.setOrCreate('tinybot.probe.remote', phase + ' · ' + frame.index + '/' + COUNT);
      Diagnostics.log('info', 'sync', 'probe_received', { count: frame.index });
      await this.send(id, { run: frame.run, index: frame.index, sent: frame.sent, ack: true });
    }
  }

  close(disconnect: boolean = true): void {
    const id = this.session;
    this.session = -1; this.connected = false;
    AppStorage.setOrCreate('tinybot.probe.connected', false);
    if (id < 0) { return; }
    try { if (disconnect) { abilityConnectionManager.disconnect(id); } }
    catch (error) { this.error('disconnect', error as Error); }
    try { abilityConnectionManager.destroyAbilityConnectionSession(id); }
    catch (error) { this.error('destroy', error as Error); }
  }

  exit(): void {
    this.armed = false; this.close();
    AppStorage.setOrCreate('tinybot.probe.armed', false);
    AppStorage.setOrCreate('tinybot.probe.visible', false);
    this.status('');
  }
}

export const liveSyncProbe = new LiveSyncProbe();
