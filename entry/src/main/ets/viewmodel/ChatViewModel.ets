import { t } from '../model/I18n';
import { UiValues } from '../model/InteractiveUi';
import { RequestUsage } from '../model/Usage';
import { referenceContext } from '../model/ThreadReferences';
import { TeamMember, TeamPlan, TeamRun } from '../model/Team';
import { Attachment, ProductivityData, defaultProductivity, expandTemplate } from '../model/Productivity';
import { AppData, ModelConfig, defaultConfig, copyModelConfig } from '../model/Conversation';
import { contextSettings, estimateTextTokens } from '../model/ConversationContext';
import { ModelChoice, ProviderProfile, availableModels } from '../model/ProviderProfiles';
import { ProviderInfo, builtinProviderInfos } from '../model/Provider';
import { ExtensionSettings, SkillData, defaultExtensions } from '../model/Skills';
import { InputMode } from '../model/PendingInput';
import { matchingThreads } from '../model/SessionManagement';
import { SessionEvent, SessionPhase, SessionState } from '../services/SessionContracts';
import { SessionService } from '../services/SessionService';
import { ProviderEditorViewModel } from './ProviderEditorViewModel';
import { SkillEditorViewModel } from './SkillEditorViewModel';
import { MessageViewModel, ThreadViewModel } from './SessionViewModels';

export { AgentStepViewModel, MessageViewModel, ThreadViewModel, ToolExecutionViewModel } from './SessionViewModels';

@Observed
export class SettingsViewModel {
  userDocument: string = '';
  autoCompact: boolean = true;
  webEnabled: boolean = true;
  error: string = '';
  reset(config: ModelConfig, webEnabled: boolean): void {
    this.userDocument = config.userDocument || ''; this.autoCompact = contextSettings(config).autoCompact;
    this.webEnabled = webEnabled; this.error = '';
  }
}

// ArkUI projection and editor drafts only. Durable data and execution belong to SessionService.
@Observed
export class ChatViewModel {
  productivity: ProductivityData = defaultProductivity();
  ready: boolean = false;
  searchQuery: string = '';
  searchMessageId: string = '';
  async openMessage(threadId: string, messageId: string, query: string = ''): Promise<boolean> {
    if (!await this.selectThread(threadId)) { return false; }
    this.visibleMessageCount = this.active.messages.length; this.searchQuery = query; this.searchMessageId = messageId; return true;
  }
  loading: boolean = false;
  busy: boolean = false;
  generating: boolean = false;
  acceptingSteering: boolean = false;
  error: string = '';
  saveError: string = '';
  draft: string = '';
  contextTokens: number = 0;
  contextStatus: string = '';
  visibleMessageCount: number = 60;
  config: ModelConfig = defaultConfig();
  threads: ThreadViewModel[] = [];
  active: ThreadViewModel = new ThreadViewModel({ id: '', title: '新对话', updatedAt: 0, messages: [] });
  settings: SettingsViewModel = new SettingsViewModel();
  providerEditor: ProviderEditorViewModel = new ProviderEditorViewModel();
  skillEditor: SkillEditorViewModel = new SkillEditorViewModel();
  extensions: ExtensionSettings = defaultExtensions();
  providerProfiles: ProviderProfile[] = [];
  get providerPresets(): ProviderInfo[] { return builtinProviderInfos(); }
  private session?: SessionService;
  private phase: SessionPhase = 'idle';
  teams: TeamRun[] = [];
  setTeamEnabled(enabled: boolean): Promise<boolean> { return this.requireSession().setTeamEnabled(enabled); }
  get teamBusy(): boolean { return this.phase === 'team'; }
  get saving(): boolean { return this.phase === 'saving'; }
  prepareTeam(goal: string, members: TeamMember[], concurrency: number): Promise<boolean> { return this.requireSession().prepareTeam(goal, members, concurrency); }
  reviseTeam(id: string, revision: number, plan: TeamPlan): Promise<boolean> { return this.requireSession().reviseTeam(id, revision, plan); }
  executeTeam(id: string, revision: number): Promise<void> { return this.requireSession().executeTeam(id, revision); }
  retryTeamTask(id: string, revision: number, taskId: string): Promise<boolean> { return this.requireSession().retryTeamTask(id, revision, taskId); }
  pauseTeam(): void { this.requireSession().pauseTeam(); }
  stopTeam(): void { this.requireSession().stopTeam(); }
  private selectedConfig: ModelConfig = defaultConfig();
  private draftTimer: number = -1;
  private onOutput: () => void = () => {};

