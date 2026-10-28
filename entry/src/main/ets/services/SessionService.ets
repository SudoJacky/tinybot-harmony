import { resolveBrowserPreview } from '../model/BrowserPreview';
import { Diagnostics } from '../model/Diagnostics';
import { configurationIssues } from '../model/ConfigurationCompatibility';
import { isSupportedProtocol } from '../model/ProviderEndpoint';
import { ToolExecution } from '../model/Agent';
import { projectFor, workspaceIdFor, validateProjects, projectContext } from '../model/Project';
import { SharedFolder } from '../model/SharedFolders';
import { proposeSessionMemory, reviewSessionMemory, addMemoryDraft } from './SessionMemory';
import { McpSettings, McpSettingsCommand, McpSettingsResult, McpSettingsHost } from './McpSettings';
import { t } from '../model/I18n';
import { AgentMode, toolEnabled, ToolSelection, validateAgentMode, validateToolSelection, normalizeDisabledTools } from '../model/AgentMode';
import { RuleTools } from './RuleTools';
import { SelectedTools } from './SelectedTools';
import { OPTIONAL_TOOL_NAMES, TOOL_CAPABILITIES } from '../model/ToolGroups';
import { stepDisplayContent } from '../model/PublishedPreview';
import { UiValues, UiSavedState, parseUiSurface, validateUiState, validateUiStates, copyUiValues } from '../model/InteractiveUi';
import { importedSessionCandidate, savedProjectCandidate, forkedThreadCandidate } from './SessionCandidates';
import { RequestUsage } from '../model/Usage';
import { attributeLegacyUsage } from '../model/UsageAttribution';
import { reasoningEfforts, supportsReasoningEffort } from '../model/ReasoningEffort';
import { ThreadReference, captureThreadReference, isCompactCommand, removeReferenceQuery, validateThreadReferences } from '../model/ThreadReferences';
import { ReferenceTools } from './ReferenceTools';
import { saveSearchSettings } from './SearchSettings';
import { SearchDraft } from '../model/WebSearch';
import { TeamRun, teamCommand } from '../model/Team';
import { ChatTeamTools, CHAT_TEAM_INSTRUCTIONS, coordinatorDefinitions } from './ChatTeamTools';
import { Attachment, MemoryEntry, McpServer, ProductivityData, defaultProductivity, validateAttachments, validateProductivity, memoryContext, supportedMcpAuth } from '../model/Productivity';
import { defaultAssistantOptions, routeModel } from '../model/AssistantOptions';
import { validateMemorySuggestions } from '../model/MemorySuggestions';
import { MEMORY_CHAR_LIMIT, MEMORY_REVIEW_INTERVAL, MemoryOperation, MemoryChange,
  applyMemoryOperations, memoryCharacters, memoryReviewTurns } from '../model/MemoryMaintenance';
import { MemoryTools } from './MemoryTools';
import { ResourceTools } from './ResourceTools';
import { LiveResources, SkillRequest, McpRequest, McpSummary, saveSkillCandidate, changeSkillCandidate } from '../model/ResourceManagement';
import { Cancellation } from './Cancellation';
import { ToolSet } from './ToolSet';
import { AppData, MessageData, ModelConfig, ThreadData, copyModelConfig, copyAppMetadata, emptyData } from '../model/Conversation';
import { contextSettings } from '../model/ContextSettings';
import { ModelReference, ProviderProfile, migrateProfiles, modelConfig } from '../model/ProviderProfiles';
import { defaultSearchConfig, isSupportedSearchProvider } from '../model/WebSearch';
import { InputMode, MAX_INPUT_TEXT, PendingInput, nextPendingInput, validatePendingInputs } from '../model/PendingInput';
import { BrowserPolicy, ExtensionSettings, SkillData, SkillFile, defaultExtensions, explicitSkill, expandSkillCommand, parseSkill, validateExtensions } from '../model/Skills';
import { seedBuiltinSkills } from '../model/BuiltinSkills';
import { threadTitle } from '../model/SessionManagement';
import { CONVERSATION_TITLE_PROMPT, sanitizeConversationTitle, shouldGenerateTitle, titleCharacters } from '../model/ConversationTitle';
import { AgentEvent, AgentRuntime } from './AgentRuntime';
import { AgentTools } from './AgentLoop';
import { CredentialVault, ProfileSettings, ProviderDraft } from './ProfileSettings';
import { SessionEvent, SessionPreferences, SessionRepository, SessionResources, SessionState, SettingsToggle } from './SessionContracts';
import { prepareSessionContext, sessionPromptSections, sessionContextSource } from './SessionContext';
import { PromptSection, renderPrompt } from '../model/ContextProjection';
interface UiComputeReceipt { status: string; result: UiValues; error: string; resultTruncated: boolean; }
interface FormReceipt { status: string; }

class ThreadExecution {
  state: SessionState = { ready: true, phase: 'idle', error: '', saveError: '',
    contextStatus: '', contextTokens: 0, acceptingSteering: false };
  runtime: AgentRuntime;
  teams?: ChatTeamTools;
  recovering?: Cancellation;
  constructor(runtime: AgentRuntime) { this.runtime = runtime; }
}

// Sole owner of application/session data and admission. No ArkUI or platform Kit imports.
export class SessionService {
  private pendingCommit?: Promise<void>;
  private memoryReviewRunning: boolean = false;
  private executions: Map<string, ThreadExecution> = new Map<string, ThreadExecution>();
  private sharedOperation: Promise<void> = Promise.resolve();
  private data: AppData = emptyData();
  private application: SessionState = { ready: false, phase: 'idle', error: '', saveError: '',
    contextStatus: '', contextTokens: 0, acceptingSteering: false };
  private repository: SessionRepository;
  private resources: SessionResources;
  private runtime: AgentRuntime;
  private credentials: CredentialVault;
  private mcpSettings: McpSettings;
  private profiles: ProfileSettings;
  private draftRevision: number = 0;
  private dirtyDrafts: Set<string> = new Set<string>();
  // Composer choices stay outside persisted data until a user message is submitted.
  private pendingTeamModes: Map<string, boolean> = new Map<string, boolean>();
  private pendingToolSelections: Map<string, ToolSelection> = new Map<string, ToolSelection>();
  private listeners: Set<(event: SessionEvent) => void> = new Set<(event: SessionEvent) => void>();
  private compatibilityIssues: Set<string> = new Set<string>();

  constructor(repository: SessionRepository, runtime: AgentRuntime, credentials: CredentialVault, resources: SessionResources) {
    this.repository = repository;
    this.runtime = runtime;
    this.credentials = credentials;
    this.mcpSettings = new McpSettings(credentials, () => resources.createId(), (message) => resources.reportError('mcp_failed', message));
    this.resources = resources;
    this.profiles = new ProfileSettings(credentials, () => resources.createId());
  }

  snapshot(): AppData { return JSON.parse(JSON.stringify(this.data)) as AppData; }
  get workspaceId(): string { return workspaceIdFor(this.data, this.active); }
  attributeUsage(records: RequestUsage[]): RequestUsage[] { return attributeLegacyUsage(records, this.data.threads); }
  async setTeamEnabled(enabled: boolean): Promise<boolean> {
    if (!this.canMutate || this.active.archived) { return false; }
    const thread = this.active; const startedAt = Date.now();
    this.pendingTeamModes.set(thread.id, enabled);
    this.refreshContext(); this.publishThread(thread);
    this.resources.reportResources?.('team_selected', { enabled: enabled, durationMs: Date.now() - startedAt });
    return true;
  }
  private selectedTeamMode(thread: ThreadData): boolean {
    return this.pendingTeamModes.get(thread.id) ?? thread.teamEnabled === true;
  }
  async setAgentMode(mode: AgentMode): Promise<boolean> {
    if (!this.canMutate || this.active.archived) { return false; }
    validateAgentMode(mode);
    const selection = this.selectedToolSelection(this.active); selection.agentMode = mode;
    this.selectTools(selection);
    return true;
  }
  async setDisabledTools(names: string[]): Promise<boolean> {
    if (!this.canMutate || this.active.archived) { return false; }
    this.selectTools({ agentMode: 'custom', disabledTools: names.slice() }); return true;
  }
  async setToolEnabled(name: string, enabled: boolean): Promise<boolean> {
    if (!OPTIONAL_TOOL_NAMES.includes(name)) { throw new Error(t('自定义工具设置无效。')); }
    const members = TOOL_CAPABILITIES.find((capability) => capability.tools.includes(name))?.tools || [name];
    const disabled = (this.selectedToolSelection(this.active).disabledTools || []).filter((item) => !members.includes(item));
    if (!enabled) { disabled.push(...members); }
    return this.setDisabledTools(disabled);
  }
  private selectTools(selection: ToolSelection): void {
    validateToolSelection(selection, true);
    if (selection.disabledTools !== undefined) { selection.disabledTools = normalizeDisabledTools(selection.disabledTools); }
    this.pendingToolSelections.set(this.active.id, selection);
    this.refreshCompatibility();
    this.refreshContext(); this.publishThread(this.active);
  }
  private selectedToolSelection(thread: ThreadData): ToolSelection {
    const selection = this.pendingToolSelections.get(thread.id) || thread;
    return { agentMode: selection.agentMode || 'full', disabledTools: selection.disabledTools?.slice() };
  }
  private readOnly(_thread: ThreadData): boolean { return this.data.productivity?.options?.readOnly === true; }
  private addModeInstructions(sections: PromptSection[], thread: ThreadData): void {
    const selection = this.selectedToolSelection(thread);
    if (selection.agentMode === 'custom') {
      sections.push({ name: 'agent-mode', content: 'The user selected a custom toolset. Disabled tools: ' +
        JSON.stringify(selection.disabledTools || []) + '. These restrictions apply to direct calls, tool orchestration and team workers. ' +
        'Do not bypass disabled tools. Basic file reading, search and editing remain available subject to the existing permissions.' });
    }
  }

