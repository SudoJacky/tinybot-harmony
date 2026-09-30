import { AppData, MessageData, ModelConfig, ThreadData, copyModelConfig, emptyData } from '../model/Conversation';
import { estimateContextTokens, threadHistory } from '../model/ConversationContext';
import { ModelReference, ProviderProfile, migrateProfiles, modelConfig } from '../model/ProviderProfiles';
import { InputMode, MAX_INPUT_TEXT, PendingInput, nextPendingInput, validatePendingInputs } from '../model/PendingInput';
import { ExtensionSettings, SkillData, SkillFile, defaultExtensions, explicitSkill, parseSkill, validateExtensions } from '../model/Skills';
import { threadTitle } from '../model/SessionManagement';
import { AgentEvent, AgentRuntime } from './AgentRuntime';
import { AgentTools } from './AgentLoop';
import { CredentialVault, ProfileSettings, ProviderDraft } from './ProfileSettings';
import { SessionEvent, SessionRepository, SessionResources, SessionState } from './SessionContracts';
import { prepareSessionContext, sessionInstructions } from './SessionContext';

// Sole owner of application/session data and admission. No ArkUI or platform Kit imports.
export class SessionService {
  private data: AppData = emptyData();
  private status: SessionState = { ready: false, phase: 'idle', error: '', saveError: '',
    contextStatus: '', contextTokens: 0, acceptingSteering: false };
  private repository: SessionRepository;
  private resources: SessionResources;
  private runtime: AgentRuntime;
  private credentials: CredentialVault;
  private profiles: ProfileSettings;
  private draftRevision: number = 0;
  private listeners: Set<(event: SessionEvent) => void> = new Set<(event: SessionEvent) => void>();

  constructor(repository: SessionRepository, runtime: AgentRuntime, credentials: CredentialVault, resources: SessionResources) {
    this.repository = repository;
    this.runtime = runtime;
    this.credentials = credentials;
    this.resources = resources;
    this.profiles = new ProfileSettings(credentials, () => resources.createId());
  }

  snapshot(): AppData { return JSON.parse(JSON.stringify(this.data)) as AppData; }
  get state(): SessionState { return JSON.parse(JSON.stringify(this.status)) as SessionState; }
  get canMutate(): boolean { return this.status.ready && this.status.phase === 'idle' && this.status.saveError.length === 0; }
  get canQueueInput(): boolean {
    return this.status.ready && !this.active.archived && this.status.saveError.length === 0 &&
      (this.status.phase === 'idle' || this.status.phase === 'running');
  }
  get currentConfig(): ModelConfig {
    const reference = this.active.modelRef;
    if (!reference) { return copyModelConfig(this.data.config, false); }
    const profile = this.providerProfiles.find((item: ProviderProfile) => item.id === reference.providerId);
    if (!profile || !profile.enabled || !profile.models.includes(reference.modelId)) {
      const unavailable = copyModelConfig(this.data.config, false);
      unavailable.contextWindow = profile?.contextWindow || this.data.config.contextWindow;
      return unavailable;
    }
    return modelConfig(this.providerProfiles, reference, this.data.config);
  }
  private get active(): ThreadData { return this.requireThread(this.data.activeThreadId); }
  private get providerProfiles(): ProviderProfile[] { return this.data.providerProfiles || []; }
  private get extensions(): ExtensionSettings { return this.data.extensions || defaultExtensions(); }

  subscribe(listener: (event: SessionEvent) => void): () => void {
    this.listeners.add(listener);
    return () => { this.listeners.delete(listener); };
  }

