import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { Diagnostics } from '../model/Diagnostics';
import { t } from '../model/I18n';
import { nearbyTraceId, parsePeerThread, peerHasOutput, peerLiveMessage, peerThreadText } from '../model/PeerSyncData';
import { SessionEvent } from './SessionContracts';
import { SessionService } from './SessionService';
import { NearbyConnectionFailure, NearbyConversationLink, nearbyConversationInvite, nearbyConversationOptions,
  nearbyConversationPeer } from './NearbyConversationChannel';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const THREAD = /^[A-Za-z0-9_-]{1,128}$/;
const TIMEOUT = 15000;
const CONCURRENT_CONNECT_MS = 2000;
const CONNECT_GRACE_MS = 750;
const STREAM_INTERVAL_MS = 120;

export interface ConversationDevice { id: string; name: string; }
interface PeerConversationInput {
  deviceId: string;
  owner: string;
  threadId: string;
  sourceThreadId: string;
  requestId: string;
  text: string;
}
interface CommandAttempt {
  input: PeerConversationInput;
  sending?: Promise<void>;
}
interface Packet {
  kind: string;
  replyTo?: string;
  origin?: string;
  threadId?: string;
  requestId?: string;
  create?: boolean;
  text?: string;
  error?: string;
}
interface Reply {
  link: NearbyConversationLink;
  complete: (packet?: Packet, error?: Error) => void;
}
interface Opening {
  origin: string;
  threadId: string;
  sourceThreadId: string;
  complete: (error?: Error) => void;
}
interface ConversationWatch {
  id: string;
  messageId: string;
  running: boolean;
  answer: string;
  error: string;
  sending: boolean;
  outputSent: boolean;
  dirty: boolean;
  timer: number;
}
class ConversationPeer {
  origin: string = '';
  readonly link: NearbyConversationLink;
  readonly watches: Map<string, ConversationWatch> = new Map();
  readonly tracedAnswers: Map<string, string> = new Map();
  constructor(link: NearbyConversationLink) { this.link = link; }
}

export async function peerConversationCollisionId(origin: string, id: string): Promise<string> {
  const digest = cryptoFramework.createMd('SHA256');
  await digest.update({ data: new util.TextEncoder().encodeInto(origin + ':' + id) });
  const bytes = (await digest.digest()).data;
  return 'peer-' + Array.from(bytes).map((byte) => byte.toString(16).padStart(2, '0')).join('');
}

class NearbyConversations {
  private context?: common.UIAbilityContext;
  private session?: SessionService;
  private origin: string = '';
  private localNetworkId?: () => string;
  private discover?: () => ConversationDevice[];
  private unsubscribe?: () => void;
  private deviceListKey: string = '[]';
  private peers: Map<number, ConversationPeer> = new Map();
  private devicesByOrigin: Map<string, string> = new Map();
  private connecting: Map<string, Promise<ConversationPeer>> = new Map();
  private replies: Map<string, Reply> = new Map();
  private openings: Map<string, Opening> = new Map();
  private attempts: Map<string, CommandAttempt> = new Map();

  start(context: common.UIAbilityContext, session: SessionService, origin: string, localNetworkId: () => string,
    discover: () => ConversationDevice[]): void {
    this.context = context; this.session = session; this.origin = origin; this.localNetworkId = localNetworkId; this.discover = discover;
    this.refreshDevices();
    this.unsubscribe = session.subscribe((event: SessionEvent) => this.scheduleProgress(event));
  }

  stop(): void {
    this.discover = undefined; this.localNetworkId = undefined;
    this.unsubscribe?.(); this.unsubscribe = undefined;
    for (const peer of this.peers.values()) { peer.link.close(); }
    this.connecting.clear();
    this.devicesByOrigin.clear();
    for (const opening of this.openings.values()) { opening.complete(new Error(t('附近设备连接已断开。'))); }
    this.refreshDevices();
  }

  refreshDevices(): ConversationDevice[] {
    const devices = this.discover?.() || [];
    const key = JSON.stringify(devices);
    if (key !== this.deviceListKey) {
      this.deviceListKey = key;
      AppStorage.setOrCreate('tinybot.conversation.devices', devices);
    }
    return devices;
  }
  deviceIdForOrigin(origin: string): string { return this.devicesByOrigin.get(origin) || ''; }