  private execution(id: string = this.data.activeThreadId): ThreadExecution {
    let execution = this.executions.get(id);
    if (!execution) { execution = new ThreadExecution(this.runtime.fork()); this.executions.set(id, execution); }
    return execution;
  }
  private get status(): SessionState { return this.application.ready ? this.execution().state : this.application; }
  get runningThreadIds(): string[] {
    return Array.from(this.executions.keys()).filter((id) => this.executions.get(id)!.state.phase !== 'idle');
  }
  get hasActiveRuns(): boolean { return this.runningThreadIds.length > 0; }
  get canNavigate(): boolean { return this.application.ready && this.application.phase === 'idle' && !this.application.saveError; }
  get state(): SessionState {
    const state = JSON.parse(JSON.stringify(this.status)) as SessionState;
    state.ready = this.application.ready; state.saveError = this.application.saveError;
    if (this.application.phase !== 'idle') { state.phase = this.application.phase; }
    state.runningThreadIds = this.runningThreadIds; state.canNavigate = this.canNavigate;
    return state;
  }
  get canMutate(): boolean { return this.canNavigate && this.status.phase === 'idle'; }
  private get canMutateShared(): boolean { return this.canNavigate && !this.hasActiveRuns; }
  get canQueueInput(): boolean {
    return this.canNavigate && !this.active.archived &&
      (this.status.phase === 'idle' || this.status.phase === 'running');
  }
  get currentConfig(): ModelConfig {
    return this.threadConfig(this.active);
  }
  private threadConfig(thread: ThreadData): ModelConfig {
    const reference = thread.modelRef;
    if (!reference) { return copyModelConfig(this.data.config, false); }
    const profile = this.providerProfiles.find((item: ProviderProfile) => item.id === reference.providerId);
    if (!profile || !profile.enabled || !isSupportedProtocol(profile.protocol) || !profile.models.includes(reference.modelId)) {
      const unavailable = copyModelConfig(this.data.config, false);
      unavailable.contextWindow = profile?.contextWindow || this.data.config.contextWindow;
      return unavailable;
    }
    return this.configFor(reference, thread);
  }
  private configFor(reference: ModelReference, thread: ThreadData = this.active): ModelConfig {
    const config = modelConfig(this.providerProfiles, reference, this.data.config);
    const capability = this.data.productivity?.options?.capabilities.find((item) => item.providerId === reference.providerId && item.modelId === reference.modelId);
    if (capability) {
      config.images = capability.images; config.reasoning = capability.reasoning; config.requestUsage = capability.requestUsage;
      if (capability.contextWindow !== undefined) { config.contextWindow = capability.contextWindow; }
    }
    const protocol = this.providerProfiles.find((item) => item.id === reference.providerId)?.protocol || '';
    // An automatically routed model (or a worker using another model) retains its own defaults.
    if (supportsReasoningEffort(protocol, reference.modelId) && thread?.modelRef?.providerId === reference.providerId &&
      thread.modelRef.modelId === reference.modelId && thread.reasoningEffort && thread.reasoningEffort !== 'default') {
      config.reasoning = thread.reasoningEffort;
    }
    if (!reasoningEfforts(protocol, reference.modelId).includes(config.reasoning || 'default')) config.reasoning = 'default';
    return config;
  }
  async setThreadMcp(id: string, enabled: boolean): Promise<boolean> {
    return this.mutate(t("保存会话工具设置失败："), async () => {
      const ids = (this.active.disabledMcpIds || []).filter((item) => item !== id);
      this.active.disabledMcpIds = enabled ? ids : ids.concat([id]); await this.persist();
    }, 'snapshot', 'thread');
  }
  async importSnapshot(imported: AppData): Promise<boolean> {
    return this.mutate(t("导入失败："), async () => {
      const importedCandidate = importedSessionCandidate(this.data, imported, () => this.resources.createId());
      for (const thread of importedCandidate.threads) { await this.ensureThreadWorkspace(thread, importedCandidate.data); }
      await this.commitSettings(importedCandidate.data);
    });
  }
  private get active(): ThreadData { return this.requireThread(this.data.activeThreadId); }
  private get providerProfiles(): ProviderProfile[] { return this.data.providerProfiles || []; }
  private get extensions(): ExtensionSettings { return this.data.extensions || defaultExtensions(); }

  subscribe(listener: (event: SessionEvent) => void): () => void {
    this.listeners.add(listener);
    return () => { this.listeners.delete(listener); };
  }

  async initialize(): Promise<void> {
    if (this.application.ready || this.application.phase !== 'idle') { return; }
    this.application.phase = 'loading'; this.application.error = ''; this.publish('state');
    try {
      const data = await this.repository.load();
      validateProjects(data);
      const migrate = data.providerProfiles === undefined;
      data.providerProfiles = data.providerProfiles || migrateProfiles(data.config);
      data.extensions = data.extensions || defaultExtensions();
      const builtinsChanged = seedBuiltinSkills(data.extensions);
      data.productivity = data.productivity || defaultProductivity();
      // Older builds stored neither key; materialize today's defaults so upgrades match a fresh install.
      let defaultsApplied = false;
      if (data.extensions.browserPolicy === undefined) { data.extensions.browserPolicy = 'enabled'; defaultsApplied = true; }
      if (!data.productivity.options) { data.productivity.options = defaultAssistantOptions(); defaultsApplied = true; }
      else if (!data.productivity.options.search) { data.productivity.options.search = defaultSearchConfig(); defaultsApplied = true; }
      for (const project of data.projects || []) { await this.resources.ensureWorkspace(project.id, project.workspaceId); }
      if (this.resources.activateProjectFolders) { await this.resources.activateProjectFolders(data.projects || []); }
      for (const thread of data.threads) {
        await this.ensureThreadWorkspace(thread, data);
        if ((thread.pendingInputs || []).length > 0) { thread.queuePaused = true; }
        if (migrate && data.config.configured) { thread.modelRef = { providerId: data.config.providerId, modelId: data.config.model }; }
      }
      this.data = data;
      this.refreshCompatibility();
      this.resources.configureProviders(this.providerProfiles);
      let active = data.threads.find((thread) => thread.id === data.activeThreadId && !thread.archived) ||
        data.threads.find((thread) => !thread.archived);
      const created = !active;
      if (!active) { active = this.freshThread(); await this.resources.ensureWorkspace(active.id); data.threads.unshift(active); }
      data.activeThreadId = active.id;
      const preferencesChanged = this.syncEmptyThreadPreferences(data);
      if (created || migrate || builtinsChanged || defaultsApplied || preferencesChanged.length > 0) { await this.persist(); }
      this.refreshContext();
      this.application.saveError = '';
      this.application.ready = true;
    } catch (error) { this.application.error = t("打开本地会话或工作区失败：") + (error as Error).message;
      Diagnostics.log('error', 'configuration', 'load_failed', undefined, error as Error); }
    finally { this.application.phase = 'idle'; this.publish('snapshot'); }
  }

  async saveSearch(draft: SearchDraft): Promise<boolean> {
    return this.mutate('', async () => {
      this.status.error = await saveSearchSettings(this.snapshot(), draft, this.credentials, () => this.resources.createId(), (candidate) => this.commitSettings(candidate));
    });
  }
  async saveProductivity(value: ProductivityData): Promise<boolean> {
    return this.mutate(t("保存资料失败："), async () => {
      validateProductivity(value);
      if (memoryCharacters(value.memories) > MEMORY_CHAR_LIMIT && memoryCharacters(value.memories) > memoryCharacters(this.data.productivity?.memories || [])) {
        throw new Error(t('记忆容量不足：{0}/100 条，{1}/{2} 字符。请先整理已有记忆；本次未保存任何变更。',
          [value.memories.length, memoryCharacters(value.memories), MEMORY_CHAR_LIMIT]));
      }
      const candidate = this.snapshot(); candidate.productivity = JSON.parse(JSON.stringify(value)) as ProductivityData;
      if (JSON.stringify(value.memories) !== JSON.stringify(this.data.productivity?.memories || [])) {
        for (const thread of candidate.threads) { thread.memorySnapshot = undefined; }
      }
      await this.commitSettings(candidate);
    });
  }
  async refreshMemoryContext(): Promise<boolean> {
    return this.mutate(t('刷新记忆失败：'), async () => {
      const candidate = this.snapshot();
      const thread = candidate.threads.find((item) => item.id === candidate.activeThreadId);
      if (!thread) { throw new Error(t('对话不存在：') + candidate.activeThreadId); }
      thread.memorySnapshot = memoryContext(candidate.productivity || defaultProductivity(), thread.id);
      await this.commitSettings(candidate);
    });
  }
  async setAttachments(items: Attachment[]): Promise<boolean> {
    const thread = this.active; const status = this.status;
    if (status.phase === 'running') {
      if (!this.canQueueInput) { return false; }
      try {
        const prepared = await this.prepareAttachments(items, thread);
        if (this.active !== thread || !this.canQueueInput) { throw new Error(t('对话已切换，请在当前对话重新添加附件。')); }
        this.active.attachments = prepared; this.publish('snapshot');
        await this.persist(this.active.id); return true;
      } catch (error) {
        status.error = t('保存附件失败：') + (error as Error).message;
        this.resources.reportError('mutation_failed', error as Error); this.publish('snapshot'); return false;
      }
    }
    return this.mutate(t("保存附件失败："), async () => {
      if (thread.archived) { throw new Error(t("请先恢复对话。")); }
      thread.attachments = await this.prepareAttachments(items, thread); await this.persist(thread.id);
    }, 'snapshot', 'thread');
  }
  private async prepareAttachments(items: Attachment[], thread: ThreadData): Promise<Attachment[]> {
    validateAttachments(items);
    if (!items.some((item) => item.original)) { return items; }
    if (!this.resources.prepareAttachments) { throw new Error('Workspace file attachment storage is unavailable.'); }
    return this.resources.prepareAttachments(items, thread.id, projectFor(this.data, thread)?.workspaceId);
  }
  async appendDraftAttachment(threadId: string, item: Attachment, text: string): Promise<void> {
    if (this.active.id !== threadId) { throw new Error(t('对话已切换，请在当前对话重新添加附件。')); }
    if (!this.canQueueInput) { throw new Error(this.application.saveError || t('当前无法添加附件，请稍后重试。')); }
    const attachments = (this.active.attachments || []).concat([item]);
    validateAttachments(attachments);
    const draft = [this.active.draft || '', text].filter((value) => value.length > 0).join('\n\n');
    if (draft.length > MAX_INPUT_TEXT) { throw new Error(t('批注与现有草稿合计不能超过 24000 字符。')); }
    this.active.attachments = attachments; this.setDraft(draft, threadId); this.publish('snapshot');
    // Like typing, staging is allowed while the runtime is paused and uses its ordered save lane.
    await this.persist(threadId); this.refreshContext(); this.publish('snapshot');
  }
  async referenceThread(id: string): Promise<boolean> {
    return this.mutate(t('添加会话引用失败：'), async () => {
      if (this.active.archived) { throw new Error(t('请先恢复对话。')); }
      if (id === this.active.id) { throw new Error(t('请选择其他会话。')); }
      const items = this.active.references || [];
      if (items.some((item) => item.threadId === id)) { throw new Error(t('已引用该会话。')); }
      const references = items.concat([captureThreadReference(this.requireThread(id))]);
      validateThreadReferences(references);
      this.active.references = references;
      this.setDraft(removeReferenceQuery(this.active.draft || ''), this.active.id);
      await this.persist();
    }, 'snapshot', 'thread');
  }
  async removeThreadReference(id: string): Promise<boolean> {
    return this.mutate(t('更新会话引用失败：'), async () => {
      if (this.active.archived) { throw new Error(t('请先恢复对话。')); }
      this.active.references = (this.active.references || []).filter((item) => item.threadId !== id);
      await this.persist();
    }, 'snapshot', 'thread');
  }
  async restoreMessageDraft(id: string): Promise<boolean> {
    return this.mutate(t('恢复草稿失败：'), async () => {
      if (this.active.archived) { throw new Error(t('请先恢复对话。')); }
      const message = this.active.messages.find((item) => item.id === id && item.role === 'user');
      if (!message) { throw new Error(t('消息已不存在。')); }
      this.active.attachments = JSON.parse(JSON.stringify(message.attachments || [])) as Attachment[];
      this.active.references = (message.references || []).map((item): ThreadReference => ({ threadId: item.threadId, title: item.title,
        content: item.content, capturedAt: item.capturedAt, truncated: item.truncated, fullContent: item.fullContent }));
      this.setDraft(message.content, this.active.id); await this.persist();
    }, 'snapshot', 'thread');
  }
  async forkThread(messageId: string = ''): Promise<boolean> {
    return this.mutate(t("创建分支失败："), async () => {
      const source = this.active;
      const branch = forkedThreadCandidate(source, () => this.freshThread(), this.selectedToolSelection(source), messageId);
      await this.ensureThreadWorkspace(branch);
      branch.attachments = await this.prepareAttachments(branch.attachments || [], branch);
      for (const message of branch.messages) {
        if (message.attachments) { message.attachments = await this.prepareAttachments(message.attachments, branch); }
        for (const step of message.steps || []) {
          if (step.steering?.attachments) { step.steering.attachments = await this.prepareAttachments(step.steering.attachments, branch); }
        }
      }
      // Preserve historical messages verbatim. Context describes shared project files or a fresh standalone workspace.
      const extras = this.data.productivity || defaultProductivity();
      const copied = extras.memories.filter((item) => item.threadId === source.id).map((item): MemoryEntry => {
        return { id: this.resources.createId(), content: item.content, threadId: branch.id, updatedAt: Date.now() };
      });
      const next: ProductivityData = { memories: extras.memories.concat(copied), templates: extras.templates,
        servers: extras.servers, options: extras.options };
      validateProductivity(next); this.data.productivity = next;
      this.data.threads.unshift(branch); this.data.activeThreadId = branch.id; await this.persist();
    }, 'snapshot', 'thread');
  }

