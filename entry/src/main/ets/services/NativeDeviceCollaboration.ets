import { AbilityConstant, abilityAccessCtrl, common } from '@kit.AbilityKit';
import { abilityConnectionManager, distributedDeviceManager } from '@kit.DistributedServiceKit';
import { util } from '@kit.ArkTS';
import { t } from '../model/I18n';
import { Diagnostics } from '../model/Diagnostics';
import { LogError } from '../model/DiagnosticLog';
import { CollaborationPacket, CollaborationReceiver, collaborationFrames } from '../model/DeviceCollaboration';
import { CollaborationLink, DeviceCollaboration } from './DeviceCollaboration';
import { LanDeviceCollaboration } from './LanDeviceCollaboration';

const BUNDLE: string = 'com.sudojacky.tinybot';
const SERVICE: string = 'tinybot.sessions.v1';
export interface CollaborationDevice { id: string; name: string; }

class NativeCollaborationLink implements CollaborationLink {
  private lane: Promise<void> = Promise.resolve();
  private sequence: number = 0;
  private alive: boolean = true;
  private id: number;
  private ended: () => void;
  constructor(id: number, ended: () => void) { this.id = id; this.ended = ended; }
  async send(packet: CollaborationPacket): Promise<void> {
    const frames = collaborationFrames(packet, this.sequence++);
    const result = this.lane.then(async () => {
      for (const frame of frames) {
        if (!this.alive) { throw new Error(t('执行设备未连接。')); }
        await abilityConnectionManager.sendMessage(this.id, frame);
      }
    });
    this.lane = result.catch((error: Error) => { this.close(); throw error; });
    // Keep rejection observable to the caller, without a second unhandled lane rejection.
    this.lane.catch(() => {});
    return result;
  }
  close(): void { if (this.alive) { this.alive = false; this.ended(); } }
}

@Observed
export class NativeDeviceCollaboration {
  model: DeviceCollaboration = new DeviceCollaboration(() => util.generateRandomUUID());
  lan: LanDeviceCollaboration = new LanDeviceCollaboration(this.model);
  enabled: boolean = false;
  busy: boolean = false;
  error: string = '';
  devices: CollaborationDevice[] = [];
  private context?: common.UIAbilityContext;
  private manager?: distributedDeviceManager.DeviceManager;
  private sessionId: number = -1;
  private link?: NativeCollaborationLink;
  private receiver: CollaborationReceiver = new CollaborationReceiver();
  private generation: number = 0;