  async initialize(session: SessionService): Promise<void> {
    if (!this.session) { this.session = session; session.subscribe((event: SessionEvent) => this.project(event)); }
    if (this.session !== session) { throw new Error(t("当前界面已经绑定会话服务。")); }
    await session.initialize();
  }

  private project(event: SessionEvent): void {
    this.projectState(event.state);
    if (event.data) { this.projectData(event.data); }
    if (event.kind === 'draft' && event.threadId === this.active.id) {
      this.draft = event.content || ''; this.active.draft = this.draft;
    }
    if (event.kind === 'message' && event.message) {
      this.threads.find((thread) => thread.id === event.threadId)?.messages.find((message) => message.id === event.message?.id)?.update(event.message);
    }
    if (event.kind === 'reasoning') {
      const message = this.threads.find((thread) => thread.id === event.threadId)?.messages.find((item) => item.id === event.messageId);
      if (message) {
        const step = message.stepViews[event.step || 0];
        if (step) { step.reasoningContent = event.stepContent || ''; }
        message.reasoningContent = message.stepViews.map((item) => item.reasoningContent).filter((text) => text.length > 0).join('\n\n');
      }
    }
    if (event.kind === 'text') {
      const message = this.threads.find((thread) => thread.id === event.threadId)?.messages.find((item) => item.id === event.messageId);
      if (message) {
        message.content = event.content || '';
        const step = message.stepViews[event.step || 0];
        if (step) { step.content = event.stepContent || ''; }
      }
    }
    if (['text', 'reasoning', 'message', 'snapshot'].includes(event.kind)) { this.onOutput(); }
  }
  private projectState(state: SessionState): void {
    this.phase = state.phase;
    this.ready = state.ready; this.loading = state.phase === 'loading'; this.busy = state.phase !== 'idle';
    this.generating = state.phase === 'running' || state.phase === 'compacting';
    this.acceptingSteering = state.acceptingSteering; this.error = state.error; this.saveError = state.saveError;
    this.contextStatus = state.contextStatus; this.contextTokens = state.contextTokens;
  }
  private projectData(data: AppData): void {
    this.teams = data.threads.find((thread) => thread.id === data.activeThreadId)?.teams || [];
    this.productivity = data.productivity || defaultProductivity();
    this.config = data.config; this.extensions = data.extensions || defaultExtensions(); this.providerProfiles = data.providerProfiles || [];
    const existing = new Map<string, ThreadViewModel>();
    for (const thread of this.threads) { existing.set(thread.id, thread); }
    this.threads = data.threads.map((thread) => {
      const view = existing.get(thread.id);
      if (view) { view.update(thread); return view; }
      return new ThreadViewModel(thread);
    });
    const active = this.threads.find((thread) => thread.id === data.activeThreadId);
    if (active) {
      if (this.active.id !== active.id) { this.visibleMessageCount = 60; this.searchQuery = ''; this.searchMessageId = ''; }
      this.active = active; this.draft = active.draft;
      this.selectedConfig = this.requireSession().currentConfig;
    }
  }