  private ensureThreadWorkspace(thread: ThreadData, data: AppData = this.data): Promise<void> {
    return this.resources.ensureWorkspace(thread.id, projectFor(data, thread)?.workspaceId);
  }

  async saveProject(name: string, instructions: string, id?: string, folders?: SharedFolder[]): Promise<boolean> {
    return this.mutate(t('保存项目失败：'), async () => {
      const change = savedProjectCandidate(this.data, name, instructions,
        () => this.freshThread(), () => this.resources.createId(), id, folders);
      // Newly picked URIs still hold the picker's temporary grant; persist them before committing.
      if (change.addedFolders.length > 0) {
        if (!this.resources.persistProjectFolders) { throw new Error(t('当前平台无法保存共享文件夹权限。')); }
        await this.resources.persistProjectFolders(change.addedFolders);
      }
      if (!id) { await this.resources.ensureWorkspace(change.project.workspaceId); }
      await this.commitSettings(change.data);
      if (change.removedFolders.length > 0 && this.resources.revokeProjectFolders) {
        await this.resources.revokeProjectFolders(change.removedFolders);
      }
    });
  }

  async newThread(projectId?: string): Promise<boolean> {
    if (!this.canNavigate) { return false; }
    const current = this.active;
    // Repeated new-chat actions are idempotent while the current composer is untouched.
    // Keep its workspace and local model/team choices; never discard prepared input.
    if (current.projectId === projectId && !current.archived && !current.titleEdited && !current.pinned &&
      !current.parentThreadId && current.messages.length === 0 && (current.draft || '').length === 0 &&
      (current.attachments || []).length === 0 && (current.references || []).length === 0 &&
      (current.pendingInputs || []).length === 0) { return true; }
    return this.mutate(t("新建对话失败："), async () => {
      const thread = this.freshThread(); thread.projectId = projectId; await this.ensureThreadWorkspace(thread);
      this.data.threads.unshift(thread); this.data.activeThreadId = thread.id;
      await this.persist();
    }, 'snapshot', 'navigation');
  }

  // A regenerated answer is a new branch; existing answers and later turns stay intact.
  async regenerateReply(messageId: string, started?: (threadId: string) => void): Promise<boolean> {
    if (!this.canMutate) { return false; }
    const threadId = this.active.id;
    if ((this.resources.authorizeGeneration && !await this.authorizeGeneration()) || !this.canMutate || this.active.id !== threadId) { return false; }
    const index = this.active.messages.findIndex((item) => item.id === messageId && item.role === 'assistant');
    if (index < 1 || this.active.messages[index - 1].role !== 'user') { return false; }
    if (!await this.forkThread(this.active.messages[index - 1].id)) { return false; }
    started?.(this.active.id);
    await this.send(); return true;
  }
  async selectThread(id: string): Promise<boolean> {
    return this.mutate(t("打开对话失败："), async () => {
      const thread = this.requireThread(id); await this.ensureThreadWorkspace(thread);
      this.data.activeThreadId = id; await this.persist();
    }, 'snapshot', 'navigation');
  }
  async deleteThread(id: string): Promise<boolean> {
    return this.deleteThreads([id]);
  }
  async deleteThreads(ids: string[]): Promise<boolean> {
    if (ids.some((id) => this.runningThreadIds.includes(id))) { return false; }
    if (ids.length === 0) { return false; }
    return this.mutate(t("删除对话失败："), async () => {
      const running = this.runningThreadIds;
      for (const id of ids) { this.requireThread(id); }
      const selected = new Set(ids);
      const candidate = this.snapshot();
      const activeChanged = selected.has(candidate.activeThreadId);
      await this.replaceActive(selected, candidate);
      // Deleting a conversation deliberately retains its workspace.
      candidate.threads = candidate.threads.filter((thread) => !selected.has(thread.id));
      await this.commitSettings(candidate, running);
      for (const id of ids) { this.executions.delete(id); this.pendingTeamModes.delete(id); this.pendingToolSelections.delete(id); }
      if (activeChanged) { this.status.contextStatus = ''; }
    }, 'snapshot', 'navigation');
  }
  async renameThread(id: string, title: string): Promise<boolean> {
    return this.mutate(t("重命名失败："), async () => {
      const thread = this.requireThread(id); thread.title = threadTitle(title); thread.titleEdited = true; await this.persist();
    }, 'snapshot', 'navigation');
  }
  async pinThread(id: string): Promise<boolean> {
    return this.mutate(t("置顶状态保存失败："), async () => {
      const thread = this.requireThread(id); thread.pinned = !thread.pinned; await this.persist();
    }, 'snapshot', 'navigation');
  }
  async archiveThread(id: string): Promise<boolean> {
    const thread = this.data.threads.find((item) => item.id === id);
    return this.archiveThreads([id], !thread?.archived);
  }
  async archiveThreads(ids: string[], archived: boolean): Promise<boolean> {
    if (ids.some((id) => this.runningThreadIds.includes(id))) { return false; }
    if (ids.length === 0) { return false; }
    return this.mutate(t("归档状态保存失败："), async () => {
      const running = this.runningThreadIds;
      for (const id of ids) { this.requireThread(id); }
      const selected = new Set(ids);
      const candidate = this.snapshot();
      const activeChanged = archived && selected.has(candidate.activeThreadId);
      if (archived) { await this.replaceActive(selected, candidate); }
      for (const thread of candidate.threads) {
        if (selected.has(thread.id)) { thread.archived = archived; }
      }
      await this.commitSettings(candidate, running);
      if (activeChanged) { this.status.contextStatus = ''; }
    }, 'snapshot', 'navigation');
  }

  setDraft(text: string, threadId: string = this.data.activeThreadId): void {
    if (!this.application.ready || text.length > MAX_INPUT_TEXT) { return; }
    const thread = this.data.threads.find((item) => item.id === threadId);
    if (!thread || thread.archived) { return; }
    thread.draft = text;
    this.draftRevision++; this.dirtyDrafts.add(thread.id);
    this.emit({ kind: 'draft', state: this.state, threadId: thread.id, content: text });
  }
  async flushDraft(): Promise<void> {
    if (!this.application.ready || this.application.phase === 'saving' || this.application.saveError.length > 0) { return; }
    // Runtime checkpoints and draft writes use the repository's same ordered save lane.
    try { await this.persist(this.data.activeThreadId); } catch (_) { /* persist publishes the retained unsaved state. */ }
  }
  async retrySave(): Promise<void> {
    if (!this.application.ready || this.application.phase !== 'idle' || this.hasActiveRuns) { return; }
    this.application.phase = 'saving'; this.publish('state');
    try { await this.persistDraftChanges(-1); this.application.saveError = ''; }
    catch (_) { /* Keep the explicit retry error visible. */ }
    finally { this.application.phase = 'idle'; this.publish('snapshot'); }
  }

  async selectModel(providerId: string, modelId: string): Promise<boolean> {
    if (!this.application.ready || this.active.archived) { return false; }
    return this.mutate(t("选择模型失败："), async () => {
      const reference: ModelReference = { providerId: providerId, modelId: modelId };
      const config = modelConfig(this.providerProfiles, reference, this.data.config);
      await this.credentials.read(config.credentialAlias);
      const candidate = this.snapshot();
      const thread = candidate.threads.find((item) => item.id === candidate.activeThreadId);
      if (!thread) { throw new Error(t("当前对话不存在。")); }
      if (thread.modelRef?.providerId !== providerId || thread.modelRef?.modelId !== modelId) { thread.reasoningEffort = undefined; }
      thread.modelRef = reference;
      if (thread.messages.length === 0) {
        config.reasoning = thread.reasoningEffort;
        candidate.config = config;
      }
      await this.commitSettings(candidate); this.status.contextStatus = '';
    }, 'snapshot', 'thread');
  }
  async setReasoningEffort(value: string): Promise<boolean> {
    if (!this.application.ready || this.active.archived) return false;
    return this.mutate(t('保存推理强度失败：'), async () => {
      const protocol = this.providerProfiles.find((item) => item.id === this.active.modelRef?.providerId)?.protocol || '';
      if (!reasoningEfforts(protocol, this.active.modelRef?.modelId || '').includes(value) || !this.currentConfig.configured) {
        throw new Error(t('当前模型或协议不支持此推理强度设置。'));
      }
      // Commit a copy so a failed disk write leaves the previous selection intact.
      const candidate = this.snapshot();
      const thread = candidate.threads.find((item) => item.id === candidate.activeThreadId);
      if (!thread) throw new Error(t('当前对话不存在。'));
      thread.reasoningEffort = value === 'default' ? undefined : value;
      if (thread.messages.length === 0) { candidate.config.reasoning = thread.reasoningEffort; }
      await this.commitSettings(candidate);
    }, 'snapshot', 'thread');
  }