  async initialize(): Promise<void> {
    if (this.status.ready || this.status.phase !== 'idle') { return; }
    this.status.phase = 'loading'; this.status.error = ''; this.publish('state');
    try {
      const data = await this.repository.load();
      const migrate = data.providerProfiles === undefined;
      data.providerProfiles = data.providerProfiles || migrateProfiles(data.config);
      data.extensions = data.extensions || defaultExtensions();
      for (const thread of data.threads) {
        await this.resources.ensureWorkspace(thread.id);
        if ((thread.pendingInputs || []).length > 0) { thread.queuePaused = true; }
        if (migrate && data.config.configured) { thread.modelRef = { providerId: data.config.providerId, modelId: data.config.model }; }
      }
      this.data = data;
      this.resources.configureProviders(this.providerProfiles);
      let active = data.threads.find((thread) => thread.id === data.activeThreadId && !thread.archived) ||
        data.threads.find((thread) => !thread.archived);
      const created = !active;
      if (!active) { active = this.freshThread(); await this.resources.ensureWorkspace(active.id); data.threads.unshift(active); }
      data.activeThreadId = active.id;
      if (created || migrate) { await this.persist(); }
      this.status.ready = true;
      this.refreshContext();
    } catch (error) { this.status.error = '打开本地会话或工作区失败：' + (error as Error).message; }
    finally { this.status.phase = 'idle'; this.publish('snapshot'); }
  }

  async newThread(): Promise<boolean> {
    return this.mutate('新建对话失败：', async () => {
      const thread = this.freshThread(); await this.resources.ensureWorkspace(thread.id);
      this.data.threads.unshift(thread); this.data.activeThreadId = thread.id;
      this.status.contextStatus = ''; await this.persist();
    });
  }
  async selectThread(id: string): Promise<boolean> {
    return this.mutate('打开对话失败：', async () => {
      const thread = this.requireThread(id); await this.resources.ensureWorkspace(thread.id);
      this.data.activeThreadId = id; this.status.contextStatus = ''; await this.persist();
    });
  }
  async deleteThread(id: string): Promise<boolean> {
    return this.mutate('删除对话失败：', async () => {
      this.requireThread(id);
      await this.replaceActive(id);
      // Deleting a conversation deliberately retains its workspace.
      this.data.threads = this.data.threads.filter((thread) => thread.id !== id);
      await this.persist();
    });
  }
  async renameThread(id: string, title: string): Promise<boolean> {
    return this.mutate('重命名失败：', async () => {
      const thread = this.requireThread(id); thread.title = threadTitle(title); thread.titleEdited = true; await this.persist();
    });
  }
  async pinThread(id: string): Promise<boolean> {
    return this.mutate('置顶状态保存失败：', async () => {
      const thread = this.requireThread(id); thread.pinned = !thread.pinned; await this.persist();
    });
  }
  async archiveThread(id: string): Promise<boolean> {
    return this.mutate('归档状态保存失败：', async () => {
      const thread = this.requireThread(id);
      if (!thread.archived) { await this.replaceActive(id); }
      thread.archived = !thread.archived; await this.persist();
    });
  }

  setDraft(text: string, threadId: string = this.data.activeThreadId): void {
    if (!this.status.ready || text.length > MAX_INPUT_TEXT) { return; }
    const thread = this.data.threads.find((item) => item.id === threadId);
    if (!thread || thread.archived) { return; }
    thread.draft = text;
    this.draftRevision++;
    this.emit({ kind: 'draft', state: this.state, threadId: thread.id, content: text });
  }
  async flushDraft(): Promise<void> {
    if (!this.status.ready || this.status.phase === 'saving' || this.status.saveError.length > 0) { return; }
    // Runtime checkpoints and draft writes use the repository's same ordered save lane.
    try { await this.persist(); } catch (_) { /* persist publishes the retained unsaved state. */ }
  }
  async retrySave(): Promise<void> {
    if (!this.status.ready || this.status.phase !== 'idle') { return; }
    this.status.phase = 'saving'; this.publish('state');
    try { await this.persistDraftChanges(-1); }
    catch (_) { /* Keep the explicit retry error visible. */ }
    finally { this.status.phase = 'idle'; this.publish('snapshot'); }
  }

