import { StorageCatalog } from '../model/StorageCatalog';
import { FirstUseStatus } from '../model/Onboarding';
import { ConversationShareData } from '../model/ConversationShare';
import { Diagnostics } from '../model/Diagnostics';
import { ProjectData } from '../model/Project';
import { SharedFolder } from '../model/SharedFolders';
import { AgentMode } from '../model/AgentMode';
import { ToolApprovalMode } from '../model/ToolApprovalMode';
import { McpSettingsCommand, McpSettingsResult } from '../services/McpSettings';
import { Cancellation } from '../services/Cancellation';
import { t } from '../model/I18n';
import { SearchDraft } from '../model/WebSearch';
import { UiValues } from '../model/InteractiveUi';
import { RequestUsage } from '../model/Usage';
import { ContextTokenItem, draftBreakdown } from '../model/ContextBreakdown';
import { referenceContext } from '../model/ThreadReferences';
import { FileAnnotationTarget, fileAnnotationContext } from '../model/FileAnnotation';
import { TeamRun } from '../model/Team';
import { Attachment, ProductivityData, defaultProductivity } from '../model/Productivity';
import { AppData, ModelConfig, ThreadData, defaultConfig, copyModelConfig } from '../model/Conversation';
import { contextSettings } from '../model/ContextSettings';
import { ImageGenerationConfig, ModelChoice, ProviderProfile, availableModels } from '../model/ProviderProfiles';
import { ProviderInfo, builtinProviderInfos } from '../model/Provider';
import { ExtensionSettings, SkillData, defaultExtensions } from '../model/Skills';
import { SkillQuery, skillDraft } from '../model/SkillCompletion';
import { InputMode } from '../model/PendingInput';
import { matchingThreads } from '../model/SessionManagement';
import { SessionEvent, SessionPhase, SessionState, SettingsToggle } from '../services/SessionContracts';
import { SessionService } from '../services/SessionService';
import { ProviderEditorViewModel } from './ProviderEditorViewModel';
import { SkillEditorViewModel } from './SkillEditorViewModel';
import { MessageViewModel, ThreadViewModel } from './SessionViewModels';

export { AgentStepViewModel, MessageViewModel, ThreadViewModel, ToolExecutionViewModel } from './SessionViewModels';

interface ThreadSearchCache {
  query: string;
  archived: boolean;
  results?: ThreadViewModel[];
}

@Observed
export class SettingsViewModel {
  userDocument: string = '';
  autoCompact: boolean = true;
  newChatOnStartup: boolean = false;
  webEnabled: boolean = true;
  error: string = '';
  reset(config: ModelConfig, webEnabled: boolean): void {
    this.userDocument = config.userDocument || ''; this.autoCompact = contextSettings(config).autoCompact;
    this.newChatOnStartup = config.newChatOnStartup === true;
    this.webEnabled = webEnabled; this.error = '';
  }
}

// ArkUI projection and editor drafts only. Durable data and execution belong to SessionService.
@Observed
export class ChatViewModel {
  projects: ProjectData[] = [];
  get activeProject(): ProjectData | undefined { return this.projects.find((item) => item.id === this.active.projectId); }
  get activeWorkspaceId(): string { return this.requireSession().workspaceId; }
  saveProject(name: string, instructions: string, id?: string, folders?: SharedFolder[]): Promise<boolean> {
    return this.requireSession().saveProject(name, instructions, id, folders);
  }
  openProject(projectId: string): Promise<boolean> {
    let thread: ThreadViewModel | undefined = undefined;
    for (const item of this.threads) {
      if (item.projectId === projectId && !item.archived && (!thread || item.updatedAt > thread.updatedAt)) { thread = item; }
    }
    return thread ? this.selectThread(thread.id) : this.newThread(projectId);
  }
  productivity: ProductivityData = defaultProductivity();
  ready: boolean = false;
  searchQuery: string = '';
  searchMessageId: string = '';
  messageSearchRequest: number = 0;
  async openMessage(threadId: string, messageId: string, query: string = ''): Promise<boolean> {
    if (!await this.selectThread(threadId)) { return false; }
    this.visibleMessageCount = this.active.messages.length;
    this.searchQuery = query;
    this.searchMessageId = messageId;
    this.messageSearchRequest++;
    return true;
  }
  loading: boolean = false;
  busy: boolean = false;
  canNavigate: boolean = false;
  runningThreadIds: string[] = [];
  get sharedBusy(): boolean { return this.busy || this.runningThreadIds.length > 0; }
  generating: boolean = false;
  acceptingSteering: boolean = false;
  error: string = '';
  saveError: string = '';
  compatibilityWarnings: string[] = [];
  draft: string = '';
  contextTokens: number = 0;
  contextItems: ContextTokenItem[] = [];
  contextSource: string = 'estimate';
  contextStatus: string = '';
  visibleMessageCount: number = 60;
  config: ModelConfig = defaultConfig();
  threads: ThreadViewModel[] = [];
  private readonly threadSearch: ThreadSearchCache = { query: '', archived: false };
  private readonly threadLists: Map<boolean, ThreadViewModel[]> = new Map();
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
  setAgentMode(mode: AgentMode): Promise<boolean> { return this.requireSession().setAgentMode(mode); }
  setToolEnabled(name: string, enabled: boolean): Promise<boolean> { return this.requireSession().setToolEnabled(name, enabled); }
  setDisabledTools(names: string[]): Promise<boolean> { return this.requireSession().setDisabledTools(names); }
  get saving(): boolean { return this.phase === 'saving'; }
  private selectedConfig: ModelConfig = defaultConfig();
  private draftTimer: number = -1;
  private outputs: Map<string, () => void> = new Map<string, () => void>();