  async saveProvider(draft: ProviderDraft): Promise<boolean> {
    return this.mutate('', async () => {
      this.status.error = await this.profiles.save(this.snapshot(), draft, (candidate) => this.commitSettings(candidate));
      this.resources.configureProviders(this.providerProfiles);
    });
  }
  async deleteProvider(id: string): Promise<boolean> {
    return this.mutate(t("删除服务失败："), async () => {
      this.status.error = await this.profiles.remove(this.snapshot(), id, (candidate) => this.commitSettings(candidate));
      this.resources.configureProviders(this.providerProfiles);
    });
  }
  async saveSettings(userDocument: string, autoCompact: boolean, webEnabled: boolean): Promise<boolean> {
    return this.mutate(t("保存助手设置失败："), async () => {
      const preferences = this.preferencesSnapshot();
      preferences.config.userDocument = userDocument; preferences.config.autoCompact = autoCompact;
      preferences.extensions.webEnabled = webEnabled;
      await this.commitPreferences(preferences);
    }, 'preferences');
  }
  async setSettingsToggle(kind: SettingsToggle, value: boolean): Promise<boolean> {
    return this.mutate(t("保存助手设置失败："), async () => {
      if (typeof value !== 'boolean') { throw new Error('Invalid settings toggle value.'); }
      const preferences = this.preferencesSnapshot();
      const options = preferences.productivity.options || defaultAssistantOptions();
      if (kind === 'autoMemory') { options.autoMemory = value; }
      else if (kind === 'readOnly') { options.readOnly = value; }
      else if (kind === 'saveSummary') { options.saveSummary = value; }
      else if (kind === 'autoCompact') { preferences.config.autoCompact = value; }
      else if (kind === 'webEnabled') { preferences.extensions.webEnabled = value; }
      else { throw new Error('Invalid settings toggle.'); }
      preferences.productivity.options = options;
      await this.commitPreferences(preferences);
    }, 'preferences');
  }
  async setBrowserPolicy(policy: BrowserPolicy): Promise<void> {
    if (!this.application.ready || this.application.saveError) { throw new Error(this.application.saveError || 'Session is not ready.'); }
    if (!['unset', 'enabled', 'disabled'].includes(policy)) { throw new Error('Invalid browser permission setting.'); }
    // This field can change while the runtime is paused. Publish only this field, never an old transcript snapshot.
    await this.exclusive(async () => {
      const candidate = this.snapshot();
      candidate.extensions = candidate.extensions || defaultExtensions();
      candidate.extensions.browserPolicy = policy;
      await this.commitCandidate(candidate, () => {
        if (!this.data.extensions) { this.data.extensions = defaultExtensions(); }
        this.data.extensions.browserPolicy = policy;
      });
      await this.persist();
      this.publish('snapshot');
    });
  }
  async saveSkill(originalName: string, document: string, files: SkillFile[]): Promise<boolean> {
    return this.mutate(t("保存 Skill 失败："), async () => {
      const candidate = this.snapshot();
      candidate.extensions = saveSkillCandidate(this.extensions, originalName, document, files);
      await this.commitSettings(candidate);
    });
  }
  async changeSkill(name: string, remove: boolean = false): Promise<boolean> {
    return this.mutate(t("更新 Skill 失败："), async () => {
      const candidate = this.snapshot();
      const enabled = this.extensions.skills.find((item) => item.name === name)?.enabled;
      candidate.extensions = changeSkillCandidate(this.extensions, name, remove ? 'remove' : enabled ? 'disable' : 'enable');
      await this.commitSettings(candidate);
    });
  }

  async enqueueInput(mode: InputMode): Promise<void> {
    const thread = this.active; const status = this.status;
    if (!this.canQueueInput || (thread.draft || '').trim().length === 0) { return; }
    status.error = '';
    try {
      if ((thread.references || []).length > 0) { throw new Error(t('会话引用请在当前任务完成后发送，或先移除引用再排队。')); }
      if (/^\/compact(?:\s|$)/i.test((thread.draft || '').trim())) { throw new Error(t('/compact 请在当前任务完成后单独发送。')); }
      if (mode === 'steer' && (!status.acceptingSteering || !this.execution(thread.id).runtime.acceptsSteering)) {
        throw new Error(t("本轮正在结束或已停止，请将指令加入队列。"));
      }
      const text = (thread.draft || '').trim();
      if (mode === 'steer' && explicitSkill(text).length > 0) { throw new Error(t("运行中保持当前工具与 Skills；显式调用 /skill: 请使用“加入队列”。")); }
      const input: PendingInput = { id: this.resources.createId(), mode: mode, text: text };
      if ((thread.attachments || []).length) { input.attachments = thread.attachments; }
      const pending = (thread.pendingInputs || []).concat([input]);
      validatePendingInputs(pending); thread.pendingInputs = pending;
      if (status.phase !== 'running') { thread.queuePaused = true; }
      thread.draft = ''; thread.attachments = []; this.publish('snapshot'); await this.persist();
    } catch (error) {
      status.error = t("指令未能提交：") + (error as Error).message;
      if (this.application.saveError.length > 0) { thread.queuePaused = true; this.execution(thread.id).runtime.abort(); }
      this.publish('snapshot');
    }
  }
  async removePendingInput(id: string, edit: boolean = false): Promise<void> {
    const thread = this.active; const status = this.status;
    if (!this.canQueueInput) { return; }
    const input = (thread.pendingInputs || []).find((item: PendingInput) => item.id === id);
    if (!input) { status.error = t("这条指令已经开始执行，不能再撤回。"); this.publish('state'); return; }
    if (edit && ((thread.draft || '').trim().length > 0 || (thread.attachments || []).length > 0)) { status.error = t("请先发送或清空当前草稿，再撤回编辑。"); this.publish('state'); return; }
    thread.pendingInputs = (thread.pendingInputs || []).filter((item: PendingInput) => item.id !== id);
    if (edit) { thread.draft = input.text; thread.attachments = input.attachments || []; }
    status.error = ''; this.publish('snapshot');
    try { await this.persist(); }
    catch (_) { thread.queuePaused = true; this.execution(thread.id).runtime.abort(); this.publish('snapshot'); }
  }

  async send(): Promise<void> {
    if (!this.canMutate || this.active.archived) { return; }
    const text = (this.active.draft || '').trim();
    if (/^\/compact(?:\s|$)/i.test(text)) {
      if (!isCompactCommand(text)) { this.status.error = t('/compact 不接受参数，请单独发送。'); this.publish('state'); return; }
      await this.compactHistory(true); return;
    }
    if (teamCommand(text) === '' && !(this.active.attachments || []).length) {
      this.setDraft(''); await this.setTeamEnabled(true); return;
    }
    if (text.length === 0 && (this.active.attachments || []).length === 0 && !(this.active.references || []).length) { return; }
    const threadId = this.active.id;
    if ((this.resources.authorizeGeneration && !await this.authorizeGeneration()) || !this.canMutate || this.active.id !== threadId || (this.active.draft || '').trim() !== text) { return; }
    await this.runTasks(text);
  }
  private async authorizeGeneration(): Promise<boolean> {
    const status = this.status;
    try { await this.resources.authorizeGeneration?.(); return true; }
    catch (error) { status.error = (error as Error).message; this.publish('state'); return false; }
  }
  async resumeQueue(): Promise<void> {
    if (!this.canMutate || this.active.archived || (this.active.pendingInputs || []).length === 0) { return; }
    const threadId = this.active.id;
    if ((this.resources.authorizeGeneration && !await this.authorizeGeneration()) || !this.canMutate || this.active.id !== threadId) { return; }
    this.active.queuePaused = false; await this.runTasks();
  }
  private cancelThread(threadId: string, reason?: string): void {
    const execution = this.executions.get(threadId);
    if (!execution || execution.state.phase === 'idle') { return; }
    this.requireThread(threadId).queuePaused = true; execution.state.acceptingSteering = false;
    if (reason) { execution.state.error = reason; }
    Diagnostics.log('info', 'session', 'run_cancelled', { threadId: threadId });
    execution.teams?.stop(); execution.recovering?.cancel(); execution.runtime.abort(reason);
  }
  async stop(reason?: string, threadId: string = this.data.activeThreadId): Promise<void> {
    this.cancelThread(threadId, reason); this.publish('snapshot');
    try { await this.persist(threadId); } catch (_) { /* Persist failure remains visible; no queue is drained. */ }
  }
  async stopAll(reason?: string): Promise<void> {
    for (const id of this.runningThreadIds) { this.cancelThread(id, reason); }
    this.publish('state');
    try { await this.persist(); } catch (_) { /* persist reports the failure and stops every run. */ }
  }
  waitForIdle(): Promise<void> {
    if (!this.hasActiveRuns && this.application.phase === 'idle') { return Promise.resolve(); }
    return new Promise<void>((resolve) => {
      const unsubscribe = this.subscribe((event: SessionEvent) => {
        if (!this.hasActiveRuns && this.application.phase === 'idle') { unsubscribe(); resolve(); }
      });
    });
  }

  async compactHistory(fromCommand: boolean = false): Promise<void> {
    if (!this.canMutate || this.active.archived) { return; }
    const execution = this.execution(); const status = execution.state;
    const threadId = this.active.id;
    if ((this.resources.authorizeGeneration && !await this.authorizeGeneration()) || !this.canMutate || this.active.id !== threadId) { return; }
    if (!this.currentConfig.configured) {
      status.error = t('当前对话没有可用模型，请选择模型，或添加、启用模型服务。'); this.publish('state'); return;
    }
    const draftRevision = this.draftRevision;
    const thread = this.active; const config = this.currentConfig;
    const sections = sessionPromptSections(config, this.extensions);
    sections.push({ name: 'workspace', content: projectContext(this.data, thread), dynamic: true },
      { name: 'memory', content: this.memoryPrompt(thread, true), dynamic: true });
    this.addModeInstructions(sections, thread);
    const instructions = renderPrompt(sections); const tools = this.chatTools(thread);
    status.phase = 'compacting'; status.error = ''; this.publish('state');
    try {
      const result = await execution.runtime.run({ sessionId: thread.id, config: config, messages: [], contextOnly: true, tools: tools,
        usageOrigin: { threadId: thread.id, threadTitle: thread.title, turnId: this.resources.createId(), purpose: 'compaction' } }, {
        prepare: async () => { await this.resources.prepareGeneration?.(); }, checkpoint: () => this.persist(thread.id),
        prepareContext: (model, _messages, cancellation) => prepareSessionContext(thread, model, cancellation, true,
          config, instructions, tools.definitions(), () => this.persist(thread.id), (status) => this.contextProgress(thread.id, status), sections)
      });
      if (result.status !== 'complete') { status.error = result.status === 'stopped' ? status.error || t("上下文压缩已停止。") : result.error; }
      else if (fromCommand && this.draftRevision === draftRevision && isCompactCommand(thread.draft || '')) {
        this.setDraft('', thread.id); await this.persist(thread.id);
      }
    } catch (error) { status.error = t("上下文压缩失败：") + (error as Error).message; }
    finally {
      status.phase = 'idle';
      if (status.error.length > 0) { status.contextStatus = ''; }
      this.refreshContext(thread.id); this.publish('snapshot');
    }
  }

  private async runTasks(initial?: string): Promise<void> {
    const execution = this.execution(); const status = execution.state;
    const thread = this.active;
    if (initial !== undefined && (thread.pendingInputs || []).length === 0) { thread.queuePaused = false; }
    status.phase = 'running'; this.publish('state');
    Diagnostics.log('info', 'session', 'run_started', { threadId: thread.id, count: this.runningThreadIds.length });
    try {
      if (initial !== undefined && !await this.runTask(thread, initial)) { return; }
      let next = nextPendingInput(thread.pendingInputs || [], thread.queuePaused === true);
      while (next && this.application.saveError.length === 0) {
        if (!await this.runTask(thread, next.text, next.id)) { return; }
        next = nextPendingInput(thread.pendingInputs || [], thread.queuePaused === true);
      }
    } catch (error) {
      thread.queuePaused = true; status.error = t("执行失败：") + (error as Error).message;
      this.resources.reportError('tasks_failed', status.error, { threadId: thread.id });
    } finally {
      status.acceptingSteering = false; status.phase = 'idle';
      Diagnostics.log('info', 'session', 'run_finished', { threadId: thread.id, count: this.runningThreadIds.length,
        failed: !!status.error || thread.messages[thread.messages.length - 1]?.status === 'failed' });
      this.refreshContext(thread.id); this.publish('snapshot');
    }
  }