  initialize(context: common.UIAbilityContext): void { this.context = context; }
  async setEnabled(enabled: boolean): Promise<void> {
    if (!enabled) { this.enabled = false; this.lan.stop(); this.disconnect(); this.devices = []; return; }
    if (!this.context || this.busy) { return; }
    const generation = this.generation;
    this.busy = true; this.error = '';
    try {
      const result = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(this.context, ['ohos.permission.DISTRIBUTED_DATASYNC']);
      if (this.generation !== generation) { return; }
      if (result.authResults.some((value) => value !== 0)) { throw new Error(t('需要允许分布式数据同步才能连接设备。')); }
      if (!this.manager) { this.manager = distributedDeviceManager.createDeviceManager(BUNDLE); }
      this.model.localName = this.manager.getLocalDeviceName();
      this.enabled = true; this.refresh();
    } catch (error) { this.fail('enable_failed', error as Error); }
    finally { if (this.generation === generation) { this.busy = false; } }
  }
  refresh(): void {
    if (!this.enabled || !this.manager) { return; }
    try {
      this.devices = this.manager.getAvailableDeviceListSync().filter((item) => !!item.networkId)
        .map((item): CollaborationDevice => ({ id: item.networkId!, name: item.deviceName }));
      this.error = '';
      Diagnostics.log('info', 'collaboration', 'devices_refreshed', { count: this.devices.length });
    } catch (error) { this.fail('discovery_failed', error as Error); }
  }
  async connect(device: CollaborationDevice): Promise<void> {
    if (!this.enabled || !this.context || this.busy || this.sessionId !== -1) { return; }
    this.lan.stop();
    this.busy = true; this.error = ''; this.model.error = '';
    const generation = this.generation;
    try {
      const peer: abilityConnectionManager.PeerInfo = { deviceId: device.id, bundleName: BUNDLE, moduleName: 'entry', abilityName: 'EntryAbility' };
      const options: abilityConnectionManager.ConnectOptions = { needSendData: true,
        startOptions: abilityConnectionManager.StartOptionParams.START_IN_FOREGROUND, parameters: { protocol: SERVICE } };
      const id = abilityConnectionManager.createAbilityConnectionSession(SERVICE, this.context, peer, options);
      this.register(id); this.model.peerName = device.name;
      const result = await abilityConnectionManager.connect(id);
      if (this.sessionId !== id || this.generation !== generation) { return; }
      if (!result.isConnected) {
        const rejection = result.reason === SERVICE + ':disabled' ? t('请先在另一台设备开启多设备协同。') :
          result.reason === SERVICE + ':busy' ? t('另一台设备已有协同连接或正在配对，请先断开后重试。') :
          result.reason === SERVICE + ':unavailable' ? t('另一台设备暂时无法接入协同，请查看对端提示。') : '';
        const message = rejection || (result.errorCode === abilityConnectionManager.ConnectErrorCode.SYSTEM_INTERNAL_ERROR ?
          t('系统协同连接失败，可尝试局域网直连（错误码 {0}）。', [String(result.errorCode)]) :
          t('设备连接失败：{0}', [String(result.errorCode) + ' ' + (result.reason || '')]));
        const error = new Error(message) as LogError;
        error.nativeCode = result.errorCode; throw error;
      }
      this.opened(id);
    } catch (error) { if (this.generation === generation) { this.disconnect(); this.fail('connect_failed', error as Error); } }
    finally { if (this.generation === generation) { this.busy = false; } }
  }
  accept(context: common.UIAbilityContext, wantParam: Record<string, Object>): AbilityConstant.CollaborateResult {
    const params = wantParam['ohos.extra.param.key.supportCollaborateIndex'] as Record<string, Object>;
    const token = params?.['ohos.dms.collabToken'] as string;
    if (!this.enabled || this.sessionId !== -1 || this.lan.active || this.lan.busy || !!this.lan.invitation) {
      Diagnostics.log('warn', 'collaboration', 'accept_rejected', { enabled: this.enabled, instanceId: this.sessionId, generation: this.generation });
      this.reject(token, this.enabled ? 'busy' : 'disabled');
      return AbilityConstant.CollaborateResult.REJECT;
    }
    try {
      const peer = params?.['PeerInfo'] as abilityConnectionManager.PeerInfo;
      const options = params?.['ConnectOption'] as abilityConnectionManager.ConnectOptions;
      if (!peer || peer.bundleName !== BUNDLE || peer.moduleName !== 'entry' || peer.abilityName !== 'EntryAbility' ||
        options?.parameters?.['protocol'] !== SERVICE || typeof token !== 'string' || !token) {
        throw new Error(t('收到不匹配的协同连接请求。'));
      }
      const id = abilityConnectionManager.createAbilityConnectionSession(SERVICE, context, peer, options);
      this.register(id); this.busy = true;
      const generation = this.generation;
      // Accept acknowledges the request; only the native connect event confirms that its channels are ready.
      abilityConnectionManager.acceptConnect(id, token).catch((error: Error) => {
        if (this.sessionId === id && this.generation === generation) { this.disconnect(); this.fail('accept_failed', error); }
      });
      return AbilityConstant.CollaborateResult.ACCEPT;
    } catch (error) {
      this.reject(token, 'unavailable'); this.disconnect(); this.fail('accept_failed', error as Error);
      return AbilityConstant.CollaborateResult.REJECT;
    }
  }
  private reject(token: string, reason: string): void {
    if (typeof token !== 'string' || !token) { return; }
    try { abilityConnectionManager.reject(token, SERVICE + ':' + reason); }
    catch (error) { Diagnostics.log('error', 'collaboration', 'reject_failed', undefined, error as Error); }
  }
  private register(id: number): void {
    this.sessionId = id; this.receiver = new CollaborationReceiver();
    const generation = this.generation;
    abilityConnectionManager.on('connect', id, () => {
      if (this.generation === generation) { this.opened(id); }
    });
    abilityConnectionManager.on('disconnect', id, (info) => {
      if (this.sessionId !== id || this.generation !== generation) { return; }
      this.model.error = t('设备连接已断开，远端状态尚未更新。');
      Diagnostics.log('warn', 'collaboration', 'disconnected', { code: info.reason, instanceId: id }); this.disconnect();
    });
    abilityConnectionManager.on('receiveMessage', id, (info) => {
      if (this.sessionId !== id || this.generation !== generation || typeof info.msg !== 'string') { return; }
      try { const packet = this.receiver.receive(info.msg); if (packet) { this.model.receive(packet); } }
      catch (error) { this.fail('protocol_failed', error as Error); this.disconnect(); }
    });
  }
  private opened(id: number): void {
    if (this.sessionId !== id || this.link) { return; }
    this.busy = false;
    this.link = new NativeCollaborationLink(id, () => { if (this.sessionId === id) { this.disconnect(); } });
    this.model.opened(this.link, this.model.localName);
    Diagnostics.log('info', 'collaboration', 'connected');
  }
  disconnect(): void {
    this.lan.disconnect();
    this.generation++; this.busy = false;
    const id = this.sessionId; this.sessionId = -1;
    const link = this.link; this.link = undefined; link?.close(); this.model.disconnected();
    if (id === -1) { return; }
    // The official guide allows destroy directly; it also disconnects the native session.
    const unregister: (() => void)[] = [() => abilityConnectionManager.off('connect', id),
      () => abilityConnectionManager.off('disconnect', id), () => abilityConnectionManager.off('receiveMessage', id)];
    for (const action of unregister) {
      try { action(); } catch (error) { this.fail('cleanup_failed', error as Error, id); }
    }
    try { abilityConnectionManager.destroyAbilityConnectionSession(id); }
    catch (error) { this.fail('destroy_failed', error as Error, id); }
  }
  dispose(): void {
    this.lan.stop();
    this.enabled = false; this.disconnect(); this.model.dispose(); this.devices = [];
    if (this.manager) {
      try { distributedDeviceManager.releaseDeviceManager(this.manager); }
      catch (error) { this.fail('cleanup_failed', error as Error); }
      this.manager = undefined;
    }
  }
  private fail(event: string, error: Error, sessionId: number = this.sessionId): void {
    this.error = error.message;
    Diagnostics.log('error', 'collaboration', event, { instanceId: sessionId, generation: this.generation }, error);
  }
}

export const nativeDeviceCollaboration: NativeDeviceCollaboration = new NativeDeviceCollaboration();