  async selectModel(providerId: string, modelId: string, asDefault: boolean = false): Promise<boolean> {
    if (!this.status.ready || this.active.archived) { return false; }
    return this.mutate('选择模型失败：', async () => {
      const reference: ModelReference = { providerId: providerId, modelId: modelId };
      const config = modelConfig(this.providerProfiles, reference, this.data.config);
      await this.credentials.read(config.credentialAlias);
      const candidate = this.snapshot();
      const thread = candidate.threads.find((item) => item.id === candidate.activeThreadId);
      if (!thread) { throw new Error('当前对话不存在。'); }
      thread.modelRef = reference;
      if (asDefault) { candidate.config = config; }
      await this.commitSettings(candidate); this.status.contextStatus = '';
    });
  }
  async saveProvider(draft: ProviderDraft): Promise<boolean> {
    return this.mutate('', async () => {
      this.status.error = await this.profiles.save(this.snapshot(), draft, (candidate) => this.commitSettings(candidate));
      this.resources.configureProviders(this.providerProfiles);
    });
  }
  async deleteProvider(id: string): Promise<boolean> {
    return this.mutate('删除服务失败：', async () => {
      this.status.error = await this.profiles.remove(this.snapshot(), id, (candidate) => this.commitSettings(candidate));
      this.resources.configureProviders(this.providerProfiles);
    });
  }
  async saveSettings(systemPrompt: string, autoCompact: boolean, webEnabled: boolean): Promise<boolean> {
    return this.mutate('保存助手设置失败：', async () => {
      const candidate = this.snapshot(); candidate.config.systemPrompt = systemPrompt; candidate.config.autoCompact = autoCompact;
      candidate.extensions = { webEnabled: webEnabled, skills: this.extensions.skills };
      await this.commitSettings(candidate);
    });
  }
  async saveSkill(originalName: string, document: string, files: SkillFile[]): Promise<boolean> {
    return this.mutate('保存 Skill 失败：', async () => {
      const skill = parseSkill(document);
      if (this.extensions.skills.some((item: SkillData) => item.name === skill.name && item.name !== originalName)) {
        throw new Error('同名 Skill 已存在，请编辑已有条目或更改 name。');
      }
      const existing = this.extensions.skills.find((item: SkillData) => item.name === originalName);
      if (originalName.length > 0 && !existing) { throw new Error('Skill 不存在。'); }
      skill.enabled = existing ? existing.enabled : true;
      skill.files = JSON.parse(JSON.stringify(files)) as SkillFile[];
      const candidate = this.snapshot();
      candidate.extensions = { webEnabled: this.extensions.webEnabled, skills: existing ?
        this.extensions.skills.map((item: SkillData) => item.name === originalName ? skill : item) : this.extensions.skills.concat([skill]) };
      validateExtensions(candidate.extensions); await this.commitSettings(candidate);
    });
  }
  async changeSkill(name: string, remove: boolean = false): Promise<boolean> {
    return this.mutate('更新 Skill 失败：', async () => {
      const candidate = this.snapshot();
      const extensions = candidate.extensions || defaultExtensions();
      const skill = extensions.skills.find((item: SkillData) => item.name === name);
      if (!skill) { throw new Error('Skill 不存在。'); }
      if (remove) { extensions.skills = extensions.skills.filter((item: SkillData) => item.name !== name); }
      else { skill.enabled = !skill.enabled; }
      candidate.extensions = extensions; await this.commitSettings(candidate);
    });
  }