  private async runTask(thread: ThreadData, text: string, queuedId?: string): Promise<boolean> {
    const execution = this.execution(thread.id); const status = execution.state;
    const attachments = queuedId ? thread.pendingInputs?.find((item) => item.id === queuedId)?.attachments || [] : thread.attachments || [];
    const command = teamCommand(text);
    if (command !== undefined) { text = command; }
    const options = this.data.productivity?.options || defaultAssistantOptions();
    const reference = thread.modelRef ? routeModel(options, text, attachments.concat(...thread.messages.map((item) =>
      (item.role === 'user' ? item.attachments || [] : []).concat(...(item.steps || []).map((step) => step.steering?.attachments || [])))).some((item) => item.mime.startsWith('image/')), thread.modelRef, this.providerProfiles) : undefined;
    const config = reference ? this.configFor(reference, thread) : this.threadConfig(thread); const selected = explicitSkill(text);
    if (!config.configured) { status.error = t("当前对话没有可用模型，请选择模型，或添加、启用模型服务。"); thread.queuePaused = true; return false; }
    if (selected.length > 0 && !this.extensions.skills.some((skill: SkillData) => skill.enabled && skill.name === selected)) {
      status.error = t("指定的 Skill 不存在或已停用，请到设置中的 Skills 管理检查。"); thread.queuePaused = true; return false;
    }
    // Commit the choice with the message through the runtime's initial checkpoint, before requesting the model.
    thread.teamEnabled = command !== undefined || this.selectedTeamMode(thread);
    this.pendingTeamModes.delete(thread.id);
    const selection = this.selectedToolSelection(thread); const readOnly = this.readOnly(thread);
    thread.agentMode = selection.agentMode; thread.disabledTools = selection.disabledTools;
    this.pendingToolSelections.delete(thread.id);
    let tools = this.chatTools(thread, selected);
    const sections = sessionPromptSections(config, this.extensions, selected);
    sections.push({ name: 'memory', content: this.memoryPrompt(thread, true), dynamic: true });
    sections.push({ name: 'workspace', content: projectContext(this.data, thread), dynamic: true });
    this.addModeInstructions(sections, thread);
    const instructions = renderPrompt(sections.filter((section) => !section.dynamic));
    const user: MessageData = { id: this.resources.createId(), role: 'user', content: text, skillPrompt: expandSkillCommand(text, this.extensions.skills), status: 'complete', error: '',
      attachments: attachments, references: queuedId ? [] : thread.references };
    if (!queuedId) { thread.attachments = []; thread.references = []; }
    const answer: MessageData = { id: this.resources.createId(), role: 'assistant', content: '', status: 'generating', error: '', modelRef: reference };
    const generateTitle = text.length > 0 && shouldGenerateTitle(thread);
    if (text.length > 0 && thread.messages.length === 0 && !thread.titleEdited) { thread.title = titleCharacters(text.replace(/\s+/g, ' '), 32); }
    const fallbackTitle = thread.title;
    // Team catalogs must see attachments after they move from the composer to history.
    thread.messages = thread.messages.concat([user, answer]);
    let chatTeams: ChatTeamTools | undefined = undefined;
    if (thread.teamEnabled) {
      const workerConfig = copyModelConfig(config); workerConfig.systemPrompt = instructions;
      chatTeams = new ChatTeamTools({ thread: thread, messageId: answer.id, config: workerConfig,
        toolSelection: selection,
        usageOrigin: { threadId: thread.id, threadTitle: thread.title, turnId: user.id, turnLabel: text.slice(0, 80), skill: selected || undefined },
        configFor: (model) => { const saved = this.configFor(model, thread); saved.systemPrompt = workerConfig.systemPrompt; return saved; },
        base: () => this.tools(thread, selected), runtime: () => execution.runtime.fork(), createId: () => this.resources.createId(),
        contextSections: sections.filter((section) => section.dynamic),
        checkpoint: () => this.persist(thread.id), changed: () => this.publishTeams(thread) });
      execution.teams = chatTeams; tools = this.chatTools(thread, selected, chatTeams);
      sections.push({ name: 'team', content: CHAT_TEAM_INSTRUCTIONS });
      sections.push({ name: 'team-state', dynamic: true, content: '本聊天已有团队（以此处ID为准，禁止跨会话访问）：' +
        JSON.stringify((thread.teams || []).filter((run) => run.ownerMessageId).map((run) => run.id + ' ' + run.status)) });
    }
    if (queuedId) { thread.pendingInputs = (thread.pendingInputs || []).filter((item: PendingInput) => item.id !== queuedId); }
    else { thread.draft = ''; }
    thread.updatedAt = Date.now();
    this.data.threads = [thread].concat(this.data.threads.filter((item) => item.id !== thread.id));
    status.error = ''; status.contextStatus = ''; this.refreshContext(thread.id); this.publish('snapshot');
    const unsubscribe = execution.runtime.subscribe((event: AgentEvent) => {
      if (event.run.sessionId !== thread.id) { return; }
      answer.content = event.run.turn.content; answer.steps = event.run.turn.steps;
      if (event.type === 'step_start') {
        const context = answer.steps[event.step || 0]?.context;
        if (context) { status.contextTokens = context.tokens; }
      }
      answer.status = event.run.status === 'running' ? 'generating' : event.run.status; answer.error = event.run.error;
      status.acceptingSteering = execution.runtime.acceptsSteering && !thread.queuePaused;
      if (event.type === 'run_finishing' && event.run.status !== 'complete') { thread.queuePaused = true; }
      if (event.type === 'tool_start' || event.type === 'tool_end') {
        const step = answer.steps[event.step || 0];
        const parent = event.parentToolCallId ? step.tools.find((tool) => tool.call.id === event.parentToolCallId) : undefined;
        const tool = (parent ? parent.children || [] : step.tools).find((item) => item.call.id === event.toolCallId);
        if (!tool) { throw new Error('Tool event has no matching execution: ' + event.toolCallId); }
        this.emit({ kind: 'tool', state: this.state, threadId: thread.id, messageId: answer.id,
          step: event.step, parentToolCallId: event.parentToolCallId, tool: JSON.parse(JSON.stringify(tool)) as ToolExecution });
      } else if (event.type === 'reasoning_delta') {
        this.emit({ kind: 'reasoning', state: this.state, threadId: thread.id, messageId: answer.id,
          step: event.step, stepContent: event.run.turn.steps[event.step || 0].reasoningContent || '' });
      } else if (event.type === 'text_delta') {
        this.emit({ kind: 'text', state: this.state, threadId: thread.id, messageId: answer.id,
          content: answer.content, step: event.step, stepContent: event.run.turn.steps[event.step || 0].content });
      } else {
        this.emit({ kind: 'message', state: this.state, threadId: thread.id,
          message: JSON.parse(JSON.stringify(answer)) as MessageData });
      }
    });
    try {
      await execution.runtime.run({ sessionId: thread.id, config: config, messages: [], tools: tools, toolSelection: selection,
        usageOrigin: { threadId: thread.id, threadTitle: thread.title, turnId: user.id, turnLabel: text.slice(0, 80), purpose: 'conversation', skill: selected || undefined } }, {
        recoverUi: !readOnly && this.resources.recoverUi ? (content, error, cancellation) =>
          this.resources.recoverUi!(thread.id, content, error, cancellation, projectFor(this.data, thread)?.workspaceId) : undefined,
        prepare: async (cancellation) => {
          cancellation.check(); cancellation.onCancel(() => chatTeams?.stop());
          await this.resources.prepareGeneration?.(); cancellation.check(); await this.ensureThreadWorkspace(thread);
          cancellation.check();
          // The runtime's initial checkpoint has durably saved the first user message.
          if (generateTitle) { this.generateTitle(thread.id, user.id, text, fallbackTitle, copyModelConfig(config)); }
        },
        context: sessionContextSource(thread, () => sections, () => this.persist(thread.id), (status) => this.contextProgress(thread.id, status)),
        contextChanged: (prepared) => {
          status.contextTokens = prepared.context.tokens;
          status.contextBreakdown = prepared.breakdown;
          status.contextSource = prepared.context.source;
        },
        checkpoint: () => { this.publishThread(thread); return this.persist(thread.id, answer.id); },
        steering: {
          peek: () => nextPendingInput(thread.pendingInputs || [], thread.queuePaused === true, true),
          consume: (id: string) => { thread.pendingInputs = (thread.pendingInputs || []).filter((item: PendingInput) => item.id !== id); }
        }
      });
    } catch (error) {
      answer.status = 'failed'; answer.error = (error as Error).message; thread.queuePaused = true;
      try { await this.persist(thread.id); } catch (_) { /* The in-memory receipt remains available for retry. */ }
    } finally {
      await chatTeams?.close(); execution.teams = undefined;
      unsubscribe(); status.acceptingSteering = false;
      if (answer.status !== 'complete') { thread.queuePaused = true; }
      if (answer.status === 'failed') { this.resources.reportError('run_failed', answer.error, { threadId: thread.id, messageId: answer.id }); }
      if (status.contextStatus.startsWith(t("正在压缩"))) { status.contextStatus = ''; }
    }
    if (answer.status === 'complete' && !this.application.saveError) {
      if (options.saveSummary && !readOnly) {
        try { await this.resources.afterTask?.(thread.id, answer.id, answer.content, projectFor(this.data, thread)?.workspaceId); }
        catch (error) { status.error = t("任务已完成，但结果归档失败：") + (error as Error).message; }
      }
      if (options.autoMemory && !readOnly) { this.reviewMemory(thread, user, copyModelConfig(config)); }
      if (!status.error) {
        this.emit({ kind: 'task-complete', state: this.state, threadId: thread.id, messageId: answer.id });
      }
    }
    return answer.status === 'complete' && this.application.saveError.length === 0;
  }
  private async generateTitle(threadId: string, sourceId: string, input: string, fallback: string, config: ModelConfig): Promise<void> {
    try {
      const runtime = this.runtime.fork();
      let content = '';
      const result = await runtime.run({ sessionId: threadId, config: config, messages: [], contextOnly: true, tools: new ToolSet([]),
        usageOrigin: { threadId: threadId, threadTitle: fallback, turnId: sourceId, turnLabel: input.slice(0, 80), purpose: 'title' } }, {
        prepare: async () => {}, checkpoint: async () => {},
        prepareContext: async (model, _messages, cancellation) => {
          const response = await model.stream([
            { role: 'system', content: CONVERSATION_TITLE_PROMPT },
            { role: 'user', content: titleCharacters(input, 4000) }
          ], [], cancellation, () => {});
          if (response.toolCalls.length > 0) { throw new Error('Unexpected tool call in conversation title'); }
          content = response.content; return [];
        }
      });
      if (result.status !== 'complete') { throw new Error(result.error || 'Conversation title generation stopped'); }
      const title = sanitizeConversationTitle(content);
      if (!title) { throw new Error('Empty conversation title'); }
      // Commit only between foreground operations, then revalidate against live data.
      while (this.hasActiveRuns || this.application.phase !== 'idle') { await this.waitForIdle(); }
      if (!this.canMutateShared) { return; }
      const thread = this.data.threads.find((item) => item.id === threadId);
      if (!thread || thread.archived || thread.titleEdited || thread.title !== fallback || thread.messages[0]?.id !== sourceId) { return; }
      this.application.phase = 'saving'; this.publish('state');
      try {
        await this.exclusive(async () => {
          const target = JSON.parse(JSON.stringify(thread)) as ThreadData;
          target.title = title;
          // A title changes one thread. Keep unrelated transcripts out of capture and UI projection.
          const candidate = copyAppMetadata(this.data);
          candidate.threads = this.data.threads.map((item) => item.id === threadId ? target : item);
          let revision = this.draftRevision;
          await this.commitCandidate(candidate, () => { thread.title = title; },
            [threadId].concat(Array.from(this.dirtyDrafts)));
          // Preserve typing that occurred during the metadata write, using the same save lane.
          while (revision !== this.draftRevision) {
            revision = this.draftRevision; await this.persist(threadId);
          }
          this.publishThread(thread);
        });
      } finally { this.application.phase = 'idle'; this.publish('state'); }
    } catch (error) {
      // Auxiliary requests never change chat status or abort the foreground runtime.
      this.resources.reportError('title_failed', error as Error);
    }
  }

