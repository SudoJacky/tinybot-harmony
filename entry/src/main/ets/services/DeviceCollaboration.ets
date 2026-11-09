import { t } from '../model/I18n';
import { CollaborationOutput, CollaborationPacket, CollaborationThreadState, CollaborationMessageState,
  projectCollaborationThreads, collaborationUpdate, applyCollaborationUpdate } from '../model/DeviceCollaboration';
import { SessionService } from './SessionService';
import { Cancellation } from './Cancellation';

export interface CollaborationLink {
  send(packet: CollaborationPacket): Promise<void>;
  close(): void;
}
interface PendingCommand {
  resolve: (id: string) => void; reject: (error: Error) => void; timer: number;
}

// Each device owns and persists its own executions. Remote views are disposable projections.
@Observed
export class DeviceCollaboration {
  connected: boolean = false;
  peerName: string = '';
  localName: string = '';
  error: string = '';
  localThreads: CollaborationThreadState[] = [];
  peerThreads: CollaborationThreadState[] = [];
  peerCatalogReady: boolean = false;
  selectedDevice: string = 'local';
  selectedId: string = '';
  output?: CollaborationOutput;
  messages: CollaborationMessageState[] = [];
  draft: string = '';
  submitting: boolean = false;
  private session?: SessionService;
  private unsubscribe?: () => void;
  private link?: CollaborationLink;
  private peerWatch: string = '';
  private peerWatchId: string = '';
  private viewing: string = '';
  private timer: number = -1;
  private dirty: boolean = false;
  private publishing: boolean = false;
  private lastCatalog: string = '';
  private lastOutput?: CollaborationOutput;
  private pending: Map<string, PendingCommand> = new Map<string, PendingCommand>();
  private drafts: Map<string, string> = new Map<string, string>();
  private receipts: Map<string, Promise<CollaborationPacket>> = new Map<string, Promise<CollaborationPacket>>();
  private createId: () => string;
  private admission: Cancellation = new Cancellation();
  private greeted: boolean = false;