  async initialize(session: SessionService, continueChat: boolean = false): Promise<void> {
    if (!this.session) { this.session = session; session.subscribe((event: SessionEvent) => this.project(event)); }
    if (this.session !== session) { throw new Error(t("当前界面已经绑定会话服务。")); }
    await session.initialize(continueChat);
  }

  private project(event: SessionEvent): void {
    const diagnosticMark = Diagnostics.begin();
    try {
      if (event.data || event.kind === 'thread') { this.threadLists.clear(); }
      if (event.data || event.kind === 'thread' || event.kind === 'message' || event.stream?.some((update) => update.content !== undefined)) {
        this.threadSearch.results = undefined;
      }
      this.projectState(event.state);
      if (event.data) { this.projectData(event.data); }
      if (event.kind === 'selection' && event.threadId) { this.projectSelection(event.threadId, event.teams || []); }
      if (event.preferences) {
        this.config = event.preferences.config; this.extensions = event.preferences.extensions;
        this.productivity = event.preferences.productivity; this.selectedConfig = this.requireSession().currentConfig;
      }
      if (event.reasoningSelection) {
        const selection = event.reasoningSelection;
        const ids = new Set(selection.threadIds);
        for (const thread of this.threads) {
          if (ids.has(thread.id)) { thread.reasoningEffort = selection.value; }
        }
        if (selection.config) { this.config = selection.config; }
        this.selectedConfig = this.requireSession().currentConfig;
      }
      if (event.kind === 'teams' && event.threadId === this.active.id) { this.teams = event.teams || []; }
      if (event.kind === 'thread' && event.thread) {
        this.threads.find((thread) => thread.id === event.threadId)?.updateMetadata(event.thread);
        if (event.threadId === this.active.id) { this.draft = event.thread.draft || ''; }
      }
      if (event.kind === 'draft') {
        const draft = event.content || '';
        const thread = this.threads.find((item) => item.id === event.threadId);
        if (thread) { thread.draft = draft; }
        if (event.threadId === this.active.id) { this.draft = draft; this.active.draft = draft; }
      }
      let activeStreamChanged = false;
      for (const update of event.stream || []) {
        const isActive = update.threadId === this.active.id;
        const thread = isActive ? this.active : this.threads.find((item) => item.id === update.threadId);
        if (!thread) { continue; }
        const tail = thread.messages[thread.messages.length - 1];
        const message = tail?.id === update.messageId ? tail : thread.messages.find((item) => item.id === update.messageId);
        if (!message) { continue; }
        message.updateStream(update.step, update.content, update.stepContent, update.reasoningContent);
        if (isActive) { activeStreamChanged = true; }
      }
      if (event.kind === 'message' && event.message) {
        const thread = this.threads.find((thread) => thread.id === event.threadId);
        thread?.messages.find((message) => message.id === event.message?.id)?.update(event.message);
        thread?.refreshPreviews();
      }
      if (event.kind === 'tool' && event.tool) {
        const thread = this.threads.find((item) => item.id === event.threadId);
        thread?.messages.find((item) => item.id === event.messageId)?.updateTool(event.step || 0, event.tool, event.parentToolCallId);
        if (event.tool.status === 'complete' && (event.tool.call.function.name === 'publish_preview' ||
          (event.tool.children || []).some((child) => child.call.function.name === 'publish_preview'))) { thread?.refreshPreviews(); }
      }
      const activeOutputChanged = (!event.threadId || event.threadId === this.active.id) &&
        ['message', 'tool', 'snapshot', 'selection', 'thread', 'teams'].includes(event.kind);
      if (activeStreamChanged || activeOutputChanged) { this.outputs.get(this.active.id)?.(); }
    } finally { if (Diagnostics.recording) { Diagnostics.end('viewmodel.project', diagnosticMark); } }
  }
  private projectState(state: SessionState): void {
    this.canNavigate = state.canNavigate === true;
    const running = state.runningThreadIds || [];
    if (running.join(',') !== this.runningThreadIds.join(',')) { this.runningThreadIds = running; }
    this.phase = state.phase;
    this.ready = state.ready; this.loading = state.phase === 'loading'; this.busy = state.phase !== 'idle';
    this.generating = state.phase === 'running' || state.phase === 'compacting';
    this.acceptingSteering = state.acceptingSteering; this.error = state.error; this.saveError = state.saveError;
    const warnings = state.compatibilityWarnings || [];
    if (JSON.stringify(warnings) !== JSON.stringify(this.compatibilityWarnings)) { this.compatibilityWarnings = warnings; }
    this.contextStatus = state.contextStatus; this.contextTokens = state.contextTokens;
    // Retain the observed context array across updates with the same contents.
    const items = state.contextBreakdown || [];
    if (items.length !== this.contextItems.length || items.some((item, index) => {
      const previous = this.contextItems[index];
      return item.id !== previous.id || item.kind !== previous.kind || item.tokens !== previous.tokens ||
        item.messageId !== previous.messageId || item.step !== previous.step || item.name !== previous.name;
    })) { this.contextItems = items; }
    this.contextSource = state.contextSource || 'estimate';
  }
  private projectData(data: AppData): void {
    this.projects = data.projects || [];
    this.productivity = data.productivity || defaultProductivity();
    this.config = data.config; this.extensions = data.extensions || defaultExtensions(); this.providerProfiles = data.providerProfiles || [];
    const existing = new Map<string, ThreadViewModel>();
    for (const thread of this.threads) { existing.set(thread.id, thread); }
    this.threads = data.threads.map((thread) => {
      const view = existing.get(thread.id);
      if (view) { view.update(thread); return view; }
      return new ThreadViewModel(thread);
    });
    this.projectSelection(data.activeThreadId, data.threads.find((thread) => thread.id === data.activeThreadId)?.teams || []);
  }
  private projectSelection(id: string, teams: TeamRun[]): void {
    this.teams = teams;
    const active = this.threads.find((thread) => thread.id === id);
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
  get contextDraft(): ContextTokenItem[] { return draftBreakdown(this.draft,
    referenceContext(this.active.references) + (this.active.panelContext || '') + fileAnnotationContext(this.active.annotations), this.active.attachments); }
  get contextDetails(): ContextTokenItem[] { return this.contextItems.concat(this.contextDraft); }
  get contextUsed(): number { return this.contextTokens + this.contextDraft.reduce((sum, item) => sum + item.tokens, 0); }
  get contextWindow(): number { return contextSettings(this.currentConfig).window; }
  get contextLabel(): string { return t('上下文约 {0} / {1} tokens', [this.contextUsed, this.contextWindow]); }
  get canQueueInput(): boolean {
    return this.canNavigate && !this.active.archived && (this.phase === 'idle' || this.phase === 'running');
  }
  filteredThreads(query: string, archived: boolean): ThreadViewModel[] {
    const search = query.trim();
    const cache = this.threadSearch;
    const existing = search ? (cache.query === search && cache.archived === archived ? cache.results : undefined) :
      this.threadLists.get(archived);
    if (existing) { return existing; }
    const results = matchingThreads(this.threads.filter((thread) => !thread.sideChat), search, archived) as ThreadViewModel[];
    if (search) { cache.query = search; cache.archived = archived; cache.results = results; }
    else { this.threadLists.set(archived, results); }
    return results;
  }

  changeMcp(request: McpSettingsCommand, cancellation: Cancellation): Promise<McpSettingsResult> { return this.requireSession().changeMcp(request, cancellation); }
  saveProductivity(value: ProductivityData): Promise<boolean> { return this.requireSession().saveProductivity(value); }
  saveImageGeneration(value?: ImageGenerationConfig): Promise<boolean> { return this.requireSession().saveImageGeneration(value); }
  saveSearch(draft: SearchDraft): Promise<boolean> { return this.requireSession().saveSearch(draft); }
  refreshMemoryContext(): Promise<boolean> { return this.requireSession().refreshMemoryContext(); }
  proposeMemory(messageId: string): Promise<string[]> { return this.requireSession().proposeMemory(messageId); }
  cancelMemoryDraft(): void { this.requireSession().cancelMemoryDraft(); }
  saveMemoryDraft(threadId: string, messageId: string, items: string[], global: boolean): Promise<number> { return this.requireSession().saveMemoryDraft(threadId, messageId, items, global); }
  receiveFromDevice(apply: (snapshot: AppData) => Promise<AppData>): Promise<boolean> {
    return this.requireSession().receiveFromDevice(apply);
  }
  configurationSnapshot(): AppData { return this.requireSession().configurationSnapshot(); }
  firstUse(): FirstUseStatus { return this.requireSession().firstUse(); }
  storageCatalog(): StorageCatalog { return this.requireSession().storageCatalog(); }
  isAiAssistedFile(owner: string, path: string): boolean { return this.requireSession().isAiAssistedFile(owner, path); }
  shareConversation(): ConversationShareData { return this.requireSession().shareConversation(); }
  exportSnapshot(): AppData { return this.requireSession().snapshot(); }
  attributeUsage(records: RequestUsage[]): RequestUsage[] { return this.requireSession().attributeUsage(records); }
  importSnapshot(data: AppData): Promise<boolean> { return this.requireSession().importSnapshot(data); }
  importDeepSeek(threads: ThreadData[], prepare: (added: ThreadData[]) => Promise<() => Promise<void>>): Promise<number> {
    return this.requireSession().importDeepSeek(threads, prepare);
  }
  setThreadMcp(id: string, enabled: boolean): Promise<boolean> { return this.requireSession().setThreadMcp(id, enabled); }
  setAttachments(items: Attachment[]): Promise<boolean> { return this.requireSession().setAttachments(items); }
  appendDraftAttachment(threadId: string, item: Attachment): Promise<void> { return this.requireSession().appendDraftAttachment(threadId, item); }
  editBrowserAnnotation(threadId: string, id: string, note?: string): Promise<void> {
    return this.requireSession().editBrowserAnnotation(threadId, id, note);
  }
  editFileAnnotation(threadId: string, id: string, comment?: string): Promise<void> {
    return this.requireSession().editFileAnnotation(threadId, id, comment);
  }
  addFileAnnotation(threadId: string, path: string, version: string, target: FileAnnotationTarget, comment: string): Promise<void> {
    return this.requireSession().addFileAnnotation(threadId, path, version, target, comment);
  }
  referenceThread(id: string): Promise<boolean> { return this.requireSession().referenceThread(id); }
  sideChats(): ThreadViewModel[] { return this.threads.filter((thread) => thread.sideChat && thread.parentThreadId === this.active.id); }
  createSideChat(parentId: string): Promise<string> { return this.requireSession().createSideChat(parentId); }
  sendSideChat(id: string): Promise<void> { return this.requireSession().sendSideChat(id); }
  stopSideChat(id: string): Promise<void> { return this.requireSession().stop(undefined, id); }
  bringBackSideChat(id: string): Promise<boolean> { return this.requireSession().referenceThread(id, true); }
  sideChatError(id: string): string { return this.requireSession().sideChatError(id); }
  removeThreadReference(id: string): Promise<boolean> { return this.requireSession().removeThreadReference(id); }
  forkThread(messageId: string = ''): Promise<boolean> { return this.requireSession().forkThread(messageId); }
  newThread(projectId: string | undefined = this.active.projectId): Promise<boolean> { return this.requireSession().newThread(projectId || undefined); }
  switchThreadWorkspace(threadId: string, projectId?: string): Promise<boolean> {
    return this.requireSession().switchThreadWorkspace(threadId, projectId);
  }
  get canNavigateNow(): boolean { return this.session?.canNavigate ?? this.canNavigate; }
  selectThread(id: string): Promise<boolean> { return this.requireSession().selectThread(id); }
  deleteThread(id: string): Promise<boolean> { return this.requireSession().deleteThread(id); }
  deleteThreads(ids: string[]): Promise<boolean> { return this.requireSession().deleteThreads(ids); }
  renameThread(id: string, value: string): Promise<boolean> { return this.requireSession().renameThread(id, value); }
  pinThread(id: string): Promise<boolean> { return this.requireSession().pinThread(id); }
  archiveThread(id: string): Promise<boolean> { return this.requireSession().archiveThread(id); }
  archiveThreads(ids: string[], archived: boolean): Promise<boolean> { return this.requireSession().archiveThreads(ids, archived); }
  selectModel(providerId: string, modelId: string): Promise<boolean> { return this.requireSession().selectModel(providerId, modelId); }
  setReasoningEffort(value: string): Promise<boolean> { return this.requireSession().setReasoningEffort(value); }
  setToolApprovalMode(mode: ToolApprovalMode): Promise<boolean> { return this.requireSession().setToolApprovalMode(mode); }
  deleteProvider(id: string): Promise<boolean> { return this.requireSession().deleteProvider(id); }
  changeSkill(name: string, remove: boolean = false): Promise<boolean> { return this.requireSession().changeSkill(name, remove); }
  enqueueInput(mode: InputMode): Promise<void> { return this.requireSession().enqueueInput(mode); }
  removePendingInput(id: string, edit: boolean = false): Promise<void> { return this.requireSession().removePendingInput(id, edit); }
  compactHistory(): Promise<void> { return this.requireSession().compactHistory(); }
  retrySave(): Promise<void> { return this.requireSession().retrySave(); }
  resumeForm(messageId: string, callId: string): Promise<void> { return this.requireSession().resumeForm(messageId, callId); }

  setDraft(text: string, threadId: string = this.active.id): void {
    if (!this.ready) { return; }
    this.requireSession().setDraft(text, threadId);
    clearTimeout(this.draftTimer);
    this.draftTimer = setTimeout(() => { this.draftTimer = -1; this.requireSession().flushDraft(); }, 800);
  }
  setPanelContext(context: string): void { this.requireSession().setPanelContext(context); }
  async flushDraft(): Promise<void> {
    clearTimeout(this.draftTimer); this.draftTimer = -1;
    if (this.session) { await this.session.flushDraft(); }
  }
  async send(onUpdate: () => void): Promise<void> {
    const threadId = this.active.id; this.outputs.set(threadId, onUpdate);
    try { await this.requireSession().send(); } finally { if (this.outputs.get(threadId) === onUpdate) { this.outputs.delete(threadId); } }
  }
  async regenerateReply(id: string, onUpdate: () => void): Promise<boolean> {
    let threadId = '';
    try {
      return await this.requireSession().regenerateReply(id, (id) => { threadId = id; this.outputs.set(id, onUpdate); });
    } finally { if (this.outputs.get(threadId) === onUpdate) { this.outputs.delete(threadId); } }
  }
  async resumeQueue(onUpdate: () => void): Promise<void> {
    const threadId = this.active.id; this.outputs.set(threadId, onUpdate);
    try { await this.requireSession().resumeQueue(); } finally { if (this.outputs.get(threadId) === onUpdate) { this.outputs.delete(threadId); } }
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
  private pendingSettingsToggle?: Promise<boolean>;
  async setSettingsToggle(kind: SettingsToggle, value: boolean): Promise<boolean> {
    // The settings categories stay mounted and share one save order.
    const save = async (): Promise<boolean> => {
      const saved = await this.requireSession().setSettingsToggle(kind, value);
      this.settings.error = saved ? '' : this.error || t("设置未保存，请稍后重试。");
      return saved;
    };
    const pending = this.pendingSettingsToggle ? this.pendingSettingsToggle.then(save, save) : save();
    this.pendingSettingsToggle = pending;
    try { return await pending; }
    finally { if (this.pendingSettingsToggle === pending) { this.pendingSettingsToggle = undefined; } }
  }
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
    if (saved) { this.providerEditor.apiKey = ''; this.providerEditor.balanceApiKey = ''; }
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
  useSkill(name: string, query?: SkillQuery): boolean {
    if (!this.requireSession().canMutate || this.active.archived || !this.extensions.skills.some((skill) => skill.name === name && skill.enabled)) { return false; }
    this.setDraft(skillDraft(this.draft, name, query).text); return true;
  }
  private requireSession(): SessionService {
    if (!this.session) { throw new Error(t("会话服务尚未就绪。")); }
    return this.session;
  }
}