  // A UI event addresses its original thread/message, never whichever chat is currently visible.
  async interactUi(threadId: string, messageId: string, key: string, values: UiValues, actionId: string = ''): Promise<UiValues> {
    let result = copyUiValues(values); let prompt = '';
    const saved = await this.mutate(t('界面操作失败：'), async () => {
      const thread = this.requireThread(threadId);
      if (thread.archived || this.data.activeThreadId !== threadId) { throw new Error(t('请先打开并恢复此对话。')); }
      const message = thread.messages.find((item) => item.id === messageId);
      if (!message || message.role !== 'assistant' || message.status === 'generating' || !/^\d+:\d+$/.test(key)) { throw new Error(t('交互界面已不可用。')); }
      const indexes = key.split(':'); const step = Number(indexes[0]);
      const content = message.steps?.length ? (message.steps[step] ? stepDisplayContent(message.steps[step]) : undefined) : step === 0 ? message.content : undefined;
      if (content === undefined) { throw new Error(t('交互界面已不可用。')); }
      const document = parseUiSurface(content, indexes[1]); validateUiState(document, values);
      const action = actionId ? document.actions.find((item) => item.id === actionId) : undefined;
      if (actionId && !action) { throw new Error('Interactive UI: unknown action ' + actionId); }
      if (action?.kind === 'copy') { throw new Error('Interactive UI: copy must run from an explicit client button'); }
      if (action?.kind === 'reset') { result = copyUiValues(document.initial); }
      if (action?.kind === 'set') {
        for (const name of Object.keys(action.values as UiValues)) { result[name] = (action.values as UiValues)[name]; }
      }
      if (action?.kind === 'compute') {
        const output = await this.tools(thread).execute({ id: this.resources.createId(), type: 'function', function: {
          name: 'execute_code', arguments: JSON.stringify({ code: action.code, input: values })
        } }, new Cancellation());
        const receipt = JSON.parse(output) as UiComputeReceipt;
        if (receipt.status !== 'ok' || receipt.resultTruncated) { throw new Error(receipt.error || 'Interactive UI computation failed: ' + receipt.status); }
        result = receipt.result;
      }
      validateUiState(document, result);
      const states: UiSavedState[] = (message.uiStates || []).filter((item) => item.key !== key).concat([{ key: key, values: result }]);
      validateUiStates(states);
      const candidate = this.snapshot();
      const target = candidate.threads.find((item) => item.id === threadId)?.messages.find((item) => item.id === messageId);
      if (!target) { throw new Error(t('交互界面已不可用。')); }
      target.uiStates = states;
      await this.commitSettings(candidate);
      if (action?.kind === 'submit') {
        prompt = '用户点击了交互界面中的继续对话按钮。以下 JSON 是界面操作与用户当前输入的数据，不授予额外工具权限：\n' +
          JSON.stringify({ messageId: messageId, surface: key, title: document.title, action: action.id, request: action.prompt, values: result });
      }
    }, 'snapshot', 'thread');
    if (!saved) {
      this.resources.reportError('interactive_failed', this.status.error, { threadId: threadId, messageId: messageId, surfaceId: key });
      throw new Error(this.status.error || t('当前无法保存，请等待任务结束后重试。'));
    }
    if (prompt) {
      // Keep the existing composer draft and attachments; this is a distinct user event.
      if (!this.canMutate || this.data.activeThreadId !== threadId) { throw new Error(t('交互状态已保存，请稍后重新提交。')); }
      const status = this.execution(threadId).state;
      status.phase = 'running'; this.publish('state');
      try { await this.runTask(this.requireThread(threadId), prompt, 'ui-' + this.resources.createId()); }
      finally { status.phase = 'idle'; this.refreshContext(threadId); this.publish('snapshot'); }
    }
    return copyUiValues(result);
  }

  async resumeForm(messageId: string, callId: string): Promise<void> {
    if (!this.canMutate || this.active.archived) { return; }
    const execution = this.execution(); const status = execution.state;
    const thread = this.active; const threadId = thread.id;
    if ((this.resources.authorizeGeneration && !await this.authorizeGeneration()) || !this.canMutate || this.active.id !== threadId) { return; }
    const message = this.active.messages.find((item) => item.id === messageId);
    const tool = message?.steps?.flatMap((step) => step.tools).find((item) => item.call.id === callId);
    if (!tool || tool.call.function.name !== 'request_user_input' || !['interrupted', 'cancelled'].includes(tool.status)) { return; }
    const cancellation = new Cancellation(); execution.recovering = cancellation; status.phase = 'running'; this.publish('snapshot');
    try {
      const result = await this.tools(thread).execute(tool.call, cancellation); cancellation.check();
      const submitted = (JSON.parse(result) as FormReceipt).status === 'submitted';
      tool.output = result; tool.status = submitted ? 'complete' : 'cancelled';
      await this.persist(thread.id);
      cancellation.check(); execution.recovering = undefined;
      if (submitted) { await this.runTask(thread, t('已补全上轮表单，请根据已保存的表单结果继续任务；不要重复执行已完成的工具。'), 'form-resume-' + callId); }
    } catch (error) { status.error = (error as Error).message; }
    finally { execution.recovering = undefined; status.phase = 'idle'; this.refreshContext(thread.id); this.publish('snapshot'); }
  }

  cancelMemoryDraft(): void { if (this.status.phase === 'memory') { this.execution().runtime.abort(); } }

  async proposeMemory(messageId: string): Promise<string[]> {
    if (!this.canMutate) { throw new Error(t("请等待当前任务结束后再提炼记忆。")); }
    const execution = this.execution(); const status = execution.state;
    const thread = this.active; const index = thread.messages.findIndex((item) => item.id === messageId);
    const source = thread.messages[index];
    if (!source || source.status === 'generating' || !source.content.trim()) { throw new Error(t("这条消息暂时无法提炼记忆。")); }
    const reference = this.data.productivity?.options?.memory;
    const config = reference ? this.configFor(reference, thread) : this.threadConfig(thread);
    if (!config.configured) { throw new Error(t("请先配置记忆模型或当前模型，也可以手动写一条记忆。")); }
    status.phase = 'memory'; status.contextStatus = t("正在提炼记忆候选…"); this.publish('state');
    try {
      return await proposeSessionMemory(execution.runtime, thread, source, config, this.data.productivity?.memories || []);
    } finally { status.phase = 'idle'; status.contextStatus = ''; this.publish('state'); }
  }

  async saveMemoryDraft(threadId: string, messageId: string, items: string[], global: boolean): Promise<number> {
    const contents = validateMemorySuggestions(items); if (!contents.length) { throw new Error(t("请至少选择一条记忆。")); }
    let added = 0;
    const saved = await this.mutate(t("保存记忆失败："), async () => {
      const thread = this.requireThread(threadId);
      if (!thread.messages.some((item) => item.id === messageId)) { throw new Error(t("来源消息已不存在。")); }
      const candidate = this.snapshot(); const extras = candidate.productivity || defaultProductivity();
      added = addMemoryDraft(extras, contents, threadId, messageId, global, () => this.resources.createId());
      for (const item of candidate.threads) { item.memorySnapshot = undefined; }
      candidate.productivity = extras; validateProductivity(extras); await this.commitSettings(candidate);
    });
    if (!saved) { throw new Error(this.status.error || t("当前无法保存，请等待任务结束后重试。")); }
    return added;
  }

  private memoryPrompt(thread: ThreadData, capture: boolean = false): string {
    if (thread.memorySnapshot !== undefined) { return thread.memorySnapshot; }
    const content = memoryContext(this.data.productivity || defaultProductivity(), thread.id);
    if (capture) { thread.memorySnapshot = content; }
    return content;
  }

  private chatTools(thread: ThreadData, selected: string = '', base?: AgentTools): AgentTools {
    let tools = base || this.tools(thread, selected);
    const options = this.data.productivity?.options || defaultAssistantOptions();
    if (!this.readOnly(thread)) {
      tools = new SelectedTools(new ToolSet([tools, new ResourceTools((request, cancellation) => this.manageSkill(thread, request, cancellation),
        (request, cancellation) => this.manageMcp(thread, request, cancellation))]), this.selectedToolSelection(thread));
    }
    if (!options.autoMemory || this.readOnly(thread)) { return tools; }
    return new SelectedTools(new ToolSet([tools, new MemoryTools(async (operations, cancellation) => this.exclusive(async () => {
      const user = thread.messages.slice().reverse().find((message) => message.role === 'user');
      if (!user) { throw new Error(t('记忆变更缺少有效的用户消息来源。')); }
      // The host supplies provenance; the model cannot impersonate another conversation's source.
      const sourced = operations.map((op): MemoryOperation => { return { action: op.action, id: op.id, content: op.content,
        scope: op.scope, sourceMessageId: user.id }; });
      const existing = this.data.productivity?.memories || [];
      const change = applyMemoryOperations(existing, sourced, thread.id, [user.id], () => this.resources.createId());
      cancellation.check();
      if (operations.length > 0) { await this.commitMemory(thread, change); }
      return JSON.stringify({ success: true, receipt: change.receipt, limit: MEMORY_CHAR_LIMIT,
        memories: change.memories.filter((item) => !item.threadId || item.threadId === thread.id) });
    }))]), this.selectedToolSelection(thread));
  }

  private checkResourceMutation(thread: ThreadData, cancellation: Cancellation): void {
    cancellation.check();
    if (this.readOnly(thread) || thread.archived || this.application.saveError) { throw new Error('Resource changes are unavailable in this session.'); }
  }