  async enqueueInput(mode: InputMode): Promise<void> {
    if (!this.canQueueInput || (this.active.draft || '').trim().length === 0) { return; }
    this.status.error = '';
    try {
      if (mode === 'steer' && (!this.status.acceptingSteering || !this.runtime.acceptsSteering)) {
        throw new Error('本轮正在结束或已停止，请将指令加入队列。');
      }
      const text = (this.active.draft || '').trim();
      if (mode === 'steer' && explicitSkill(text).length > 0) { throw new Error('运行中保持当前工具与 Skills；显式调用 /skill: 请使用“加入队列”。'); }
      const pending = (this.active.pendingInputs || []).concat([{ id: this.resources.createId(), mode: mode, text: text }]);
      validatePendingInputs(pending); this.active.pendingInputs = pending;
      if (this.status.phase !== 'running') { this.active.queuePaused = true; }
      this.active.draft = ''; this.publish('snapshot'); await this.persist();
    } catch (error) {
      this.status.error = '指令未能提交：' + (error as Error).message;
      if (this.status.saveError.length > 0) { this.active.queuePaused = true; this.runtime.abort(); }
      this.publish('snapshot');
    }
  }
  async removePendingInput(id: string, edit: boolean = false): Promise<void> {
    if (!this.canQueueInput) { return; }
    const input = (this.active.pendingInputs || []).find((item: PendingInput) => item.id === id);
    if (!input) { this.status.error = '这条指令已经开始执行，不能再撤回。'; this.publish('state'); return; }
    if (edit && (this.active.draft || '').trim().length > 0) { this.status.error = '请先发送或清空当前草稿，再撤回编辑。'; this.publish('state'); return; }
    this.active.pendingInputs = (this.active.pendingInputs || []).filter((item: PendingInput) => item.id !== id);
    if (edit) { this.active.draft = input.text; }
    this.status.error = ''; this.publish('snapshot');
    try { await this.persist(); }
    catch (_) { this.active.queuePaused = true; this.runtime.abort(); this.publish('snapshot'); }
  }

  async send(): Promise<void> {
    if (!this.canMutate || this.active.archived) { return; }
    const text = (this.active.draft || '').trim();
    if (text.length === 0) { return; }
    await this.runTasks(text);
  }
  async resumeQueue(): Promise<void> {
    if (!this.canMutate || this.active.archived || (this.active.pendingInputs || []).length === 0) { return; }
    this.active.queuePaused = false; await this.runTasks();
  }
  async stop(): Promise<void> {
    if (!this.status.ready || (this.status.phase !== 'running' && this.status.phase !== 'compacting')) { return; }
    this.active.queuePaused = true; this.status.acceptingSteering = false;
    this.runtime.abort(); this.publish('snapshot');
    try { await this.persist(); } catch (_) { /* Persist failure remains visible; no queue is drained. */ }
  }
  waitForIdle(): Promise<void> {
    if (this.status.phase === 'idle') { return Promise.resolve(); }
    return new Promise<void>((resolve) => {
      const unsubscribe = this.subscribe((event: SessionEvent) => {
        if (event.state.phase === 'idle') { unsubscribe(); resolve(); }
      });
    });
  }

  async compactHistory(): Promise<void> {
    if (!this.canMutate || this.active.archived || !this.currentConfig.configured) { return; }
    const thread = this.active; const config = this.currentConfig;
    const instructions = sessionInstructions(config, this.extensions); const tools = this.tools(thread);
    this.status.phase = 'compacting'; this.status.error = ''; this.publish('state');
    try {
      const result = await this.runtime.run({ sessionId: thread.id, config: config, messages: [], contextOnly: true, tools: tools }, {
        prepare: async () => {}, checkpoint: () => this.persist(),
        prepareContext: (model, _messages, cancellation) => prepareSessionContext(thread, model, cancellation, true,
          config, instructions, tools.definitions(), () => this.persist(), (status) => this.contextProgress(status))
      });
      if (result.status !== 'complete') { this.status.error = result.status === 'stopped' ? '上下文压缩已停止。' : result.error; }
    } catch (error) { this.status.error = '上下文压缩失败：' + (error as Error).message; }
    finally {
      this.status.phase = 'idle';
      if (this.status.error.length > 0) { this.status.contextStatus = ''; }
      this.refreshContext(); this.publish('snapshot');
    }
  }