  get currentConfig(): ModelConfig { return this.ready ? this.selectedConfig : copyModelConfig(this.config, false); }
  get configured(): boolean { return this.currentConfig.configured; }
  get modelChoices(): ModelChoice[] { return availableModels(this.providerProfiles); }
  get currentModelLabel(): string {
    const ref = this.active.modelRef;
    if (!ref) { return t('选择模型'); }
    const name = this.providerProfiles.find((item) => item.id === ref.providerId)?.name || t('已删除服务');
    return name + ' · ' + ref.modelId + (this.configured ? '' : t(' · 不可用'));
  }
  get visibleMessages(): MessageViewModel[] { return this.active.messages.slice(-this.visibleMessageCount); }
  get contextUsed(): number { return this.contextTokens + estimateTextTokens(this.draft + referenceContext(this.active.references)); }
  get contextWindow(): number { return contextSettings(this.currentConfig).window; }
  get contextLabel(): string { return t('上下文约 {0} / {1} tokens', [this.contextUsed, this.contextWindow]); }
  get canQueueInput(): boolean {
    return this.ready && !this.active.archived && this.saveError.length === 0 && (this.phase === 'idle' || this.phase === 'running');
  }
  filteredThreads(query: string, archived: boolean): ThreadViewModel[] { return matchingThreads(this.threads, query, archived) as ThreadViewModel[]; }

  saveProductivity(value: ProductivityData): Promise<boolean> { return this.requireSession().saveProductivity(value); }
  proposeMemory(messageId: string): Promise<string[]> { return this.requireSession().proposeMemory(messageId); }
  cancelMemoryDraft(): void { this.requireSession().cancelMemoryDraft(); }
  saveMemoryDraft(threadId: string, messageId: string, items: string[], global: boolean): Promise<number> { return this.requireSession().saveMemoryDraft(threadId, messageId, items, global); }
  exportSnapshot(): AppData { return this.requireSession().snapshot(); }
  attributeUsage(records: RequestUsage[]): RequestUsage[] { return this.requireSession().attributeUsage(records); }
  importSnapshot(data: AppData): Promise<boolean> { return this.requireSession().importSnapshot(data); }
  setThreadMcp(id: string, enabled: boolean): Promise<boolean> { return this.requireSession().setThreadMcp(id, enabled); }
  setAttachments(items: Attachment[]): Promise<boolean> { return this.requireSession().setAttachments(items); }
  referenceThread(id: string): Promise<boolean> { return this.requireSession().referenceThread(id); }
  removeThreadReference(id: string): Promise<boolean> { return this.requireSession().removeThreadReference(id); }
  forkThread(messageId: string = ''): Promise<boolean> { return this.requireSession().forkThread(messageId); }
  useTemplate(id: string): void {
    try {
      const item = this.productivity.templates.find((item) => item.id === id);
      if (item) { this.setDraft(expandTemplate(item, this.draft)); }
    } catch (error) { this.error = (error as Error).message; }
  }
  newThread(): Promise<boolean> { return this.requireSession().newThread(); }
  selectThread(id: string): Promise<boolean> { return this.requireSession().selectThread(id); }
  deleteThread(id: string): Promise<boolean> { return this.requireSession().deleteThread(id); }
  renameThread(id: string, value: string): Promise<boolean> { return this.requireSession().renameThread(id, value); }
  pinThread(id: string): Promise<boolean> { return this.requireSession().pinThread(id); }
  archiveThread(id: string): Promise<boolean> { return this.requireSession().archiveThread(id); }
  selectModel(providerId: string, modelId: string, asDefault: boolean = false): Promise<boolean> { return this.requireSession().selectModel(providerId, modelId, asDefault); }
  setReasoningEffort(value: string): Promise<boolean> { return this.requireSession().setReasoningEffort(value); }
  deleteProvider(id: string): Promise<boolean> { return this.requireSession().deleteProvider(id); }
  changeSkill(name: string, remove: boolean = false): Promise<boolean> { return this.requireSession().changeSkill(name, remove); }
  enqueueInput(mode: InputMode): Promise<void> { return this.requireSession().enqueueInput(mode); }
  removePendingInput(id: string, edit: boolean = false): Promise<void> { return this.requireSession().removePendingInput(id, edit); }
  compactHistory(): Promise<void> { return this.requireSession().compactHistory(); }
  retrySave(): Promise<void> { return this.requireSession().retrySave(); }
  resumeForm(messageId: string, callId: string): Promise<void> { return this.requireSession().resumeForm(messageId, callId); }