  private canConnect(): boolean { return !!this.discover && AppStorage.get<boolean>('tinybot.foreground') === true; }

  accept(want: Record<string, Object>): boolean {
    if (!this.canConnect() || !this.context || this.peers.size >= 12) { return false; }
    const invite = nearbyConversationInvite(want);
    if (!invite || !this.refreshDevices().some((item) => item.id === invite.peer.deviceId)) { return false; }
    try {
      const peer = this.attach(new NearbyConversationLink(this.context, invite.peer, invite.options,
        (link, text) => this.receive(link, text), (link) => this.closed(link)));
      peer.link.open(invite.token).catch((error: Error) =>
        Diagnostics.log('warn', 'sync', 'conversation_accept_failed', undefined, error));
      return true;
    } catch (error) {
      Diagnostics.log('warn', 'sync', 'conversation_accept_failed', undefined, error as Error);
      return false;
    }
  }

  async submit(deviceId: string, owner: string, threadId: string, sourceThreadId: string, text: string,
    onRequest?: (id: string) => void): Promise<void> {
    if (!this.canConnect()) { throw new Error(t('请先在两台设备上开启附近设备同步，并打开 Tinybot。')); }
    const key = JSON.stringify([deviceId, owner, threadId, sourceThreadId, text]);
    let attempt = this.attempts.get(key);
    if (!attempt) {
      attempt = { input: { deviceId: deviceId, owner: owner, threadId: threadId || util.generateRandomUUID(), sourceThreadId: sourceThreadId,
        requestId: 'remote-' + util.generateRandomUUID(), text: text } };
      if (this.attempts.size >= 32) {
        const inactive = Array.from(this.attempts.keys()).find((id) => !this.attempts.get(id)?.sending);
        if (inactive) { this.attempts.delete(inactive); }
      }
      this.attempts.set(key, attempt);
    }
    onRequest?.(attempt.input.requestId);
    if (attempt.sending) { return attempt.sending; }
    const selected = attempt;
    selected.sending = this.sendInput(key, selected.input).finally(() => { selected.sending = undefined; });
    return selected.sending;
  }

  private async sendInput(key: string, input: PeerConversationInput): Promise<void> {
    const traced = Diagnostics.acceptsLog('info');
    const operationId = traced ? nearbyTraceId(input.requestId) : undefined;
    const routing = traced ? Diagnostics.now() : 0;
    const peer = input.owner ? await this.findOwner(input.owner) : await this.connect(input.deviceId);
    if (traced) {
      Diagnostics.log('info', 'sync', 'conversation_route_ready', { operationId: operationId, durationMs: Diagnostics.now() - routing });
    }
    const started = traced ? Diagnostics.now() : 0;
    const reply = await this.call(peer, { kind: 'command', origin: peer.origin, threadId: input.threadId,
      requestId: input.requestId, create: !input.owner, text: input.text });
    if (reply.error) { this.attempts.delete(key); throw new Error(reply.error); }
    if (traced) {
      Diagnostics.log('info', 'sync', 'conversation_acknowledged', { operationId: operationId, durationMs: Diagnostics.now() - started });
    }
    if (!input.owner) {
      await this.openWhenReceived(peer, input);
      if (traced) {
        Diagnostics.log('info', 'sync', 'conversation_opened', { operationId: operationId, durationMs: Diagnostics.now() - routing });
      }
    }
    this.attempts.delete(key);
  }

  private async findOwner(origin: string): Promise<ConversationPeer> {
    for (const peer of this.peers.values()) { if (peer.origin === origin) { return peer; } }
    const devices = this.refreshDevices();
    const previous = this.devicesByOrigin.get(origin);
    const ordered = devices.filter((device) => device.id === previous).concat(devices.filter((device) => device.id !== previous));
    for (const device of ordered) {
      try {
        const peer = await this.connect(device.id);
        if (peer.origin === origin) { return peer; }
      } catch (error) { Diagnostics.log('warn', 'sync', 'conversation_connect_failed', undefined, error as Error); }
    }
    throw new Error(t('会话执行端不在线。请在该设备上打开 Tinybot 并开启附近设备同步。'));
  }