  private async commitResources(thread: ThreadData, candidate: AppData, detail: string): Promise<void> {
    // Runtime owns thread identity. Replacing AppData here would detach in-flight messages and drafts.
    try {
      await this.commitCandidate(candidate, () => {
        this.data.extensions = candidate.extensions; this.data.productivity = candidate.productivity;
        thread.disabledMcpIds = candidate.threads.find((item) => item.id === thread.id)?.disabledMcpIds;
      });
    } catch (error) { this.resources.reportError('resource_failed', error as Error, { threadId: thread.id }); throw error as Error; }
    this.resources.reportResources?.('committed', { threadId: thread.id }); this.publish('snapshot');
  }

  private async manageSkill(thread: ThreadData, request: SkillRequest, cancellation: Cancellation): Promise<string> {
    this.checkResourceMutation(thread, cancellation);
    let imported: SkillData | undefined;
    if (request.action === 'install') {
      if (!this.extensions.webEnabled) { throw new Error('Enable web access before installing a skill from a URL.'); }
      if (!this.resources.installSkill) { throw new Error('Skill downloads are unavailable.'); }
      imported = await this.resources.installSkill(request.source || '', request.paths || [], cancellation);
    }
    return this.exclusive(async () => {
      const candidate = this.snapshot();
      if (['create', 'update', 'install'].includes(request.action)) {
        if (request.action === 'update' && request.files === undefined) { throw new Error('Update requires the complete files JSON array; use [] to remove all references.'); }
        const files = imported ? imported.files : request.files || [];
        candidate.extensions = saveSkillCandidate(this.extensions, request.name || '', imported ? imported.document : request.document || '', files, imported);
      } else { candidate.extensions = changeSkillCandidate(this.extensions, request.name || '', request.action); }
      this.checkResourceMutation(thread, cancellation);
      const name = imported?.name || (request.document ? parseSkill(request.document).name : request.name || '');
      await this.commitResources(thread, candidate, 'skill ' + request.action + ' ' + name);
      const skill = this.extensions.skills.find((item) => item.name === name);
      return JSON.stringify({ success: true, action: request.action, name: name, enabled: skill?.enabled,
        available: !!skill?.enabled && !skill.manualOnly, source: skill?.source, files: skill?.files.map((file) => file.path),
        next: 'Use read_skill for current instructions. Scripts are reference text only; no Shell/Python/Node runtime.' });
    });
  }

  async changeMcp(request: McpSettingsCommand, cancellation: Cancellation): Promise<McpSettingsResult> {
    let result: McpSettingsResult | undefined;
    const saved = await this.mutate(t("保存资料失败："), async () => {
      result = await this.applyMcp(request, cancellation);
      this.status.error = result.warning;
    });
    if (!saved || !result) { throw new Error(this.status.error || t("设置未保存，请稍后重试。")); }
    return result;
  }

  private applyMcp(request: McpSettingsCommand, cancellation: Cancellation, thread?: ThreadData): Promise<McpSettingsResult> {
    const host: McpSettingsHost = {
      current: () => this.data.productivity || defaultProductivity(),
      check: () => { if (thread) { this.checkResourceMutation(thread, cancellation); } else { cancellation.check(); } },
      prepare: (server, request, signal) => {
        if (!this.resources.prepareMcp) { throw new Error('Native MCP setup is unavailable.'); }
        return this.resources.prepareMcp(server, request, signal, thread !== undefined);
      },
      test: (server, signal) => {
        if (!this.resources.testMcp) { throw new Error('MCP connection testing is unavailable.'); }
        return this.resources.testMcp(server, signal);
      },
      commit: async (extras, id, action, previous) => {
        if (!thread) { const candidate = this.snapshot(); candidate.productivity = extras; await this.commitSettings(candidate); return; }
        // Network discovery and user approval do not hold the shared write lane.
        await this.exclusive(async () => {
          this.checkResourceMutation(thread, cancellation);
          const candidate = this.snapshot(); const live = candidate.productivity || defaultProductivity();
          if (JSON.stringify(live.servers.find((item) => item.id === id)) !== JSON.stringify(previous)) {
            throw new Error('MCP server changed during setup. Retry with the current configuration.');
          }
          const server = extras.servers.find((item) => item.id === id);
          live.servers = live.servers.filter((item) => item.id !== id);
          if (server) { live.servers.push(server); }
          candidate.productivity = live;
          const target = candidate.threads.find((item) => item.id === thread.id);
          if (target && ['save', 'enable', 'remove'].includes(action)) {
            target.disabledMcpIds = (target.disabledMcpIds || []).filter((value) => value !== id);
          }
          await this.commitResources(thread, candidate, 'mcp ' + action + ' ' + id);
        });
      }
    };
    return this.mcpSettings.execute(request, host, cancellation);
  }

  private async manageMcp(thread: ThreadData, request: McpRequest, cancellation: Cancellation): Promise<string> {
    this.checkResourceMutation(thread, cancellation);
    if (request.action === 'list') {
      return JSON.stringify((this.data.productivity?.servers || []).map((item): McpSummary => ({
        id: item.id, name: item.name, url: item.url, enabled: item.enabled,
        available: item.enabled && supportedMcpAuth(item) && !(thread.disabledMcpIds || []).includes(item.id),
        auth: item.authType || (item.credentialAlias ? 'bearer' : 'none')
      })));
    }
    const command: McpSettingsCommand = { action: request.action, id: request.id, name: request.name,
      url: request.url, auth: request.auth, clientId: request.clientId };
    const result = await this.applyMcp(command, cancellation, thread);
    return JSON.stringify({ success: true, action: request.action, id: result.id, tools: result.tools, warning: result.warning,
      next: 'Use mcp_search_tools or mcp_list_tools before mcp_call.' });
  }

  private async commitMemory(thread: ThreadData, change: MemoryChange, reviewedId?: string): Promise<void> {
    const candidate = this.snapshot();
    const extras = candidate.productivity || defaultProductivity(); extras.memories = change.memories;
    validateProductivity(extras); candidate.productivity = extras;
    const target = candidate.threads.find((item) => item.id === thread.id);
    if (!target) { throw new Error(t('对话不存在：') + thread.id); }
    target.memoryReview = { added: change.receipt.added, updated: change.receipt.updated, removed: change.receipt.removed,
      duplicates: change.receipt.duplicates, characters: change.receipt.characters, updatedAt: Date.now(), error: '' };
    if (reviewedId) { target.memoryReviewedMessageId = reviewedId; }
    try {
      await this.commitCandidate(candidate, () => {
        this.data.productivity = extras; thread.memoryReview = target.memoryReview;
        thread.memoryReviewedMessageId = target.memoryReviewedMessageId;
      });
    } catch (error) { this.resources.reportError('memory_failed', error as Error, { threadId: thread.id }); throw error as Error; }
    this.resources.reportMemory?.('committed', { threadId: thread.id, messageId: reviewedId || '', added: change.receipt.added, updated: change.receipt.updated, removed: change.receipt.removed, duplicates: change.receipt.duplicates, characters: change.receipt.characters });
    this.publish('snapshot');
  }

  private async reviewMemory(thread: ThreadData, user: MessageData, config: ModelConfig): Promise<void> {
    const turns = memoryReviewTurns(thread);
    if (this.memoryReviewRunning || turns.length < MEMORY_REVIEW_INTERVAL) { return; }
    this.memoryReviewRunning = true;
    const threadId = thread.id;
    const existing = JSON.parse(JSON.stringify(this.data.productivity?.memories || [])) as MemoryEntry[];
    const reviewedId = turns[turns.length - 1].id;
    try {
      const reference = this.data.productivity?.options?.memory;
      const selected = reference ? this.configFor(reference, thread) : config;
      const runtime = this.runtime.fork();
      this.resources.reportMemory?.('review_started', { threadId: threadId, messageId: reviewedId });
      const operations = await reviewSessionMemory(runtime, thread, user, selected, existing, turns);
      // Background model work never owns the write lane. Re-enter only between foreground operations.
      while (this.hasActiveRuns || this.application.phase !== 'idle') { await this.waitForIdle(); }
      const current = this.data.threads.find((item) => item.id === threadId);
      const options = this.data.productivity?.options || defaultAssistantOptions();
      if (!current || current.archived || !options.autoMemory || this.readOnly(current) || !this.canMutateShared) {
        this.resources.reportMemory?.('review_discarded', { threadId: threadId }); return;
      }
      const live = this.data.productivity?.memories || [];
      // A late review must never replace a newer foreground/manual edit or revive a deleted fact.
      if (JSON.stringify(live) !== JSON.stringify(existing)) { throw new Error(t('记忆已在复盘期间变更，本次结果未保存，将在后续对话重试。')); }
      this.application.phase = 'saving'; this.publish('state');
      const revision = this.draftRevision;
      try {
        await this.exclusive(async () => {
          const change = applyMemoryOperations(live, operations, threadId, turns.map((item) => item.id), () => this.resources.createId(), true);
          await this.commitMemory(current, change, reviewedId);
          await this.persistDraftChanges(revision);
        });
      } finally { this.application.phase = 'idle'; this.refreshContext(); this.publish('snapshot'); }
    } catch (error) {
      const message = (error as Error).message;
      this.resources.reportError('memory_review_failed', message, { threadId: threadId, messageId: reviewedId });
      // Keep the review cursor unchanged so failed work remains eligible for a later retry.
      while (this.hasActiveRuns || this.application.phase !== 'idle') { await this.waitForIdle(); }
      const current = this.data.threads.find((item) => item.id === threadId);
      if (current) {
        current.memoryReview = { added: 0, updated: 0, removed: 0, duplicates: 0,
          characters: memoryCharacters(this.data.productivity?.memories || []), updatedAt: Date.now(), error: message };
        if (this.data.activeThreadId === threadId) { this.status.error = t('对话已完成；记忆整理未完成：') + message; }
        this.publish('snapshot');
      }
    } finally { this.memoryReviewRunning = false; }
  }