  private async runTasks(initial?: string): Promise<void> {
    const thread = this.active;
    if (initial !== undefined && (thread.pendingInputs || []).length === 0) { thread.queuePaused = false; }
    this.status.phase = 'running'; this.publish('state');
    try {
      if (initial !== undefined && !await this.runTask(thread, initial)) { return; }
      let next = nextPendingInput(thread.pendingInputs || [], thread.queuePaused === true);
      while (next && this.status.saveError.length === 0) {
        if (!await this.runTask(thread, next.text, next.id)) { return; }
        next = nextPendingInput(thread.pendingInputs || [], thread.queuePaused === true);
      }
    } catch (error) {
      thread.queuePaused = true; this.status.error = '执行失败：' + (error as Error).message;
      this.resources.reportError(this.status.error);
    } finally {
      this.status.acceptingSteering = false; this.status.phase = 'idle';
      this.refreshContext(); this.publish('snapshot');
    }
  }

  private async runTask(thread: ThreadData, text: string, queuedId?: string): Promise<boolean> {
    const config = this.currentConfig; const selected = explicitSkill(text);
    if (!config.configured) { this.status.error = '当前对话没有可用模型，请选择模型，或添加、启用模型服务。'; thread.queuePaused = true; return false; }
    if (selected.length > 0 && !this.extensions.skills.some((skill: SkillData) => skill.enabled && skill.name === selected)) {
      this.status.error = '指定的 Skill 不存在或已停用，请到设置中的 Skills 管理检查。'; thread.queuePaused = true; return false;
    }
    const tools = this.tools(thread, selected); const instructions = sessionInstructions(config, this.extensions, selected);
    const user: MessageData = { id: this.resources.createId(), role: 'user', content: text, status: 'complete', error: '' };
    const answer: MessageData = { id: this.resources.createId(), role: 'assistant', content: '', status: 'generating', error: '', modelRef: thread.modelRef };
    if (thread.messages.length === 0 && !thread.titleEdited) { thread.title = text.slice(0, 32); }
    thread.messages = thread.messages.concat([user, answer]);
    if (queuedId) { thread.pendingInputs = (thread.pendingInputs || []).filter((item: PendingInput) => item.id !== queuedId); }
    else { thread.draft = ''; }
    thread.updatedAt = Date.now();
    this.data.threads = [thread].concat(this.data.threads.filter((item) => item.id !== thread.id));
    this.status.error = ''; this.status.contextStatus = ''; this.refreshContext(); this.publish('snapshot');
    const unsubscribe = this.runtime.subscribe((event: AgentEvent) => {
      if (event.run.sessionId !== thread.id) { return; }
      answer.content = event.run.turn.content; answer.steps = event.run.turn.steps;
      answer.status = event.run.status === 'running' ? 'generating' : event.run.status; answer.error = event.run.error;
      this.status.acceptingSteering = this.runtime.acceptsSteering && !thread.queuePaused;
      if (event.type === 'run_finishing' && event.run.status !== 'complete') { thread.queuePaused = true; }
      if (event.type === 'text_delta') {
        this.emit({ kind: 'text', state: this.state, threadId: thread.id, messageId: answer.id,
          content: answer.content, step: event.step, stepContent: event.run.turn.steps[event.step || 0].content });
      } else {
        this.emit({ kind: 'message', state: this.state, threadId: thread.id,
          message: JSON.parse(JSON.stringify(answer)) as MessageData });
      }
    });
    try {
      await this.runtime.run({ sessionId: thread.id, config: config, messages: threadHistory(thread, instructions), tools: tools }, {
        prepare: async (cancellation) => { cancellation.check(); await this.resources.ensureWorkspace(thread.id); },
        prepareContext: (model, _messages, cancellation) => prepareSessionContext(thread, model, cancellation, false,
          config, instructions, tools.definitions(), () => this.persist(), (status) => this.contextProgress(status)),
        checkpoint: () => { this.publish('snapshot'); return this.persist(); },
        steering: {
          peek: () => nextPendingInput(thread.pendingInputs || [], thread.queuePaused === true, true),
          consume: (id: string) => { thread.pendingInputs = (thread.pendingInputs || []).filter((item: PendingInput) => item.id !== id); }
        }
      });
    } catch (error) {
      answer.status = 'failed'; answer.error = (error as Error).message; thread.queuePaused = true;
      try { await this.persist(); } catch (_) { /* The in-memory receipt remains available for retry. */ }
    } finally {
      unsubscribe(); this.status.acceptingSteering = false;
      if (answer.status !== 'complete') { thread.queuePaused = true; }
      if (answer.status === 'failed') { this.resources.reportError('Run failed: ' + answer.error); }
      if (this.status.contextStatus.startsWith('正在压缩')) { this.status.contextStatus = ''; }
    }
    return answer.status === 'complete' && this.status.saveError.length === 0;
  }