  private connect(deviceId: string): Promise<ConversationPeer> {
    const connected = this.connected(deviceId);
    if (connected) { return Promise.resolve(connected); }
    const connecting = this.connecting.get(deviceId);
    if (connecting) { return connecting; }
    const opening = this.open(deviceId).finally(() => {
      if (this.connecting.get(deviceId) === opening) { this.connecting.delete(deviceId); }
    });
    this.connecting.set(deviceId, opening);
    return opening;
  }

  private connected(deviceId: string): ConversationPeer | undefined {
    return Array.from(this.peers.values()).find((peer) => peer.link.deviceId === deviceId && !!peer.origin);
  }

  private async concurrentConnection(deviceId: string, graceMs: number = CONCURRENT_CONNECT_MS): Promise<ConversationPeer | undefined> {
    // Both devices can request a connection at once. The winning link carries traffic in both directions.
    const started = Date.now();
    while (this.canConnect()) {
      const peer = this.connected(deviceId);
      if (peer) { return peer; }
      const incoming = Array.from(this.peers.values()).some((item) => item.link.deviceId === deviceId);
      const remaining = (incoming ? CONCURRENT_CONNECT_MS : graceMs) - (Date.now() - started);
      if (remaining <= 0) { break; }
      await new Promise<void>((resolve) => { setTimeout(resolve, Math.min(remaining, 50)); });
    }
    return this.connected(deviceId);
  }

  private async open(deviceId: string, retried: boolean = false): Promise<ConversationPeer> {
    if (!this.context || !this.canConnect() || !this.refreshDevices().some((item) => item.id === deviceId)) {
      throw new Error(t('执行端已离线，请检查设备连接。'));
    }
    let peer: ConversationPeer | undefined;
    try {
      const tracing = Diagnostics.acceptsLog('info');
      const started = tracing ? Diagnostics.now() : 0;
      // HarmonyOS allows one collaboration session per pair. Give the lower network ID the first attempt.
      if ((this.localNetworkId?.() || '') > deviceId) {
        const incoming = await this.concurrentConnection(deviceId, CONNECT_GRACE_MS);
        if (incoming) { return incoming; }
      }
      if (!this.canConnect()) { throw new Error(t('执行端已离线，请检查设备连接。')); }
      const connecting = tracing ? Diagnostics.now() : 0;
      peer = this.attach(new NearbyConversationLink(this.context, nearbyConversationPeer(deviceId),
        nearbyConversationOptions(), (link, text) => this.receive(link, text), (link) => this.closed(link)));
      await peer.link.open();
      const reply = await this.call(peer, { kind: 'identify', origin: this.origin });
      this.identify(peer, reply.origin);
      if (tracing) {
        Diagnostics.log('info', 'sync', 'conversation_connected', {
          delayMs: connecting - started, durationMs: Diagnostics.now() - connecting
        });
      }
      return peer;
    } catch (error) {
      peer?.link.close();
      const concurrent = await this.concurrentConnection(deviceId);
      if (concurrent) { return concurrent; }
      if (!retried && this.canConnect() && error instanceof NearbyConnectionFailure && error.retryable) {
        return this.open(deviceId, true);
      }
      Diagnostics.log('warn', 'sync', 'conversation_connect_failed', { code: (error as BusinessError).code }, error as Error);
      throw new Error(t('无法连接执行端，请在两台设备上打开 Tinybot 并开启附近设备同步。'));
    }
  }

  private attach(link: NearbyConversationLink): ConversationPeer {
    const peer = new ConversationPeer(link);
    this.peers.set(link.id, peer);
    return peer;
  }

  private identify(peer: ConversationPeer, origin?: string): void {
    if (!origin || !UUID.test(origin) || origin === this.origin || peer.origin && peer.origin !== origin) {
      throw new Error('Invalid nearby conversation origin');
    }
    peer.origin = origin;
    this.devicesByOrigin.set(origin, peer.link.deviceId);
  }