  setDraft(text: string): void {
    if (!this.ready) { return; }
    this.requireSession().setDraft(text, this.active.id);
    clearTimeout(this.draftTimer);
    this.draftTimer = setTimeout(() => { this.draftTimer = -1; this.requireSession().flushDraft(); }, 800);
  }
  async flushDraft(): Promise<void> {
    clearTimeout(this.draftTimer); this.draftTimer = -1;
    if (this.session) { await this.session.flushDraft(); }
  }
  async send(onUpdate: () => void): Promise<void> {
    this.onOutput = onUpdate;
    try { await this.requireSession().send(); } finally { this.onOutput = () => {}; }
  }
  async resumeQueue(onUpdate: () => void): Promise<void> {
    this.onOutput = onUpdate;
    try { await this.requireSession().resumeQueue(); } finally { this.onOutput = () => {}; }
  }
  interactUi(threadId: string, messageId: string, key: string, values: UiValues, actionId: string): Promise<UiValues> {
    return this.requireSession().interactUi(threadId, messageId, key, values, actionId);
  }
  async stop(): Promise<void> { if (this.session) { await this.session.stop(); } }
  retryPrompt(): void {
    if (!this.requireSession().canMutate) { return; }
    if (this.active.messages.length >= 2) { this.requireSession().restoreMessageDraft(this.active.messages[this.active.messages.length - 2].id); }
  }

  openSettings(): void { this.settings.reset(this.config, this.extensions.webEnabled); }
  async saveSettings(): Promise<boolean> {
    const saved = await this.requireSession().saveSettings(this.settings.userDocument, this.settings.autoCompact, this.settings.webEnabled);
    // A refused save (session busy) reports no session error; still tell the user it did not stick.
    this.settings.error = saved ? '' : this.error || t("设置未保存，请稍后重试。"); return saved;
  }
  // Returns false when the editor was not reset, so callers must not open it with a stale draft.
  beginProvider(presetId: string = '', profileId: string = ''): boolean {
    if (!this.requireSession().canMutate) { return false; }
    const profile = this.providerProfiles.find((item) => item.id === profileId);
    if (profileId.length > 0 && !profile) { throw new Error(t("模型服务不存在。")); }
    this.providerEditor.reset(profile, this.providerPresets.find((preset) => preset.id === presetId));
    return true;
  }
  async saveProvider(): Promise<boolean> {
    const saved = await this.requireSession().saveProvider(this.providerEditor.snapshot());
    this.providerEditor.error = saved ? '' : this.error;
    if (saved) { this.providerEditor.apiKey = ''; }
    return saved;
  }
  beginSkill(name: string = ''): void {
    if (!this.requireSession().canMutate) { return; }
    const skill = this.extensions.skills.find((item: SkillData) => item.name === name);
    if (name.length > 0 && !skill) { throw new Error(t("Skill 不存在。")); }
    this.skillEditor.reset(skill);
  }
  async saveSkill(): Promise<boolean> {
    if (this.skillEditor.referencePath.trim().length > 0 || this.skillEditor.referenceText.length > 0) {
      this.skillEditor.error = t('下方还有未添加的参考内容，请先点击“添加参考文件”或清空草稿。'); return false;
    }
    const saved = await this.requireSession().saveSkill(this.skillEditor.originalName, this.skillEditor.document, this.skillEditor.files);
    this.skillEditor.error = saved ? '' : this.error; return saved;
  }
  useSkill(name: string): boolean {
    if (!this.requireSession().canMutate || this.active.archived || !this.extensions.skills.some((skill) => skill.name === name && skill.enabled)) { return false; }
    this.setDraft('/skill:' + name + ' ' + this.draft.replace(/^\/skill:[^\s]+\s*/, '')); return true;
  }
  private requireSession(): SessionService {
    if (!this.session) { throw new Error(t("会话服务尚未就绪。")); }
    return this.session;
  }
}