  private tools(thread: ThreadData, selected: string = ''): AgentTools { return this.resources.tools(thread.id, this.extensions, selected); }
  private refreshContext(): void {
    if (this.data.threads.length === 0) { this.status.contextTokens = 0; return; }
    this.status.contextTokens = estimateContextTokens(threadHistory(this.active, sessionInstructions(this.data.config, this.extensions)), this.tools(this.active).definitions());
  }
  private contextProgress(status: string): void { this.status.contextStatus = status; this.publish('state'); }
  private requireThread(id: string): ThreadData {
    const thread = this.data.threads.find((item) => item.id === id);
    if (!thread) { throw new Error('对话不存在：' + id); } return thread;
  }
  private freshThread(): ThreadData {
    return { id: this.resources.createId(), title: '新对话', updatedAt: Date.now(), messages: [], draft: '', pendingInputs: [], queuePaused: false,
      modelRef: this.data.config.configured ? { providerId: this.data.config.providerId, modelId: this.data.config.model } : undefined };
  }
  private async replaceActive(id: string): Promise<void> {
    if (this.data.activeThreadId !== id) { return; }
    const next = this.data.threads.find((item) => item.id !== id && !item.archived) || this.freshThread();
    await this.resources.ensureWorkspace(next.id);
    if (!this.data.threads.some((item) => item.id === next.id)) { this.data.threads.unshift(next); }
    this.data.activeThreadId = next.id; this.status.contextStatus = '';
  }
  private async mutate(prefix: string, action: () => Promise<void>): Promise<boolean> {
    if (!this.canMutate) { return false; }
    const draftRevision = this.draftRevision;
    this.status.phase = 'saving'; this.status.error = ''; this.publish('state');
    try {
      await action();
      // A settings commit must not overwrite typing that happened while disk/key IO was pending.
      await this.persistDraftChanges(draftRevision);
      this.refreshContext(); return true;
    }
    catch (error) { this.status.error = prefix + (error as Error).message; this.resources.reportError(this.status.error); return false; }
    finally { this.status.phase = 'idle'; this.publish('snapshot'); }
  }
  private async commitSettings(candidate: AppData): Promise<void> {
    await this.repository.save(candidate);
    for (const thread of candidate.threads) {
      const current = this.data.threads.find((item) => item.id === thread.id);
      if (current) { thread.draft = current.draft; }
    }
    this.data = candidate;
  }
  private async persistDraftChanges(revision: number): Promise<void> {
    while (revision !== this.draftRevision) { revision = this.draftRevision; await this.persist(); }
  }
  private async persist(): Promise<void> {
    try { await this.repository.save(this.snapshot()); this.status.saveError = ''; }
    catch (error) {
      this.status.saveError = '会话尚未保存，请重试保存。当前内容仍保留在页面中。原因：' + (error as Error).message;
      if (this.status.phase === 'running') { this.active.queuePaused = true; this.runtime.abort(); }
      this.resources.reportError(this.status.saveError); this.publish('state'); throw new Error(this.status.saveError);
    }
  }
  private publish(kind: 'snapshot' | 'state'): void {
    this.emit({ kind: kind, state: this.state, data: kind === 'snapshot' ? this.snapshot() : undefined });
  }
  private emit(event: SessionEvent): void {
    for (const listener of Array.from(this.listeners)) {
      try { listener(event); }
      catch (error) { this.resources.reportError('Session observer failed: ' + (error as Error).message); }
    }
  }
}