  private closed(link: NearbyConversationLink): void {
    const peer = this.peers.get(link.id);
    this.peers.delete(link.id);
    if (peer) { for (const id of peer.watches.keys()) { this.removeWatch(peer, id); } }
    for (const reply of this.replies.values()) {
      if (reply.link === link) { reply.complete(undefined, new Error(t('附近设备连接已断开。'))); }
    }
    if (!peer?.origin || Array.from(this.peers.values()).some((item) => item.origin === peer.origin)) { return; }
    this.session?.clearPeerProgress(peer.origin, undefined, true);
    for (const opening of this.openings.values()) {
      if (opening.origin === peer.origin) { opening.complete(new Error(t('附近设备连接已断开。'))); }
    }
  }

  private call(peer: ConversationPeer, packet: Packet): Promise<Packet> {
    const id = util.generateRandomUUID();
    packet.replyTo = id;
    return new Promise<Packet>((resolve, reject) => {
      const complete = (reply?: Packet, error?: Error): void => {
        clearTimeout(timer); this.replies.delete(id);
        if (reply) { resolve(reply); }
        else { reject(error); }
      };
      const timer = setTimeout(() => complete(undefined, new Error(t('等待执行端确认超时，请重试。'))), TIMEOUT);
      this.replies.set(id, { link: peer.link, complete: complete });
      this.send(peer, packet).catch((error: Error) => complete(undefined, error));
    });
  }

  private send(peer: ConversationPeer, packet: Packet): Promise<void> {
    return peer.link.send(JSON.stringify(packet));
  }

  private async receive(link: NearbyConversationLink, text: string): Promise<void> {
    const peer = this.peers.get(link.id);
    if (!peer || !this.discover || !this.session) { return; }
    const packet = JSON.parse(text) as Packet;
    if (!packet || typeof packet.kind !== 'string') { throw new Error('Invalid nearby conversation packet'); }
    if (packet.kind === 'reply') {
      const reply = this.replies.get(packet.replyTo || '');
      if (reply?.link === link) { reply.complete(packet); }
      return;
    }
    if (packet.kind === 'identify' && packet.replyTo && UUID.test(packet.replyTo)) {
      this.identify(peer, packet.origin);
      await this.send(peer, { kind: 'reply', replyTo: packet.replyTo, origin: this.origin });
      return;
    }
    const id = packet.threadId;
    if (!peer.origin || !id || !THREAD.test(id)) { throw new Error('Invalid nearby conversation identity'); }
    if (packet.kind === 'command') {
      await this.receiveCommand(peer, id, packet);
    } else if (packet.kind === 'answer' && typeof packet.text === 'string') {
      const answer = peerLiveMessage(packet.text);
      if (this.session.receivePeerAnswer(peer.origin, id, answer, true) && Diagnostics.acceptsLog('info') &&
        peer.tracedAnswers.get(id) !== answer.id && peerHasOutput(answer)) {
        peer.tracedAnswers.set(id, answer.id);
        Diagnostics.log('info', 'sync', 'conversation_output_applied', {
          operationId: nearbyTraceId(packet.requestId), chars: packet.text.length, streaming: true
        });
      }
    } else if (packet.kind === 'state') {
      await this.receiveState(peer, id, packet);
    } else {
      throw new Error('Unsupported nearby conversation packet');
    }
  }

  private async receiveCommand(peer: ConversationPeer, id: string, packet: Packet): Promise<void> {
    const requestId = packet.requestId;
    if (packet.origin !== this.origin || !packet.replyTo || !UUID.test(packet.replyTo) || !requestId ||
      !requestId.startsWith('remote-') || !UUID.test(requestId.slice(7)) || typeof packet.create !== 'boolean' ||
      packet.create && !UUID.test(id) || typeof packet.text !== 'string') { throw new Error('Invalid nearby conversation command'); }
    let error = '';
    const operationId = Diagnostics.acceptsLog('info') ? nearbyTraceId(requestId) : undefined;
    const started = operationId === undefined ? 0 : Diagnostics.now();
    try {
      const allowed = (): boolean => this.canConnect() && this.peers.get(peer.link.id) === peer;
      if (!allowed()) { throw new Error(t('请在执行端打开 Tinybot。')); }
      await this.session!.acceptPeerInput(id, requestId, packet.text, packet.create, allowed);
      if (operationId !== undefined) {
        Diagnostics.log('info', 'sync', 'conversation_admitted', { operationId: operationId, durationMs: Diagnostics.now() - started });
      }
    } catch (failure) {
      error = (failure as Error).message || t('执行端暂时无法接收消息。');
      Diagnostics.log('warn', 'sync', 'conversation_admission_failed', { threadId: id }, failure as Error);
    }
    await this.send(peer, { kind: 'reply', replyTo: packet.replyTo, error: error || undefined });
    if (!error && this.peers.get(peer.link.id) === peer && !peer.watches.has(id)) {
      if (peer.watches.size >= 32) { this.removeWatch(peer, peer.watches.keys().next().value); }
      const watch: ConversationWatch = { id: id, messageId: '', running: false, answer: '', error: '', sending: false,
        outputSent: false, dirty: false, timer: -1 };
      peer.watches.set(id, watch);
      this.scheduleWatch(peer, watch, true);
    }
  }