  constructor(createId: () => string) { this.createId = createId; }
  attach(session: SessionService): void {
    if (this.session === session) { return; }
    this.unsubscribe?.(); this.session = session;
    this.unsubscribe = session.subscribe((event) => {
      if (event.kind !== 'draft' && event.kind !== 'preferences') { this.changed(); }
    });
    this.changed();
  }
  opened(link: CollaborationLink, localName: string): void {
    this.disconnected(); this.link = link; this.localName = localName;
    this.admission = new Cancellation();
    this.peerThreads = []; this.peerCatalogReady = false; this.greeted = false;
    if (this.selectedDevice === 'peer') { this.showOutput(undefined); }
    this.connected = true; this.error = ''; this.lastCatalog = '';
    this.send({ version: 1, kind: 'hello', name: localName }); this.changed();
  }
  disconnected(error: string = ''): void {
    this.admission.cancel();
    this.link = undefined; this.connected = false; this.peerWatch = ''; this.peerWatchId = '';
    this.viewing = ''; this.lastCatalog = ''; this.lastOutput = undefined;
    if (error) { this.error = error; }
    for (const item of this.pending.values()) {
      clearTimeout(item.timer); item.reject(new Error(t('未收到执行端确认，请先检查会话状态，避免重复提交。')));
    }
    this.pending.clear();
    // Retain the last visible result, explicitly marked offline by the UI.
  }
  dispose(): void {
    this.link?.close(); this.disconnected(); this.unsubscribe?.(); this.unsubscribe = undefined;
    clearTimeout(this.timer); this.timer = -1; this.session = undefined;
  }
  select(device: string, id: string): void {
    this.drafts.set(this.selectedDevice + ':' + this.selectedId, this.draft);
    this.selectedDevice = device; this.selectedId = id; this.showOutput(undefined); this.error = '';
    this.draft = this.drafts.get(device + ':' + id) || '';
    if (device === 'local') {
      this.refreshLocalOutput();
      if (this.connected) { this.watch(''); }
    } else if (this.connected) { this.watch(id); }
  }
  async create(device: string): Promise<void> {
    if (this.submitting) { return; }
    this.submitting = true; this.error = '';
    try {
      const id = device === 'local' ? await this.requireSession().createCollaborationThread() :
        await this.request('create');
      this.select(device, id); this.changed();
    } catch (error) { this.error = (error as Error).message; }
    finally { this.submitting = false; }
  }
  async submit(): Promise<void> {
    const text = this.draft.trim(); const id = this.selectedId; const device = this.selectedDevice;
    if (!text || !id || this.submitting) { return; }
    this.submitting = true; this.error = '';
    try {
      if (device === 'local') { await this.requireSession().submitCollaborationInput(id, text); }
      else { await this.request('send', id, text); }
      const key = device + ':' + id;
      if (this.selectedDevice === device && this.selectedId === id && this.draft.trim() === text) { this.draft = ''; }
      if (this.drafts.get(key)?.trim() === text) { this.drafts.delete(key); }
    } catch (error) { this.error = (error as Error).message; }
    finally { this.submitting = false; this.changed(); }
  }
  async stop(): Promise<void> {
    const id = this.selectedId;
    if (!id) { return; }
    try {
      if (this.selectedDevice === 'local') { await this.requireSession().stop(undefined, id); }
      else { await this.request('stop', id); }
    } catch (error) { this.error = (error as Error).message; }
  }
  receive(packet: CollaborationPacket): void {
    if (!this.connected) { return; }
    if (packet.kind === 'hello') {
      if (typeof packet.name !== 'string' || packet.name.length > 256) { throw new Error('Invalid peer name.'); }
      this.peerName = packet.name;
      if (!this.greeted) {
        // Native link establishment can precede the peer's business listener. Acknowledge readiness.
        this.greeted = true; this.send({ version: 1, kind: 'hello', name: this.localName });
        if (this.selectedDevice === 'peer' && this.selectedId) { this.watch(this.selectedId); }
        this.changed();
      }
    } else if (packet.kind === 'catalog') {
      if (!Array.isArray(packet.threads) || packet.threads.length > 10000) { throw new Error('Invalid collaboration catalog.'); }
      this.peerThreads = projectCollaborationThreads(this.peerThreads, packet.threads); this.peerCatalogReady = true;
    } else if (packet.kind === 'watch') {
      if (typeof packet.threadId !== 'string' || packet.threadId.length > 128 ||
        typeof packet.watchId !== 'string' || packet.watchId.length > 128) { throw new Error('Invalid watch request.'); }
      this.peerWatch = packet.threadId; this.peerWatchId = packet.watchId; this.lastOutput = undefined; this.changed();
    } else if (packet.kind === 'output') {
      if (packet.watchId !== this.viewing) { return; }
      if (packet.error) { this.error = packet.error; return; }
      if (!packet.output?.thread || !Array.isArray(packet.output.messages)) { throw new Error('Invalid collaboration output.'); }
      if (this.selectedDevice === 'peer' && this.selectedId === packet.output.thread.id) {
        this.showOutput(applyCollaborationUpdate(this.output, packet));
      }
    } else if (packet.kind === 'receipt') {
      const waiting = this.pending.get(packet.requestId || '');
      if (!waiting) { return; }
      clearTimeout(waiting.timer); this.pending.delete(packet.requestId!);
      if (packet.error) { waiting.reject(new Error(packet.error)); } else { waiting.resolve(packet.threadId || ''); }
    } else if (packet.kind === 'command') {
      const link = this.link!;
      this.command(packet).then((receipt) => {
        if (this.link === link) { this.send(receipt); }
        this.changed();
      });
    }
  }
  private requireSession(): SessionService {
    if (!this.session?.state.ready) { throw new Error(t('会话服务尚未就绪。')); }
    return this.session;
  }
  private command(packet: CollaborationPacket): Promise<CollaborationPacket> {
    const id = packet.requestId || '';
    if (!/^[A-Za-z0-9_-]{1,128}$/.test(id) || !['create', 'send', 'stop'].includes(packet.action || '')) {
      throw new Error('Invalid collaboration command.');
    }
    const previous = this.receipts.get(id);
    if (previous) { return previous; }
    const result = this.execute(packet);
    this.receipts.set(id, result);
    // Receipts survive connection loss; commands are never replayed automatically.
    if (this.receipts.size > 512) { this.receipts.delete(Array.from(this.receipts.keys())[0]); }
    return result;
  }
  private async execute(packet: CollaborationPacket): Promise<CollaborationPacket> {
    const receipt: CollaborationPacket = { version: 1, kind: 'receipt', requestId: packet.requestId, threadId: packet.threadId };
    const admission = this.admission;
    try {
      admission.check();
      const session = this.requireSession();
      if (packet.action === 'create') { receipt.threadId = await session.createCollaborationThread(); }
      else {
        if (typeof packet.threadId !== 'string' || !session.collaborationThreads().some((item) => item.id === packet.threadId)) {
          throw new Error(t('协同会话已不存在。'));
        }
        if (packet.action === 'stop') { await session.stop(undefined, packet.threadId); }
        else {
          if (typeof packet.text !== 'string') { throw new Error('Invalid collaboration input.'); }
          await session.submitCollaborationInput(packet.threadId, packet.text, admission);
        }
      }
    } catch (error) { receipt.error = (error as Error).message; }
    return receipt;
  }
  private request(action: 'create' | 'send' | 'stop', threadId?: string, text?: string): Promise<string> {
    const link = this.link;
    if (!link) { return Promise.reject(new Error(t('执行设备未连接。'))); }
    const requestId = this.createId();
    return new Promise<string>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(requestId); reject(new Error(t('未收到执行端确认，请先检查会话状态，避免重复提交。')));
      }, 30000);
      this.pending.set(requestId, { resolve: resolve, reject: reject, timer: timer });
      link.send({ version: 1, kind: 'command', requestId: requestId, action: action, threadId: threadId, text: text })
        .catch((error: Error) => {
          clearTimeout(timer); this.pending.delete(requestId); reject(error);
        });
    });
  }
  private send(packet: CollaborationPacket): void {
    const link = this.link;
    if (!link) { return; }
    link.send(packet).catch((error: Error) => { if (this.link === link) { this.error = error.message; link.close(); } });
  }
  private watch(id: string): void {
    this.viewing = this.createId(); this.send({ version: 1, kind: 'watch', threadId: id, watchId: this.viewing });
  }
  private changed(): void {
    this.dirty = true;
    if (this.timer !== -1 || this.publishing) { return; }
    this.timer = setTimeout(() => { this.timer = -1; this.publish(); }, 120);
  }
  private refreshLocalOutput(): void {
    if (this.selectedDevice !== 'local' || !this.selectedId || !this.session?.state.ready) { return; }
    try { this.showOutput(this.session.collaborationOutput(this.selectedId)); }
    catch (error) { this.showOutput(undefined); this.error = (error as Error).message; }
  }
  private showOutput(output: CollaborationOutput | undefined): void {
    this.output = output;
    const existing = new Map<string, CollaborationMessageState>();
    for (const message of this.messages) { existing.set(message.id, message); }
    this.messages = (output?.messages || []).map((message): CollaborationMessageState => {
      const state = existing.get(message.id);
      if (state) { state.update(message); return state; }
      return new CollaborationMessageState(message);
    });
  }
  private async publish(): Promise<void> {
    if (!this.session?.state.ready) { return; }
    this.publishing = true; this.dirty = false;
    const link = this.link;
    try {
      const threads = this.session.collaborationThreads();
      this.localThreads = projectCollaborationThreads(this.localThreads, threads); this.refreshLocalOutput();
      if (!link || !this.greeted) { return; }
      const catalog = JSON.stringify(threads);
      if (catalog !== this.lastCatalog) {
        await link.send({ version: 1, kind: 'catalog', threads: threads });
        if (this.link === link) { this.lastCatalog = catalog; }
      }
      if (this.peerWatch && this.link === link) {
        const watched = this.peerWatch;
        const watchId = this.peerWatchId;
        let output: CollaborationOutput;
        try { output = this.session.collaborationOutput(watched); }
        catch (error) { await link.send({ version: 1, kind: 'output', watchId: watchId, error: (error as Error).message }); return; }
        const packet = collaborationUpdate(this.lastOutput, output);
        if (packet) { packet.watchId = watchId; await link.send(packet); }
        if (this.link === link && this.peerWatch === watched && this.peerWatchId === watchId) { this.lastOutput = output; }
      }
    } catch (error) { if (this.link === link) { this.error = (error as Error).message; } }
    finally { this.publishing = false; if (this.dirty) { this.changed(); } }
  }
}