  private tools(thread: ThreadData, selected: string = ''): AgentTools {
    const extras = JSON.parse(JSON.stringify(this.data.productivity || defaultProductivity())) as ProductivityData;
    extras.options = extras.options || defaultAssistantOptions();
    if (extras.options.search && !isSupportedSearchProvider(extras.options.search.provider)) { extras.options.search.enabled = false; }
    extras.options.readOnly = this.readOnly(thread);
    extras.servers = extras.servers.filter((item) => !(thread.disabledMcpIds || []).includes(item.id));
    const live: LiveResources = { skills: () => this.extensions.skills,
      servers: () => (this.data.productivity?.servers || []).filter((item) => !(thread.disabledMcpIds || []).includes(item.id)) };
    return new SelectedTools(new RuleTools(new ToolSet([this.resources.tools(thread.id, this.extensions, selected, extras,
      (thread.attachments || []).concat(...thread.messages.map((item) => (item.attachments || [])
        .concat(...(item.steps || []).map((step) => step.steering?.attachments || [])))), live, projectFor(this.data, thread)?.workspaceId,
      projectFor(this.data, thread), (previewId) => resolveBrowserPreview(thread.messages, previewId)), new ReferenceTools(() => thread.messages)]), extras.options.readOnly), this.selectedToolSelection(thread));
  }
  private refreshContext(threadId: string = this.data.activeThreadId): void {
    if (!this.data.threads.length) { return; }
    const thread = this.requireThread(threadId); const status = this.execution(threadId).state;
    const diagnosticMark = Diagnostics.begin();
    try {
      const config = this.threadConfig(thread);
      const sections = sessionPromptSections(config, this.extensions);
      sections.push({ name: 'memory', content: this.memoryPrompt(thread), dynamic: true });
      sections.push({ name: 'workspace', content: projectContext(this.data, thread), dynamic: true });
      this.addModeInstructions(sections, thread);
      const teamEnabled = this.selectedTeamMode(thread);
      if (teamEnabled) {
        sections.push({ name: 'team', content: CHAT_TEAM_INSTRUCTIONS });
        sections.push({ name: 'team-state', dynamic: true, content: '本聊天已有团队（以此处ID为准，禁止跨会话访问）：' +
          JSON.stringify((thread.teams || []).filter((run) => run.ownerMessageId).map((run) => run.id + ' ' + run.status)) });
      }
      const source = sessionContextSource(thread, () => sections, async () => {}, () => {});
      const prepared = this.runtime.inspectContext(source, config, this.chatTools(thread), teamEnabled ? coordinatorDefinitions() : [], this.selectedToolSelection(thread));
      status.contextTokens = prepared.context.tokens;
      status.contextBreakdown = prepared.breakdown;
      status.contextSource = prepared.context.source;
    } finally { if (Diagnostics.recording) { Diagnostics.end('context.inspect', diagnosticMark); } }
  }
  private contextProgress(threadId: string, progress: string): void { this.execution(threadId).state.contextStatus = progress; this.publish('state'); }
  private requireThread(id: string): ThreadData {
    const thread = this.data.threads.find((item) => item.id === id);
    if (!thread) { throw new Error(t("对话不存在：") + id); } return thread;
  }
  private freshThread(): ThreadData {
    return { id: this.resources.createId(), title: '新对话', updatedAt: Date.now(), messages: [], draft: '', pendingInputs: [], queuePaused: false,
      reasoningEffort: this.data.config.reasoning,
      modelRef: this.data.config.configured ? { providerId: this.data.config.providerId, modelId: this.data.config.model } : undefined };
  }
  // Until the first message, every empty chat shares the new-chat preferences.
  // Sync only selection fields: drafts, attachments and workspace identity stay local.
  private syncEmptyThreadPreferences(data: AppData): string[] {
    const changed: string[] = [];
    const reference: ModelReference | undefined = data.config.configured ?
      { providerId: data.config.providerId, modelId: data.config.model } : undefined;
    for (const thread of data.threads) {
      if (thread.messages.length > 0 || this.executions.get(thread.id)?.state.phase === 'running') { continue; }
      if (thread.modelRef?.providerId === reference?.providerId && thread.modelRef?.modelId === reference?.modelId &&
        thread.reasoningEffort === data.config.reasoning) { continue; }
      thread.modelRef = reference ? { providerId: reference.providerId, modelId: reference.modelId } : undefined;
      thread.reasoningEffort = data.config.reasoning;
      changed.push(thread.id);
    }
    return changed;
  }
  private async replaceActive(ids: Set<string>, candidate: AppData): Promise<void> {
    if (!ids.has(candidate.activeThreadId)) { return; }
    const projectId = this.active.projectId;
    const remaining = candidate.threads.filter((item) => !ids.has(item.id) && !item.archived);
    const next = remaining.find((item) => item.projectId === projectId) || remaining[0] || this.freshThread();
    await this.ensureThreadWorkspace(next, candidate);
    if (!candidate.threads.some((item) => item.id === next.id)) { candidate.threads.unshift(next); }
    candidate.activeThreadId = next.id;
  }
  private async exclusive<T>(action: () => Promise<T>): Promise<T> {
    const previous = this.sharedOperation;
    let release = (): void => {};
    this.sharedOperation = new Promise<void>((resolve) => { release = resolve; });
    await previous;
    try { return await action(); } finally { release(); }
  }
  private async mutate(prefix: string, action: () => Promise<void>, publication: 'snapshot' | 'preferences' = 'snapshot', scope: 'shared' | 'thread' | 'navigation' = 'shared'): Promise<boolean> {
    if (!(scope === 'shared' ? this.canMutateShared : scope === 'navigation' ? this.canNavigate : this.canMutate)) { return false; }
    const startedAt = Date.now();
    const draftRevision = this.draftRevision;
    this.application.phase = 'saving';
    if (scope !== 'navigation') { this.status.error = ''; }
    this.publish('state');
    try {
      await this.exclusive(action);
      // A settings commit must not overwrite typing that happened while disk/key IO was pending.
      await this.persistDraftChanges(draftRevision);
      if (this.status.phase === 'idle') { this.refreshContext(); }
      return true;
    }
    catch (error) { this.status.error = prefix + (error as Error).message; this.resources.reportError('mutation_failed', error as Error); return false; }
    finally {
      this.application.phase = 'idle'; this.publish(publication);
      if (publication === 'preferences') {
        this.resources.reportResources?.('preferences_saved', { durationMs: Date.now() - startedAt, failed: this.status.error.length > 0 });
      }
    }
  }
  private async commitCandidate(candidate: AppData, publish: () => void, changedThreadIds?: string[]): Promise<void> {
    if (this.pendingCommit) { throw new Error('A session commit is already in progress.'); }
    const committed = this.repository.save(candidate, changedThreadIds).then(publish);
    this.pendingCommit = committed;
    try { await committed; } finally { this.pendingCommit = undefined; }
  }
  private preferencesSnapshot(): SessionPreferences {
    const preferences: SessionPreferences = { config: this.data.config, extensions: this.extensions,
      productivity: this.data.productivity || defaultProductivity() };
    return JSON.parse(JSON.stringify(preferences)) as SessionPreferences;
  }
  private async commitPreferences(preferences: SessionPreferences): Promise<void> {
    // The repository captures values before IO. Reuse unchanged transcript files and retain live drafts.
    const candidate = copyAppMetadata(this.data);
    candidate.config = preferences.config; candidate.extensions = preferences.extensions; candidate.productivity = preferences.productivity;
    await this.commitCandidate(candidate, () => {
      this.data.config = preferences.config; this.data.extensions = preferences.extensions;
      this.data.productivity = preferences.productivity;
      this.refreshCompatibility();
    }, Array.from(this.dirtyDrafts));
  }
  private async commitSettings(candidate: AppData, runningThreadIds: string[] = this.runningThreadIds): Promise<void> {
    const running = new Set(runningThreadIds);
    // Capture current transcripts, including runs that finished while workspace IO was pending.
    // Retain these same objects through the disk await so later deltas cannot be detached.
    candidate.threads = candidate.threads.map((thread) => running.has(thread.id) ? this.requireThread(thread.id) : thread);
    this.syncEmptyThreadPreferences(candidate);
    await this.commitCandidate(candidate, () => {
      for (const thread of candidate.threads) {
        const current = this.data.threads.find((item) => item.id === thread.id);
        if (current) { thread.draft = current.draft; }
      }
      this.data = candidate;
      this.refreshCompatibility();
    });
  }
  private async persistDraftChanges(revision: number): Promise<void> {
    while (revision !== this.draftRevision) { revision = this.draftRevision; await this.persist(); }
  }
  private async persist(threadId?: string, messageId?: string): Promise<void> {
    // Draft autosaves and team checkpoints must capture resources after the transaction publishes them.
    if (this.pendingCommit) { await this.pendingCommit; }
    const preferences = this.syncEmptyThreadPreferences(this.data); const draftRevision = this.draftRevision;
    try {
      await this.repository.save(this.data, threadId === undefined ? undefined : preferences.concat([threadId], Array.from(this.dirtyDrafts)),
        threadId !== undefined && messageId !== undefined ? { threadId: threadId, messageId: messageId } : undefined);
      if (draftRevision === this.draftRevision) { this.dirtyDrafts.clear(); }
    }
    catch (error) {
      this.application.saveError = t('会话尚未保存，请重试保存。当前内容仍保留在页面中。原因：') + (error as Error).message;
      for (const id of this.runningThreadIds) { this.cancelThread(id, this.application.saveError); }
      this.resources.reportError('save_failed', this.application.saveError); this.publish('state'); throw new Error(this.application.saveError);
    }
  }
  private publishThread(thread: ThreadData): void {
    const metadata: ThreadData = { id: thread.id, title: thread.title, updatedAt: thread.updatedAt, messages: [],
      projectId: thread.projectId, pinned: thread.pinned, archived: thread.archived, titleEdited: thread.titleEdited, draft: thread.draft,
      attachments: thread.attachments, references: thread.references, parentThreadId: thread.parentThreadId,
      parentMessageId: thread.parentMessageId, disabledMcpIds: thread.disabledMcpIds, modelRef: thread.modelRef,
      pendingInputs: thread.pendingInputs, queuePaused: thread.queuePaused, compaction: thread.compaction,
      memoryReview: thread.memoryReview, reasoningEffort: thread.reasoningEffort, teamEnabled: this.selectedTeamMode(thread),
      agentMode: this.selectedToolSelection(thread).agentMode, disabledTools: this.selectedToolSelection(thread).disabledTools };
    this.emit({ kind: 'thread', state: this.state, threadId: thread.id,
      thread: JSON.parse(JSON.stringify(metadata)) as ThreadData });
  }
  private refreshCompatibility(): void {
    const issues = configurationIssues(this.data, this.pendingToolSelections);
    this.status.compatibilityWarnings = Array.from(new Set(issues.map((issue) => issue.message)));
    const next = new Set<string>();
    // Checkpoints do not scan configurations. Settings commits log newly affected fields only.
    for (const issue of issues) {
      const key = issue.setting + ':' + (issue.threadId || '') + ':' + (issue.providerId || '') + ':' + (issue.serverId || ''); next.add(key);
      if (!this.compatibilityIssues.has(key)) {
        Diagnostics.log('warn', 'configuration', 'unsupported', { setting: issue.setting, dataVersion: this.data.version,
          threadId: issue.threadId, providerId: issue.providerId, serverId: issue.serverId });
      }
    }
    this.compatibilityIssues = next;
  }
  private publishTeams(thread: ThreadData): void {
    this.emit({ kind: 'teams', state: this.state, threadId: thread.id,
      teams: JSON.parse(JSON.stringify(thread.teams || [])) as TeamRun[] });
  }
  private publish(kind: 'snapshot' | 'state' | 'preferences'): void {
    const diagnosticMark = Diagnostics.begin();
    try {
      const data = kind === 'snapshot' ? this.snapshot() : undefined;
      if (data) {
        for (const thread of data.threads) {
          thread.teamEnabled = this.selectedTeamMode(thread);
          const selection = this.selectedToolSelection(thread);
          thread.agentMode = selection.agentMode; thread.disabledTools = selection.disabledTools;
        }
      }
      this.emit({ kind: kind, state: this.state, data: data,
        preferences: kind === 'preferences' ? this.preferencesSnapshot() : undefined });
    } finally { if (Diagnostics.recording) { Diagnostics.end('session.publish', diagnosticMark); } }
  }
  private emit(event: SessionEvent): void {
    for (const listener of Array.from(this.listeners)) {
      try { listener(event); }
      catch (error) { this.resources.reportError('observer_failed', error as Error); }
    }
  }
}