  private async openWhenReceived(peer: ConversationPeer, input: PeerConversationInput): Promise<void> {
    const key = peer.origin + ':' + input.threadId;
    const existing = this.session!.peerThreadId(peer.origin, input.threadId);
    if (existing) { await this.selectIfCurrent(input.sourceThreadId, existing); return; }
    return new Promise<void>((resolve, reject) => {
      const complete = (error?: Error): void => {
        clearTimeout(timer); this.openings.delete(key);
        if (error) { reject(error); } else { resolve(); }
      };
      const timer = setTimeout(() => complete(new Error(t('执行端已接收，正在等待会话同步。可重试查看同一个会话。'))), TIMEOUT);
      this.openings.set(key, { origin: peer.origin, threadId: input.threadId, sourceThreadId: input.sourceThreadId, complete: complete });
    });
  }

  private async selectIfCurrent(source: string, target: string): Promise<void> {
    if (this.session!.activeThreadId === source) { await this.session!.selectThread(target); }
  }

  private async receiveState(peer: ConversationPeer, id: string, packet: Packet): Promise<void> {
    if (typeof packet.text === 'string') {
      const tracing = Diagnostics.acceptsLog('info');
      const started = tracing ? Diagnostics.now() : 0;
      const thread = parsePeerThread(packet.text, id);
      if (thread.projectId && !this.session!.hasProject(thread.projectId)) { return; }
      const collision = await peerConversationCollisionId(peer.origin, id);
      if (this.peers.get(peer.link.id) !== peer) { return; }
      await this.session!.receivePeerChanges([], [{ origin: peer.origin, id: id, collisionId: collision, thread: thread, direct: true }], [], this.origin);
      if (tracing) {
        const last = thread.messages[thread.messages.length - 1];
        Diagnostics.log('info', 'sync', 'conversation_snapshot_applied', {
          operationId: nearbyTraceId(packet.requestId), durationMs: Diagnostics.now() - started, chars: packet.text.length,
          streaming: last?.status === 'generating'
        });
        if (last && peer.tracedAnswers.get(id) !== last.id && peerHasOutput(last)) {
          peer.tracedAnswers.set(id, last.id);
          Diagnostics.log('info', 'sync', 'conversation_output_applied', {
            operationId: nearbyTraceId(packet.requestId), streaming: last.status === 'generating'
          });
        }
      }
    }
    const error = typeof packet.error === 'string' ? packet.error : '';
    this.session!.receivePeerExecutionError(peer.origin, id, error);
    const opening = this.openings.get(peer.origin + ':' + id);
    if (!opening) { return; }
    const localId = this.session!.peerThreadId(peer.origin, id);
    if (localId) { await this.selectIfCurrent(opening.sourceThreadId, localId); opening.complete(); }
    else if (error) { opening.complete(new Error(error)); }
  }

  private removeWatch(peer: ConversationPeer, id: string): void {
    const watch = peer.watches.get(id);
    if (watch && watch.timer >= 0) { clearTimeout(watch.timer); }
    peer.watches.delete(id);
  }

  private scheduleProgress(event: SessionEvent): void {
    if (event.kind !== 'snapshot' && event.kind !== 'thread' && event.kind !== 'message' &&
      event.kind !== 'text' && event.kind !== 'reasoning' && event.kind !== 'tool') { return; }
    for (const peer of this.peers.values()) {
      if (event.threadId) {
        const watch = peer.watches.get(event.threadId);
        if (watch) { this.scheduleWatch(peer, watch, true); }
      } else {
        for (const watch of peer.watches.values()) { this.scheduleWatch(peer, watch, false); }
      }
    }
  }

  private scheduleWatch(peer: ConversationPeer, watch: ConversationWatch, changed: boolean): void {
    const thread = this.session?.shareableThread(watch.id);
    if (!thread) { this.removeWatch(peer, watch.id); return; }
    const last = thread.messages[thread.messages.length - 1];
    const running = this.session!.shareableThreadRunning(watch.id);
    if (running && last && last.status !== 'generating') { return; }
    const error = !running ? this.session!.shareableThreadError(watch.id) : '';
    const structural = !!last && (last.id !== watch.messageId || watch.running !== running);
    const immediate = structural || error !== watch.error ||
      !!last && last.status === 'generating' && !watch.outputSent && peerHasOutput(last);
    if (!immediate && (!changed || last?.status !== 'generating')) { return; }
    if (watch.sending) { watch.dirty = true; return; }
    if (immediate) {
      if (watch.timer >= 0) { clearTimeout(watch.timer); watch.timer = -1; }
      this.flushWatch(peer, watch);
    } else if (watch.timer < 0) {
      watch.timer = setTimeout(() => { watch.timer = -1; this.flushWatch(peer, watch); }, STREAM_INTERVAL_MS);
    }
  }

  private async flushWatch(peer: ConversationPeer, watch: ConversationWatch): Promise<void> {
    if (watch.sending || !this.session || peer.watches.get(watch.id) !== watch) { return; }
    const thread = this.session.shareableThread(watch.id);
    if (!thread) { this.removeWatch(peer, watch.id); return; }
    const last = thread.messages[thread.messages.length - 1];
    const requestId = thread.messages[thread.messages.length - 2]?.id;
    const running = this.session.shareableThreadRunning(watch.id);
    // Terminal turns reach the mirror after the executor's last checkpoint.
    if (running && last && last.status !== 'generating') { return; }
    const error = !running ? this.session.shareableThreadError(watch.id) : '';
    const structural = !!last && (last.id !== watch.messageId || watch.running !== running);
    const answer = last?.status === 'generating' ? JSON.stringify(last) : '';
    const hasOutput = !!last && !!answer && peerHasOutput(last);
    if (!structural && answer === watch.answer && error === watch.error) { return; }
    watch.sending = true;
    try {
      if (structural || error !== watch.error) {
        const tracing = Diagnostics.acceptsLog('info');
        const started = tracing ? Diagnostics.now() : 0;
        const text = last ? peerThreadText(thread) : undefined;
        await this.send(peer, { kind: 'state', threadId: watch.id, requestId: requestId, text: text, error: error || undefined });
        if (tracing) {
          Diagnostics.log('info', 'sync', 'conversation_snapshot_sent', {
            operationId: nearbyTraceId(requestId), durationMs: Diagnostics.now() - started, chars: text?.length,
            streaming: last?.status === 'generating'
          });
        }
      }
      if (answer && (structural || answer !== watch.answer)) {
        const tracing = hasOutput && (last.id !== watch.messageId || !watch.outputSent) && Diagnostics.acceptsLog('info');
        const started = tracing ? Diagnostics.now() : 0;
        await this.send(peer, { kind: 'answer', threadId: watch.id, requestId: requestId, text: answer });
        if (tracing) {
          Diagnostics.log('info', 'sync', 'conversation_first_output_sent', {
            operationId: nearbyTraceId(requestId), chars: answer.length, durationMs: Diagnostics.now() - started
          });
        }
      }
      watch.messageId = last?.id || ''; watch.running = running; watch.answer = answer; watch.error = error; watch.outputSent = hasOutput;
    } catch (failure) {
      Diagnostics.log('warn', 'sync', 'conversation_progress_failed', { threadId: watch.id }, failure as Error);
      this.removeWatch(peer, watch.id);
    } finally {
      watch.sending = false;
      if (watch.dirty && peer.watches.get(watch.id) === watch) {
        watch.dirty = false; this.scheduleWatch(peer, watch, true);
      }
    }
  }
}

export const nearbyConversations = new NearbyConversations();
