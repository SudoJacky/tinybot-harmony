import { describe, expect, it } from '@ohos/hypium';
import { contextSettings } from '../main/ets/model/ConversationContext';
import { DEFAULT_SYSTEM_PROMPT } from '../main/ets/model/SystemPrompt';
import { CONVERSATION_TITLE_PROMPT, sanitizeConversationTitle, titleCharacters } from '../main/ets/model/ConversationTitle';
import { ModelTurn, ToolCall, ToolDefinition } from '../main/ets/model/Agent';
import { AppData, ThreadData, emptyData, parseAppData } from '../main/ets/model/Conversation';
import { ProviderInfo } from '../main/ets/model/Provider';
import { ProviderProfile, modelConfig } from '../main/ets/model/ProviderProfiles';
import { ExtensionSettings, defaultExtensions } from '../main/ets/model/Skills';
import { AgentTools } from '../main/ets/services/AgentLoop';
import { AgentRuntime } from '../main/ets/services/AgentRuntime';
import { Cancellation, RunCancelledError } from '../main/ets/services/Cancellation';
import { CredentialVault, ProviderDraft } from '../main/ets/services/ProfileSettings';
import { SessionEvent, SessionRepository, SessionResources } from '../main/ets/services/SessionContracts';
import { SessionService } from '../main/ets/services/SessionService';
import { Attachment, ProductivityData, defaultProductivity } from '../main/ets/model/Productivity';
import { AttachmentTools } from '../main/ets/services/AttachmentTools';
import { ToolSet } from '../main/ets/services/ToolSet';
import { ModelProvider, ProviderRequest } from '../main/ets/services/providers/Provider';
import { ProviderRegistry } from '../main/ets/services/providers/ProviderRegistry';
import { defaultAssistantOptions } from '../main/ets/model/AssistantOptions';
import { InteractionTools } from '../main/ets/services/InteractionTools';
import { ToolApproval } from '../main/ets/services/ToolApproval';
import { InputForm } from '../main/ets/model/RichArtifacts';

class Gate {
  private release: () => void = () => {};
  promise: Promise<void> = new Promise<void>((resolve) => { this.release = resolve; });
  open(): void { this.release(); }
}

// Matches ConversationStore's capture-at-call and ordered write semantics, without platform APIs.
class MemoryRepository implements SessionRepository {
  saved: string;
  writes: AppData[] = [];
  beforeSave: (data: AppData) => Promise<void> = async () => {};
  private pending: Promise<void> = Promise.resolve();
  constructor(data: AppData) { this.saved = JSON.stringify(data); }
  async load(): Promise<AppData> { return parseAppData(this.saved); }
  save(data: AppData): Promise<void> {
    const text = JSON.stringify(data);
    const pending = this.pending.catch(() => {}).then(async () => {
      const snapshot = JSON.parse(text) as AppData;
      await this.beforeSave(snapshot);
      this.saved = text; this.writes.push(snapshot);
    });
    this.pending = pending; return pending;
  }
}

class Keys implements CredentialVault {
  values: Map<string, string> = new Map<string, string>();
  removed: string[] = [];
  async read(alias: string): Promise<string> {
    if (alias.length === 0) { return ''; }
    const value = this.values.get(alias);
    if (value === undefined) { throw new Error('missing key'); }
    return value;
  }
  async write(alias: string, secret: string): Promise<void> { this.values.set(alias, secret); }
  async remove(alias: string): Promise<void> { this.values.delete(alias); this.removed.push(alias); }
}

class ScriptedProvider implements ModelProvider {
  readonly info: ProviderInfo = { id: 'test', name: 'Test', protocol: 'test', defaultBaseUrl: 'https://example.com/v1', defaultModel: 'model' };
  requests: ProviderRequest[] = [];
  respond: (index: number, signal: Cancellation) => Promise<ModelTurn> = async () => reply();
  endpoint(baseUrl: string): string { return baseUrl + '/chat/completions'; }
  async stream(request: ProviderRequest, signal: Cancellation, onText: (text: string) => void): Promise<ModelTurn> {
    const index = this.requests.length; this.requests.push(request);
    const answer = await this.respond(index, signal); signal.check();
    onText(answer.content); return answer;
  }
}

class EmptyTools implements AgentTools {
  definitions(): ToolDefinition[] { return []; }
  async execute(_call: ToolCall, cancellation: Cancellation): Promise<string> { cancellation.check(); return 'ok'; }
}
class Resources implements SessionResources {
  agentTools: AgentTools = new EmptyTools();
  ids: number = 100;
  workspaces: string[] = [];
  errors: string[] = [];
  createId(): string { return 'id-' + ++this.ids; }
  async ensureWorkspace(id: string): Promise<void> { this.workspaces.push(id); }
  tools(_id: string, _extensions: ExtensionSettings, _selected: string, _productivity?: ProductivityData, attachments: Attachment[] = []): AgentTools {
    return new ToolSet([this.agentTools, new AttachmentTools(attachments)]);
  }
  configureProviders(_profiles: ProviderProfile[]): void {}
  reportError(message: string): void { this.errors.push(message); }
}
class Fixture {
  repository: MemoryRepository;
  keys: Keys = new Keys();
  provider: ScriptedProvider = new ScriptedProvider();
  resources: Resources = new Resources();
  session: SessionService;
  constructor(data: AppData = seed()) {
    this.repository = new MemoryRepository(data);
    const registry = new ProviderRegistry(); registry.register(this.provider);
    this.session = new SessionService(this.repository, new AgentRuntime(registry, this.keys), this.keys, this.resources);
  }
}
function reply(content: string = 'done'): ModelTurn { return { content: content, toolCalls: [] }; }
function seed(): AppData {
  const data = emptyData();
  // Most session tests isolate the main turn; memory-specific tests enable extraction separately.
  data.productivity = defaultProductivity(); data.productivity.options = defaultAssistantOptions();
  data.productivity.options.autoMemory = false;
  const profile: ProviderProfile = { id: 'test', name: 'Test', protocol: 'chat-completions', baseUrl: 'https://example.com/v1',
    credentialAlias: '', noApiKey: true, enabled: true, models: ['model'], contextWindow: 32768 };
  data.providerProfiles = [profile]; data.extensions = defaultExtensions();
  data.config = modelConfig([profile], { providerId: 'test', modelId: 'model' }, data.config);
  data.threads = [{ id: 'thread-1', title: 'Test', updatedAt: 1, messages: [], draft: '',
    modelRef: { providerId: 'test', modelId: 'model' }, pendingInputs: [], queuePaused: false }];
  data.activeThreadId = 'thread-1'; return data;
}
function active(data: AppData): ThreadData {
  const thread = data.threads.find((item) => item.id === data.activeThreadId);
  if (!thread) { throw new Error('missing fixture thread'); } return thread;
}
function providerDraft(): ProviderDraft {
  return { id: 'test', name: 'Edited', protocol: 'chat-completions', baseUrl: 'https://example.com/v1', apiKey: '',
    noApiKey: true, enabled: true, models: 'model', contextWindow: '32768' };
}
function historySeed(): AppData {
  const data = seed();
  for (let i = 0; i < 4; i++) {
    data.threads[0].messages.push({ id: 'user-' + i, role: 'user', content: 'historical input '.repeat(50), status: 'complete', error: '' });
    data.threads[0].messages.push({ id: 'answer-' + i, role: 'assistant', content: 'historical answer '.repeat(50), status: 'complete', error: '' });
  }
  return data;
}

function titleSeed(): AppData {
  const data = seed(); data.threads[0].title = '新对话'; return data;
}
function isTitleRequest(request: ProviderRequest): boolean {
  return request.messages[0]?.content === CONVERSATION_TITLE_PROMPT;
}
// All fixture IO is promise-based; drain detached auxiliary work without wall-clock sleeps.
async function settleTitles(): Promise<void> {
  for (let i = 0; i < 100; i++) { await Promise.resolve(); }
}

export default function sessionServiceTests(): void {
  describe('SessionService', () => {
    it('addsGlobalUserDocumentToRequestsAndClearsItWithoutChangingSystemRules', 0, async () => {
      const f = new Fixture(); await f.session.initialize();
      const document = '# About me\nCall me Lin.\n\n# Preferences\nKeep it concise.';
      expect(await f.session.saveSettings(document, true, false)).assertTrue();
      expect((await f.repository.load()).config.userDocument).assertEqual(document);
      expect(f.session.currentConfig.userDocument).assertEqual(document);
      f.session.setDraft('hello'); await f.session.send();
      const first = f.provider.requests[0].messages[0].content;
      expect(first.startsWith('<identity>\n' + DEFAULT_SYSTEM_PROMPT + '\n</identity>')).assertTrue();
      expect(first.includes(JSON.stringify(document))).assertTrue();
      await f.session.newThread();
      expect(f.session.currentConfig.userDocument).assertEqual(document);
      f.session.setDraft('hello again'); await f.session.send(); await settleTitles();
      const chats = f.provider.requests.filter((request) => !isTitleRequest(request));
      expect(chats[1].messages[0].content.includes(JSON.stringify(document))).assertTrue();
      expect(await f.session.saveSettings('', true, false)).assertTrue();
      f.session.setDraft('without preferences'); await f.session.send();
      const cleared = f.provider.requests.filter((request) => !isTitleRequest(request));
      expect(cleared[2].messages[0].content.startsWith('<identity>\n' + DEFAULT_SYSTEM_PROMPT + '\n</identity>')).assertTrue();
      expect(cleared[2].messages[0].content.includes('# USER.md')).assertFalse();
      expect((await f.repository.load()).config.userDocument).assertEqual('');
    });
    it('keepsSavedUserDocumentWhenSavingItsReplacementFails', 0, async () => {
      const f = new Fixture(); await f.session.initialize();
      expect(await f.session.saveSettings('original preferences', true, false)).assertTrue();
      f.repository.beforeSave = async () => { throw new Error('disk full'); };
      expect(await f.session.saveSettings('unsaved replacement', true, false)).assertFalse();
      expect(f.session.snapshot().config.userDocument).assertEqual('original preferences');
      expect((await f.repository.load()).config.userDocument).assertEqual('original preferences');
      expect(f.session.snapshot().config.systemPrompt).assertEqual(DEFAULT_SYSTEM_PROMPT);
    });
    it('restoresBackupPreferencesWithoutOverwritingAnExistingDocument', 0, async () => {
      const f = new Fixture(); await f.session.initialize();
      const imported = emptyData(); imported.config.userDocument = '# Restored preferences';
      imported.productivity = { memories: [], templates: [], servers: [] };
      expect(await f.session.importSnapshot(imported)).assertTrue();
      expect((await f.repository.load()).config.userDocument).assertEqual('# Restored preferences');
      imported.config.userDocument = 'different backup';
      expect(await f.session.importSnapshot(imported)).assertTrue();
      expect((await f.repository.load()).config.userDocument).assertEqual('# Restored preferences');
    });
    it('restoresUsingLocalServicesAndCredentialsWithoutOverwritingSettings', 0, async () => {
      const data = seed(); const profile = (data.providerProfiles as ProviderProfile[])[0];
      profile.noApiKey = false; profile.credentialAlias = 'local-key'; data.config.credentialAlias = 'local-key';
      data.config.userDocument = 'local preferences';
      data.productivity = defaultProductivity(); data.productivity.options = defaultAssistantOptions();
      data.productivity.options.autoMemory = false;
      data.productivity.servers = [{ id: 'local-mcp', name: 'Local MCP', url: 'https://mcp.example.com/api',
        enabled: true, credentialAlias: 'local-token', authType: 'oauth' }];
      const f = new Fixture(data); f.keys.values.set('local-key', 'local-secret'); f.keys.values.set('local-token', 'token-secret');
      await f.session.initialize(); const before = f.session.snapshot();
      const imported = seed(); imported.config.userDocument = 'backup preferences';
      imported.providerProfiles = [{ id: 'remote', name: 'Backup provider', protocol: profile.protocol, baseUrl: profile.baseUrl + '/',
        credentialAlias: '', noApiKey: true, enabled: false, models: ['model'] }];
      imported.threads[0].id = 'restored'; imported.threads[0].modelRef = { providerId: 'remote', modelId: 'model' };
      imported.threads[0].disabledMcpIds = ['remote-mcp'];
      imported.threads[0].messages = [{ id: 'old-question', role: 'user', content: 'saved question', status: 'complete', error: '' },
        { id: 'old-message', role: 'assistant', content: 'saved answer', status: 'complete', error: '',
        modelRef: { providerId: 'remote', modelId: 'model' } }];
      imported.productivity = { memories: [], templates: [], servers: [{ id: 'remote-mcp', name: 'Backup MCP',
        url: 'https://mcp.example.com/api', enabled: false, credentialAlias: '' }] };
      const originalImport = JSON.stringify(imported);
      expect(await f.session.importSnapshot(imported)).assertTrue();
      const saved = await f.repository.load();
      expect(JSON.stringify(saved.providerProfiles)).assertEqual(JSON.stringify(before.providerProfiles));
      expect(JSON.stringify(saved.config)).assertEqual(JSON.stringify(before.config));
      expect(JSON.stringify(saved.productivity)).assertEqual(JSON.stringify(before.productivity));
      expect(saved.activeThreadId).assertEqual(before.activeThreadId);
      const restored = saved.threads.find((thread) => thread.id === 'restored') as ThreadData;
      expect(restored.modelRef?.providerId).assertEqual('test');
      expect(restored.messages[1].modelRef?.providerId).assertEqual('test');
      expect(restored.disabledMcpIds?.[0]).assertEqual('local-mcp');
      expect(JSON.stringify(imported)).assertEqual(originalImport);
      expect(await f.session.selectThread('restored')).assertTrue();
      f.session.setDraft('continue restored conversation'); await f.session.send();
      expect(f.provider.requests[0].apiKey).assertEqual('local-secret');
      expect(f.keys.values.get('local-token')).assertEqual('token-secret'); expect(f.keys.removed.length).assertEqual(0);
    });
    it('doesNotGuessBetweenAccountsAndDoesNotReuseCredentialsForChangedEndpoints', 0, async () => {
      for (const changedEndpoint of [false, true]) {
        const data = seed(); const profiles = data.providerProfiles as ProviderProfile[];
        profiles[0].credentialAlias = 'existing-key'; profiles[0].noApiKey = false;
        profiles.push({ id: 'second', name: 'Second account', protocol: profiles[0].protocol, baseUrl: profiles[0].baseUrl,
          enabled: true, noApiKey: false, credentialAlias: 'second-key', models: ['model'] });
        const f = new Fixture(data); await f.session.initialize(); const before = JSON.stringify(f.session.snapshot().providerProfiles);
        const imported = historySeed(); const profile = (imported.providerProfiles as ProviderProfile[])[0];
        profile.id = changedEndpoint ? 'test' : 'unknown-account';
        if (changedEndpoint) { profile.baseUrl = 'https://different.example.com/v1'; }
        imported.threads[0].id = 'restored'; imported.threads[0].modelRef = { providerId: profile.id, modelId: 'model' };
        imported.productivity = { memories: [], templates: [], servers: [] };
        expect(await f.session.importSnapshot(imported)).assertTrue();
        const saved = f.session.snapshot(); const all = saved.providerProfiles as ProviderProfile[];
        expect(all.length).assertEqual(3); expect(JSON.stringify(all.slice(0, 2))).assertEqual(before);
        expect(all[2].enabled).assertFalse(); expect(all[2].credentialAlias).assertEqual('');
        expect(all[2].id === profile.id).assertFalse();
        expect(saved.threads[1].modelRef?.providerId).assertEqual(all[2].id);
      }
    });
    it('prefersTheOriginalServiceIdAndLeavesLocalDataIntactWhenRestoreSaveFails', 0, async () => {
      const data = seed(); const profiles = data.providerProfiles as ProviderProfile[];
      profiles.push({ id: 'second', name: 'Second account', protocol: profiles[0].protocol, baseUrl: profiles[0].baseUrl,
        enabled: true, noApiKey: false, credentialAlias: 'second-key', models: ['model'] });
      const f = new Fixture(data); f.keys.values.set('second-key', 'preserved'); await f.session.initialize();
      const imported = seed(); imported.threads[0].id = 'restored'; imported.productivity = { memories: [], templates: [], servers: [] };
      const before = JSON.stringify(f.session.snapshot());
      f.repository.beforeSave = async () => { throw new Error('disk full'); };
      expect(await f.session.importSnapshot(imported)).assertFalse();
      expect(JSON.stringify(f.session.snapshot())).assertEqual(before); expect(f.keys.values.get('second-key')).assertEqual('preserved');
      f.repository.beforeSave = async () => {};
      expect(await f.session.importSnapshot(imported)).assertTrue();
      expect(f.session.snapshot().providerProfiles?.length).assertEqual(2);
      expect(f.session.snapshot().threads[1].modelRef?.providerId).assertEqual('test');
    });
    it('normalizesShortTitlesWithoutSplittingUnicodeCharacters', 0, () => {
      expect(sanitizeConversationTitle('  \n **"简短会话标题。"**\nexplanation')).assertEqual('简短会话标题');
      expect(sanitizeConversationTitle('  Fix   login\t failures! ')).assertEqual('Fix login failures');
      expect(sanitizeConversationTitle('***。***')).assertEqual('');
      expect(sanitizeConversationTitle('😀'.repeat(40))).assertEqual('😀'.repeat(28));
      expect(titleCharacters('😀abc', 2)).assertEqual('😀a');
    });
    it('generatesOneDurableTitleUsingTheFirstTurnsModelWithoutBlockingChat', 0, async () => {
      const data = titleSeed(); data.config.reasoning = 'high';
      const f = new Fixture(data); await f.session.initialize();
      const release = new Gate(); const entered = new Gate();
      f.provider.respond = async (index) => {
        if (!isTitleRequest(f.provider.requests[index])) { return reply('normal answer'); }
        expect(active(await f.repository.load()).messages[0].content).assertEqual('帮我排查登录失败的原因');
        entered.open(); await release.promise; return reply('**登录故障排查。**');
      };
      f.session.setDraft('帮我排查登录失败的原因'); await f.session.send(); await entered.promise;
      expect(f.session.state.phase).assertEqual('idle');
      expect(active(f.session.snapshot()).messages[1].content).assertEqual('normal answer');
      expect(active(f.session.snapshot()).title).assertEqual('帮我排查登录失败的原因');
      release.open(); await settleTitles();
      const saved = active(await f.repository.load());
      expect(saved.title).assertEqual('登录故障排查'); expect(saved.messages.length).assertEqual(2);
      expect(saved.titleEdited === true).assertFalse();
      const request = f.provider.requests.find((item) => isTitleRequest(item));
      const conversation = f.provider.requests.find((item) => !isTitleRequest(item));
      expect(request?.usageOrigin?.purpose).assertEqual('title');
      expect(conversation?.usageOrigin?.purpose).assertEqual('conversation');
      expect(request?.usageOrigin?.threadId).assertEqual(saved.id);
      expect(request?.usageOrigin?.turnId).assertEqual(saved.messages[0].id);
      expect(conversation?.usageOrigin?.turnId).assertEqual(saved.messages[0].id);
      expect(request?.model).assertEqual('model'); expect(request?.reasoning).assertEqual('high');
      expect(request?.tools.length).assertEqual(0); expect(request?.messages.length).assertEqual(2);
      expect(request?.maxOutputTokens === undefined).assertTrue();
      f.session.setDraft('继续'); await f.session.send();
      expect(f.provider.requests.filter((item) => isTitleRequest(item)).length).assertEqual(1);
      const restored = new Fixture(await f.repository.load()); await restored.session.initialize();
      expect(active(restored.session.snapshot()).title).assertEqual('登录故障排查');
    });
    it('keepsForegroundModelRunningWhenTitleGenerationFails', 0, async () => {
      const f = new Fixture(titleSeed()); await f.session.initialize();
      const release = new Gate(); const entered = new Gate();
      f.provider.respond = async (index) => {
        if (isTitleRequest(f.provider.requests[index])) { throw new Error('title offline'); }
        entered.open(); await release.promise; return reply('answer survived');
      };
      f.session.setDraft('hello'); const sending = f.session.send(); await entered.promise; await settleTitles();
      expect(f.session.state.phase).assertEqual('running'); expect(f.session.state.error).assertEqual('');
      release.open(); await sending; await settleTitles();
      expect(active(f.session.snapshot()).title).assertEqual('hello');
      expect(active(f.session.snapshot()).messages[1].status).assertEqual('complete');
      expect(f.resources.errors.some((item) => item.includes('title offline'))).assertTrue();
    });
    it('discardsLateTitlesAfterManualRenameArchiveOrDeletion', 0, async () => {
      for (const action of ['rename', 'archive', 'delete']) {
        const f = new Fixture(titleSeed()); await f.session.initialize(); const release = new Gate();
        f.provider.respond = async (index) => {
          if (!isTitleRequest(f.provider.requests[index])) { return reply(); }
          await release.promise; return reply('late title');
        };
        f.session.setDraft('hello'); await f.session.send();
        if (action === 'rename') { await f.session.renameThread('thread-1', 'Manual'); }
        if (action === 'archive') { await f.session.archiveThread('thread-1'); }
        if (action === 'delete') { await f.session.deleteThread('thread-1'); }
        release.open(); await settleTitles();
        const thread = (await f.repository.load()).threads.find((item) => item.id === 'thread-1');
        expect(thread?.title === 'late title').assertFalse();
        if (action === 'rename') { expect(thread?.title).assertEqual('Manual'); }
        if (action === 'delete') { expect(thread === undefined).assertTrue(); }
      }
    });
    it('mergesLateTitlesAfterSettingsCommitsAndPreservesTypingDuringTitleSave', 0, async () => {
      const f = new Fixture(titleSeed()); await f.session.initialize(); const release = new Gate();
      f.provider.respond = async (index) => {
        if (!isTitleRequest(f.provider.requests[index])) { return reply(); }
        await release.promise; return reply('generated title');
      };
      f.session.setDraft('hello'); await f.session.send();
      const enteredSettings = new Gate(); const releaseSettings = new Gate();
      const enteredTitle = new Gate(); const releaseTitle = new Gate(); let blockedSettings = false;
      f.repository.beforeSave = async (snapshot) => {
        if (!blockedSettings) { blockedSettings = true; enteredSettings.open(); await releaseSettings.promise; }
        else if (active(snapshot).title === 'generated title') { enteredTitle.open(); await releaseTitle.promise; }
      };
      const saving = f.session.saveSettings('new instructions', false, false); await enteredSettings.promise;
      release.open(); await settleTitles();
      expect(active(f.session.snapshot()).title).assertEqual('hello');
      releaseSettings.open(); expect(await saving).assertTrue(); await enteredTitle.promise;
      f.session.setDraft('typed during title save'); releaseTitle.open(); await settleTitles();
      const saved = await f.repository.load();
      expect(saved.config.userDocument).assertEqual('new instructions');
      expect(active(saved).title).assertEqual('generated title');
      expect(active(saved).draft).assertEqual('typed during title save');
    });
    it('keepsFallbackAndChatUsableWhenGeneratedTitleCannotBeSaved', 0, async () => {
      const f = new Fixture(titleSeed()); await f.session.initialize(); const release = new Gate();
      f.provider.respond = async (index) => {
        if (!isTitleRequest(f.provider.requests[index])) { return reply(); }
        await release.promise; return reply('generated title');
      };
      f.session.setDraft('hello'); await f.session.send();
      f.repository.beforeSave = async (snapshot) => {
        if (active(snapshot).title === 'generated title') { throw new Error('title disk failure'); }
      };
      release.open(); await settleTitles();
      expect(active(f.session.snapshot()).title).assertEqual('hello');
      expect(active(await f.repository.load()).title).assertEqual('hello');
      expect(f.session.canMutate).assertTrue(); expect(f.session.state.saveError).assertEqual('');
      expect(f.resources.errors.some((item) => item.includes('title disk failure'))).assertTrue();
    });
    it('doesNotGenerateTitlesForManualOrExistingThreadsOrUnpersistedFirstTurns', 0, async () => {
      const manual = titleSeed(); manual.threads[0].titleEdited = true;
      for (const data of [manual, historySeed(), seed()]) {
        const f = new Fixture(data); await f.session.initialize();
        f.session.setDraft('hello'); await f.session.send(); await settleTitles();
        expect(f.provider.requests.some((item) => isTitleRequest(item))).assertFalse();
      }
      const failed = new Fixture(titleSeed()); await failed.session.initialize();
      failed.repository.beforeSave = async () => { throw new Error('disk failed'); };
      failed.session.setDraft('hello'); await failed.session.send(); await settleTitles();
      expect(failed.provider.requests.length).assertEqual(0);
    });
    it('persistsAutomaticContextAndResolvesModelThenServiceOverrides', 0, async () => {
      const f = new Fixture(); await f.session.initialize();
      const draft = providerDraft(); draft.models = 'model,deepseek-flash'; draft.contextWindow = '';
      expect(await f.session.saveProvider(draft)).assertTrue();
      expect(await f.session.selectModel('test', 'deepseek-flash')).assertTrue();
      expect(contextSettings(f.session.currentConfig).window).assertEqual(1000000);
      const extras = defaultProductivity(); const options = defaultAssistantOptions();
      options.capabilities = [{ providerId: 'test', modelId: 'deepseek-flash', images: true, reasoning: 'default', requestUsage: false }];
      extras.options = options;
      expect(await f.session.saveProductivity(extras)).assertTrue();
      draft.contextWindow = '65536';
      expect(await f.session.saveProvider(draft)).assertTrue();
      expect(contextSettings(f.session.currentConfig).window).assertEqual(65536);
      options.capabilities[0].contextWindow = 128000;
      expect(await f.session.saveProductivity(extras)).assertTrue();
      expect(contextSettings(f.session.currentConfig).window).assertEqual(128000);
      options.capabilities[0].contextWindow = undefined; draft.contextWindow = '';
      expect(await f.session.saveProductivity(extras)).assertTrue();
      expect(await f.session.saveProvider(draft)).assertTrue();
      const restored = new Fixture(await f.repository.load()); await restored.session.initialize();
      expect(contextSettings(restored.session.currentConfig).window).assertEqual(1000000);
      expect(await restored.session.selectModel('test', 'model')).assertTrue();
      expect(contextSettings(restored.session.currentConfig).window).assertEqual(200000);
    });
    it('reasoningSelectionPersistsAndReachesTheRequestAndResetsToModelDefaults', 0, async () => {
      const data = seed(); data.productivity = defaultProductivity();
      const options = defaultAssistantOptions(); options.autoMemory = false;
      options.capabilities = [{ providerId: 'test', modelId: 'model', images: true, reasoning: 'medium', contextWindow: 32768, requestUsage: false }];
      data.productivity.options = options;
      const f = new Fixture(data); await f.session.initialize();
      expect(await f.session.setReasoningEffort('high')).assertTrue();
      const restored = new Fixture(await f.repository.load()); await restored.session.initialize();
      expect(active(restored.session.snapshot()).reasoningEffort).assertEqual('high');
      restored.session.setDraft('hello'); await restored.session.send();
      expect(restored.provider.requests[0].reasoning).assertEqual('high');
      expect(await restored.session.setReasoningEffort('default')).assertTrue();
      expect(active(restored.session.snapshot()).reasoningEffort === undefined).assertTrue();
      restored.session.setDraft('hello again'); await restored.session.send();
      expect(restored.provider.requests[1].reasoning).assertEqual('medium');
    });
    it('anthropicEffortAndSignedHistorySurviveRuntimeAndRestart', 0, async () => {
      const data = seed(); const profile = (data.providerProfiles || [])[0];
      profile.protocol = 'anthropic-messages'; profile.models = ['claude-opus-4-6'];
      data.threads[0].modelRef = { providerId: 'test', modelId: 'claude-opus-4-6' };
      data.config.model = 'claude-opus-4-6';
      const f = new Fixture(data); await f.session.initialize();
      expect(await f.session.setReasoningEffort('max')).assertTrue();
      expect(await f.session.setReasoningEffort('none')).assertFalse();
      f.provider.respond = async (): Promise<ModelTurn> => {
        return { content: 'answer', toolCalls: [], reasoningContent: 'thought', anthropicContent: [
          { type: 'thinking', thinking: 'thought', signature: 'opaque-signature' },
          { type: 'text', text: 'answer' }
        ] };
      };
      f.session.setDraft('hello'); await f.session.send();
      expect(f.provider.requests[0].reasoning).assertEqual('max');
      const restored = new Fixture(await f.repository.load()); await restored.session.initialize();
      expect(restored.session.currentConfig.reasoning).assertEqual('max');
      restored.session.setDraft('continue'); await restored.session.send();
      const answer = restored.provider.requests[0].messages.find((message) => message.role === 'assistant');
      expect(answer?.anthropicContent?.[0].signature).assertEqual('opaque-signature');
    });
    it('reasoningSelectionIsScopedToTheThreadAndSelectedModel', 0, async () => {
      const data = seed(); (data.providerProfiles || [])[0].models.push('another');
      const f = new Fixture(data); await f.session.initialize();
      await f.session.setReasoningEffort('low');
      await f.session.selectModel('test', 'model');
      expect(f.session.currentConfig.reasoning).assertEqual('low');
      await f.session.newThread();
      expect(active(f.session.snapshot()).reasoningEffort).assertEqual('low');
      await f.session.selectThread('thread-1');
      expect(f.session.currentConfig.reasoning).assertEqual('low');
      await f.session.selectModel('test', 'another');
      expect(active(f.session.snapshot()).reasoningEffort === undefined).assertTrue();
    });
    it('reasoningSelectionRejectsUnsupportedValuesAndRollsBackFailedWrites', 0, async () => {
      const f = new Fixture(); await f.session.initialize();
      expect(await f.session.setReasoningEffort('invalid')).assertFalse();
      await f.session.setReasoningEffort('low');
      f.repository.beforeSave = async () => { throw new Error('disk failed'); };
      expect(await f.session.setReasoningEffort('high')).assertFalse();
      expect(f.session.currentConfig.reasoning).assertEqual('low');
      expect(active(await f.repository.load()).reasoningEffort).assertEqual('low');
      const unsupported = seed(); (unsupported.providerProfiles || [])[0].protocol = 'anthropic-messages';
      (unsupported.providerProfiles || [])[0].models = ['claude-haiku-4-5'];
      unsupported.threads[0].modelRef = { providerId: 'test', modelId: 'claude-haiku-4-5' };
      unsupported.config.model = 'claude-haiku-4-5';
      const other = new Fixture(unsupported); await other.session.initialize();
      expect(await other.session.setReasoningEffort('high')).assertFalse();
      const broken = seed(); broken.threads[0].reasoningEffort = 'invalid';
      let rejected = false;
      try { parseAppData(JSON.stringify(broken)); } catch (_) { rejected = true; }
      expect(rejected).assertTrue();
    });
    it('emptyChatsShareUnsentSelectionsAcrossRestartWithoutLosingDrafts', 0, async () => {
      const data = seed(); (data.providerProfiles || [])[0].models.push('another');
      const f = new Fixture(data); await f.session.initialize();
      f.session.setDraft('keep this draft'); await f.session.flushDraft();
      await f.session.newThread();
      expect(await f.session.selectModel('test', 'another')).assertTrue();
      expect(await f.session.setReasoningEffort('max')).assertTrue();
      expect(f.provider.requests.length).assertEqual(0);
      const saved = await f.repository.load();
      expect(saved.config.model).assertEqual('another'); expect(saved.config.reasoning).assertEqual('max');
      const restored = new Fixture(saved); restored.resources.ids = 1000; await restored.session.initialize();
      await restored.session.selectThread('thread-1');
      expect(restored.session.currentConfig.model).assertEqual('another');
      expect(restored.session.currentConfig.reasoning).assertEqual('max');
      expect(active(restored.session.snapshot()).draft).assertEqual('keep this draft');
      await restored.session.newThread();
      expect(restored.session.currentConfig.model).assertEqual('another');
      expect(restored.session.currentConfig.reasoning).assertEqual('max');
      // Re-selecting the same model preserves effort; changing providers resets it.
      await restored.session.selectModel('test', 'another');
      expect(restored.session.currentConfig.reasoning).assertEqual('max');
      const draft = providerDraft(); draft.id = ''; draft.name = 'Second'; draft.models = 'another';
      await restored.session.saveProvider(draft);
      const second = (restored.session.snapshot().providerProfiles || []).find((item) => item.id !== 'test');
      expect(second !== undefined).assertTrue();
      await restored.session.selectModel(second!.id, 'another');
      expect(restored.session.snapshot().config.providerId).assertEqual(second!.id);
      expect(restored.session.snapshot().config.reasoning === undefined).assertTrue();
      await restored.session.setReasoningEffort('high'); await restored.session.newThread();
      expect(restored.session.currentConfig.providerId).assertEqual(second!.id);
      expect(restored.session.currentConfig.reasoning).assertEqual('high');
    });
    it('usedChatsKeepTheirSelectionAndNeverChangeNewChatPreferences', 0, async () => {
      const data = seed(); (data.providerProfiles || [])[0].models.push('another');
      const f = new Fixture(data); await f.session.initialize();
      await f.session.setReasoningEffort('high'); f.session.setDraft('first'); await f.session.send();
      expect(f.provider.requests[0].reasoning).assertEqual('high');
      await f.session.newThread();
      await f.session.selectModel('test', 'another'); await f.session.setReasoningEffort('max');
      await f.session.selectThread('thread-1');
      expect(f.session.currentConfig.model).assertEqual('model'); expect(f.session.currentConfig.reasoning).assertEqual('high');
      await f.session.setReasoningEffort('low'); f.session.setDraft('second'); await f.session.send();
      expect(f.provider.requests[1].model).assertEqual('model'); expect(f.provider.requests[1].reasoning).assertEqual('low');
      // A failed request in the old chat still must not change the new-chat defaults.
      await f.session.selectModel('test', 'another'); await f.session.setReasoningEffort('medium');
      f.provider.respond = async () => { throw new Error('request failed'); };
      f.session.setDraft('third'); await f.session.send();
      expect(active(f.session.snapshot()).messages[5].status).assertEqual('failed');
      expect(active(f.session.snapshot()).messages[5].error).assertEqual('request failed');
      const saved = await f.repository.load();
      expect(saved.config.model).assertEqual('another'); expect(saved.config.reasoning).assertEqual('max');
      const restored = new Fixture(saved); restored.resources.ids = 1000; await restored.session.initialize();
      expect(restored.session.currentConfig.reasoning).assertEqual('medium');
      await restored.session.newThread(); expect(restored.session.currentConfig.reasoning).assertEqual('max');
      await restored.session.selectModel('test', 'model');
      expect(restored.session.currentConfig.reasoning === undefined).assertTrue();
      await restored.session.selectThread('thread-1');
      expect(restored.session.currentConfig.model).assertEqual('another'); expect(restored.session.currentConfig.reasoning).assertEqual('medium');
    });
    it('emptyPreferenceWritesRollbackTogetherAndProviderEditsPreserveEffort', 0, async () => {
      const data = seed(); (data.providerProfiles || [])[0].models.push('another');
      const f = new Fixture(data); await f.session.initialize(); await f.session.setReasoningEffort('high');
      await f.session.newThread();
      f.repository.beforeSave = async () => { throw new Error('disk failed'); };
      expect(await f.session.setReasoningEffort('low')).assertFalse();
      expect(await f.session.selectModel('test', 'another')).assertFalse();
      expect(f.session.snapshot().config.model).assertEqual('model'); expect(f.session.snapshot().config.reasoning).assertEqual('high');
      expect(f.session.snapshot().threads.every((thread) => thread.modelRef?.modelId === 'model' && thread.reasoningEffort === 'high')).assertTrue();
      expect((await f.repository.load()).config.reasoning).assertEqual('high');
      f.repository.beforeSave = async () => {};
      expect(await f.session.saveProvider(providerDraft())).assertTrue();
      await f.session.newThread(); expect(f.session.currentConfig.reasoning).assertEqual('high');
      await f.session.setReasoningEffort('default');
      expect((await f.repository.load()).config.reasoning === undefined).assertTrue();
      expect(f.session.snapshot().threads.every((thread) => thread.reasoningEffort === undefined)).assertTrue();
    });
    it('initializationSyncsLegacyEmptyChatsButPreservesUsedChats', 0, async () => {
      const data = historySeed(); (data.providerProfiles || [])[0].models.push('another');
      data.threads[0].reasoningEffort = 'high';
      data.threads.push({ id: 'empty', title: 'Draft', updatedAt: 2, messages: [], draft: 'unsent',
        modelRef: { providerId: 'test', modelId: 'another' }, reasoningEffort: 'max' });
      const f = new Fixture(data); await f.session.initialize();
      expect(f.session.currentConfig.reasoning).assertEqual('high');
      await f.session.selectThread('empty');
      expect(f.session.currentConfig.model).assertEqual('model');
      expect(active(f.session.snapshot()).reasoningEffort === undefined).assertTrue();
      expect(active(f.session.snapshot()).draft).assertEqual('unsent');
      const corrupt = seed(); corrupt.config.reasoning = 'invalid';
      let rejected = false; try { parseAppData(JSON.stringify(corrupt)); } catch (_) { rejected = true; }
      expect(rejected).assertTrue();
    });
    it('reasoningOverrideDoesNotLeakToAutomaticallyRoutedModels', 0, async () => {
      const data = seed(); (data.providerProfiles || [])[0].models.push('another');
      data.productivity = defaultProductivity();
      const options = defaultAssistantOptions(); options.autoRoute = true;
      options.fast = { providerId: 'test', modelId: 'another' };
      options.capabilities = [{ providerId: 'test', modelId: 'another', reasoning: 'low', images: true, requestUsage: false, contextWindow: 32768 }];
      data.productivity.options = options;
      const f = new Fixture(data); await f.session.initialize();
      await f.session.setReasoningEffort('high'); f.session.setDraft('hello'); await f.session.send();
      expect(f.provider.requests[0].model).assertEqual('another');
      expect(f.provider.requests[0].reasoning).assertEqual('low');
    });
    it('compactSlashCommandSummarizesWithoutCreatingAMessage', 0, async () => {
      const f = new Fixture(historySeed()); await f.session.initialize();
      f.provider.respond = async () => reply('short summary');
      f.session.setDraft(' /compact '); await f.session.send();
      expect(active(f.session.snapshot()).messages.length).assertEqual(8);
      expect(active(f.session.snapshot()).compaction?.summary).assertEqual('short summary');
      expect(active(await f.repository.load()).draft).assertEqual('');
      expect(f.provider.requests[0].messages.some((message) => message.content === '/compact')).assertFalse();
    });
    it('compactKeepsFailedCommandAndRejectsQueueAndArguments', 0, async () => {
      const f = new Fixture(); await f.session.initialize();
      f.session.setDraft('/compact'); await f.session.enqueueInput('followUp');
      expect((active(f.session.snapshot()).pendingInputs || []).length).assertEqual(0);
      await f.session.send(); expect(active(f.session.snapshot()).draft).assertEqual('/compact');
      expect(f.session.state.error.length > 0).assertTrue(); expect(f.provider.requests.length).assertEqual(0);
      f.session.setDraft('/compact later'); await f.session.send();
      expect(active(f.session.snapshot()).messages.length).assertEqual(0); expect(f.provider.requests.length).assertEqual(0);
    });
    it('compactPreservesDraftTypedWhileSummaryIsRunning', 0, async () => {
      const f = new Fixture(historySeed()); await f.session.initialize();
      f.provider.respond = async () => { f.session.setDraft('next task'); return reply('short summary'); };
      f.session.setDraft('/compact'); await f.session.send();
      expect(active(f.session.snapshot()).draft).assertEqual('next task');
    });
    it('referencesPersistAcrossSwitchAndDeletionAndReachModelAsUserContext', 0, async () => {
      const data = seed(); const source = historySeed().threads[0]; source.id = 'source'; source.title = 'Reference source';
      source.messages[7].content = 'unique source answer'; data.threads.push(source);
      const f = new Fixture(data); await f.session.initialize();
      f.session.setDraft('compare @Reference'); expect(await f.session.referenceThread('source')).assertTrue();
      expect(active(f.session.snapshot()).draft).assertEqual('compare ');
      expect(await f.session.referenceThread('source')).assertFalse();
      await f.session.selectThread('source'); await f.session.selectThread('thread-1');
      expect((active(await f.repository.load()).references || []).length).assertEqual(1);
      await f.session.deleteThread('source'); await f.session.send();
      expect(f.provider.requests[0].messages.some((message) => message.role === 'user' && message.content.includes('unique source answer'))).assertTrue();
      expect(f.provider.requests[0].messages.filter((message) => message.role === 'system').some((message) => message.content.includes('unique source answer'))).assertFalse();
      expect((active(f.session.snapshot()).references || []).length).assertEqual(0);
      const user = active(f.session.snapshot()).messages[0]; expect((user.references || []).length).assertEqual(1);
      await f.session.restoreMessageDraft(user.id); expect((active(f.session.snapshot()).references || []).length).assertEqual(1);
      await f.session.enqueueInput('followUp'); expect((active(f.session.snapshot()).pendingInputs || []).length).assertEqual(0);
      expect(await f.session.removeThreadReference('source')).assertTrue();
      expect((active(await f.repository.load()).references || []).length).assertEqual(0);
    });
    it('slashTeamEnablesModeWithoutCallingModelUntilThereIsATask', 0, async () => {
      const f = new Fixture(); await f.session.initialize(); f.session.setDraft('/team'); await f.session.send();
      expect(f.provider.requests.length).assertEqual(0); expect(active(await f.repository.load()).teamEnabled).assertTrue();
      expect(active(f.session.snapshot()).draft).assertEqual('');
      f.session.setDraft('简单回答即可'); await f.session.send();
      expect(f.provider.requests[0].tools.some((tool) => tool.function.name === 'team_recruit')).assertTrue();
      expect(await f.session.setTeamEnabled(false)).assertTrue(); f.session.setDraft('普通模式'); await f.session.send();
      expect(f.provider.requests[1].tools.some((tool) => tool.function.name === 'team_recruit')).assertFalse();
    });
    it('chatCoordinatorRecruitsAndIntegratesWithoutManualPlanOrSecondTurn', 0, async () => {
      const f = new Fixture(); await f.session.initialize(); let parentRequests = 0;
      const teams: SessionEvent[] = []; const metadata: SessionEvent[] = [];
      f.session.subscribe((event: SessionEvent) => {
        if (event.kind === 'teams') { teams.push(event); }
        if (event.kind === 'thread') { metadata.push(event); }
      });
      f.provider.respond = async (index) => {
        const request = f.provider.requests[index];
        if (request.tools.some((tool) => tool.function.name === 'team_complete_task')) {
          expect(request.tools.some((tool) => tool.function.name === 'team_recruit')).assertFalse();
          if (request.messages.some((message) => message.role === 'tool')) { return reply('内部草稿'); }
          return { content: '', toolCalls: [{ id: 'handoff', type: 'function', function: { name: 'team_complete_task', arguments: '{"summary":"研究证据已整理","unresolved":[],"artifacts":[]}' } }] };
        }
        parentRequests++;
        if (parentRequests === 1) { return { content: '我来招募研究员。', toolCalls: [{ id: 'recruit', type: 'function', function: { name: 'team_recruit', arguments: '{"goal":"研究","members":[{"id":"researcher","displayName":"研究员","instructions":"查证"}],"tasks":[{"id":"facts","title":"整理证据","memberId":"researcher","instructions":"整理后交接","dependencies":[]}]}' } }] }; }
        // The finish guard must turn a premature answer into integration inside this same turn.
        if (parentRequests === 2) { return reply('正在等待。'); }
        expect(JSON.stringify(request.messages).includes('研究证据已整理')).assertTrue(); return reply('根据员工证据，最终结论如下。');
      };
      f.session.setDraft('/team 请招募员工研究'); await f.session.send();
      const thread = active(f.session.snapshot());
      expect(thread.messages.length).assertEqual(2); expect(thread.messages[0].content).assertEqual('请招募员工研究');
      expect(thread.messages[1].status).assertEqual('complete'); expect(thread.messages[1].content.includes('最终结论')).assertTrue();
      expect(thread.teams![0].status).assertEqual('completed'); expect(thread.teams![0].ownerMessageId).assertEqual(thread.messages[1].id);
      expect(active(await f.repository.load()).teams![0].tasks[0].attempts[0].handoff?.summary).assertEqual('研究证据已整理');
      expect(teams.length > 0).assertTrue(); expect(metadata.length > 0).assertTrue();
      expect(teams.every((event) => event.data === undefined && event.thread === undefined)).assertTrue();
      expect(metadata.every((event) => event.data === undefined && event.thread?.messages.length === 0 && event.thread.teams === undefined)).assertTrue();
      teams[teams.length - 1].teams![0].goal = 'observer edit';
      expect(active(f.session.snapshot()).teams![0].goal === 'observer edit').assertFalse();
    });
    it('memoryProposalDoesNotSaveOrCopyLongAnswersAndIncludesRoleEvidence', 0, async () => {
      const data = seed(); const thread = data.threads[0]; thread.draft = 'keep draft';
      thread.messages = [{ id: 'u', role: 'user', content: '我偏好中文和简短回答', status: 'complete', error: '' },
        { id: 'a', role: 'assistant', content: '回复内容'.repeat(800), status: 'complete', error: '' }];
      data.productivity = defaultProductivity(); data.productivity.memories = [{ id: 'existing', content: '偏好中文', threadId: '', updatedAt: 1 }];
      const f = new Fixture(data); await f.session.initialize(); const before = JSON.stringify(f.session.snapshot()); const writes = f.repository.writes.length;
      f.provider.respond = async () => reply('[" 偏好中文 ","偏好简短回答","偏好简短回答"]');
      const proposed = await f.session.proposeMemory('a'); expect(proposed.join(',')).assertEqual('偏好简短回答');
      expect(f.provider.requests[0].messages[1].content.includes('precedingUserMessage')).assertTrue();
      expect(f.provider.requests[0].messages[1].content.includes('assistant')).assertTrue();
      expect(JSON.stringify(f.session.snapshot())).assertEqual(before); expect(f.repository.writes.length).assertEqual(writes); expect(f.session.state.phase).assertEqual('idle');
      expect(await f.session.saveMemoryDraft('thread-1', 'a', ['偏好简短回答'], false)).assertEqual(1);
      const saved = await f.repository.load(); const memory = saved.productivity?.memories[1];
      expect(memory?.threadId).assertEqual('thread-1'); expect(memory?.sourceMessageId).assertEqual('a'); expect(memory?.automatic).assertFalse();
      expect(active(saved).draft).assertEqual('keep draft'); expect(active(saved).messages.length).assertEqual(2);
      expect(await f.session.saveMemoryDraft('thread-1', 'a', ['偏好简短回答'], false)).assertEqual(0);
    });
    it('emptyOrInvalidMemorySuggestionsNeverFallBackToTheSourceText', 0, async () => {
      const f = new Fixture(historySeed()); await f.session.initialize(); const before = f.repository.saved;
      f.provider.respond = async () => reply('[]'); expect((await f.session.proposeMemory('answer-0')).length).assertEqual(0);
      for (const output of ['not json', '["' + 'x'.repeat(201) + '"]', '[""]']) {
        f.provider.respond = async () => reply(output); let rejected = false;
        try { await f.session.proposeMemory('answer-0'); } catch (_) { rejected = true; }
        expect(rejected).assertTrue(); expect(f.session.state.phase).assertEqual('idle');
      }
      expect(f.repository.saved).assertEqual(before);
    });
    it('cancelsMemoryProposalWithoutSavingOrChangingConversationQueue', 0, async () => {
      const f = new Fixture(historySeed()); await f.session.initialize(); const before = JSON.stringify(f.session.snapshot()); const entered = new Gate();
      f.provider.respond = async (_index, signal) => { entered.open(); await new Promise<void>((resolve) => signal.onCancel(resolve)); signal.check(); return reply('[]'); };
      const proposal = f.session.proposeMemory('answer-0'); await entered.promise;
      expect(f.session.canQueueInput).assertFalse(); f.session.cancelMemoryDraft(); let cancelled = false;
      try { await proposal; } catch (_) { cancelled = true; }
      expect(cancelled).assertTrue(); expect(JSON.stringify(f.session.snapshot())).assertEqual(before); expect(f.session.state.phase).assertEqual('idle');
    });
    it('confirmedMemorySaveIsAtomicAndChecksScopeAndSource', 0, async () => {
      const f = new Fixture(historySeed()); await f.session.initialize(); const before = JSON.stringify(f.session.snapshot());
      f.repository.beforeSave = async () => { throw new Error('disk failed'); }; let rejected = false;
      try { await f.session.saveMemoryDraft('thread-1', 'answer-0', ['short fact'], true); } catch (_) { rejected = true; }
      expect(rejected).assertTrue(); expect(JSON.stringify(f.session.snapshot())).assertEqual(before);
      f.repository.beforeSave = async () => {}; expect(await f.session.saveMemoryDraft('thread-1', 'answer-0', ['short fact'], true)).assertEqual(1);
      expect(f.session.snapshot().productivity?.memories[0].threadId).assertEqual('');
      expect(await f.session.saveMemoryDraft('thread-1', 'answer-0', [' short   fact '], false)).assertEqual(0);
      rejected = false; try { await f.session.saveMemoryDraft('thread-1', 'deleted', ['fact'], false); } catch (_) { rejected = true; }
      expect(rejected).assertTrue(); expect(f.session.snapshot().productivity?.memories.length).assertEqual(1);
    });
    it('resumesInterruptedFormWithoutReplayingWritesOrConsumingDraftAndWaitsThroughContinuation', 0, async () => {
      const data = seed(); const thread = data.threads[0]; thread.draft = 'unsent draft';
      const definition: InputForm = { title: 'Choose', fields: [{ name: 'choice', label: 'Choice', type: 'text', required: true }] };
      const form: ToolCall = { id: 'ask', type: 'function', function: { name: 'request_user_input', arguments: JSON.stringify({ data: JSON.stringify(definition) }) } };
      const write: ToolCall = { id: 'write', type: 'function', function: { name: 'write_file', arguments: '{"path":"a.txt","content":"saved"}' } };
      thread.messages = [{ id: 'u', role: 'user', content: 'task', status: 'complete', error: '' },
        { id: 'a', role: 'assistant', content: '', status: 'stopped', error: '', steps: [{ content: '', tools: [
          { call: write, status: 'complete', output: 'saved' }, { call: form, status: 'interrupted', output: '' }] }] }];
      const f = new Fixture(data); const approval = new ToolApproval(); f.resources.agentTools = new InteractionTools(approval); await f.session.initialize();
      const entered = new Gate(); const release = new Gate(); f.provider.respond = async () => { entered.open(); await release.promise; return reply('continued'); };
      const resume = f.session.resumeForm('a', 'ask'); let idle = false; const waiting = f.session.waitForIdle().then(() => { idle = true; });
      approval.submit(['yes']); await entered.promise; expect(idle).assertFalse();
      expect(f.provider.requests[0].messages.some((item) => item.toolCallId === 'ask' && item.content.includes('yes'))).assertTrue();
      release.open(); await resume; await waiting; const saved = await f.repository.load();
      expect(active(saved).draft).assertEqual('unsent draft'); expect(active(saved).messages[1].steps?.[0].tools[0].output).assertEqual('saved');
      expect(active(saved).messages[1].steps?.[0].tools[1].status).assertEqual('complete'); expect(active(saved).messages[3].content).assertEqual('continued');
    });
    it('memoryToolSavesWithUserProvenanceAndPreservesManualFacts', 0, async () => {
      const data = seed(); data.productivity = defaultProductivity();
      data.productivity.memories = [{ id: 'manual', content: '用户偏好中文', threadId: '', updatedAt: 1 }];
      const f = new Fixture(data); await f.session.initialize();
      f.provider.respond = async (index) => index === 0 ? { content: '', toolCalls: [{ id: 'remember', type: 'function', function: {
        name: 'memory', arguments: JSON.stringify({ operations: JSON.stringify([
          { action: 'add', scope: 'global', content: '用户偏好中文' }, { action: 'add', scope: 'global', content: '用户喜欢简短回答' }
        ]) }) } }] } : reply('已保存');
      f.session.setDraft('请记住我喜欢简短回答'); await f.session.send();
      expect(f.provider.requests.length).assertEqual(2);
      expect(f.provider.requests[1].messages.some((message) => message.role === 'tool' && message.content.includes('"duplicates":1'))).assertTrue();
      const saved = parseAppData(f.repository.saved); expect(saved.productivity?.memories.length).assertEqual(2);
      expect(saved.productivity?.memories[0].id).assertEqual('manual'); expect(saved.productivity?.memories[1].automatic).assertTrue();
      expect(saved.productivity?.memories[1].sourceMessageId).assertEqual(saved.threads[0].messages[0].id);
    });
    it('failedTurnsDoNotTriggerAutomaticMemory', 0, async () => {
      const data = seed(); data.productivity = defaultProductivity(); data.productivity.options = defaultAssistantOptions(); data.productivity.options.autoMemory = true;
      const f = new Fixture(data); await f.session.initialize(); f.provider.respond = async () => { throw new Error('offline'); };
      f.session.setDraft('fact'); await f.session.send(); expect(f.provider.requests.length).assertEqual(1); expect(f.session.snapshot().productivity?.memories.length).assertEqual(0);
    });
    it('routingRecordsPhysicalModelWithoutChangingConversationChoice', 0, async () => {
      const data = seed(); data.productivity = defaultProductivity(); data.productivity.options = defaultAssistantOptions(); data.productivity.options.autoRoute = true;
      data.productivity.options.deep = { providerId: 'test', modelId: 'deep' }; data.providerProfiles?.[0].models.push('deep');
      const f = new Fixture(data); await f.session.initialize(); f.session.setDraft('详细分析这个问题'); await f.session.send();
      expect(f.provider.requests[0].model).assertEqual('deep'); expect(active(f.session.snapshot()).modelRef?.modelId).assertEqual('model');
      expect(active(f.session.snapshot()).messages[1].modelRef?.modelId).assertEqual('deep');
    });
    it('sendsAttachmentsWithoutTextAndRetainsThemForHistory', 0, async () => {
      const f = new Fixture(); await f.session.initialize();
      const attachment: Attachment = { id: 'photo', name: 'photo', path: 'photo.jpg', mime: 'image/jpeg', size: 12 };
      expect(await f.session.setAttachments([attachment])).assertTrue();
      await f.session.send();
      expect(f.provider.requests.length).assertEqual(1);
      expect(f.provider.requests[0].messages[1].attachments?.[0].id).assertEqual('photo');
      expect(active(f.session.snapshot()).attachments?.length).assertEqual(0);
      expect(active(f.session.snapshot()).messages[0].attachments?.length).assertEqual(1);
      const restored = parseAppData(f.repository.saved);
      expect(active(restored).messages[0].attachments?.[0].path).assertEqual('photo.jpg');
    });
    it('readsLargeComposerAttachmentsInNormalAndTeamChats', 0, async () => {
      for (const team of [false, true]) {
        const data = seed(); data.threads[0].teamEnabled = team;
        const f = new Fixture(data); await f.session.initialize();
        const text = 'x'.repeat(70000) + '\nATTACHMENT-END';
        const attachment: Attachment = { id: 'large', name: 'large.txt', path: 'large.txt', mime: 'text/plain', size: text.length, text: text };
        expect(await f.session.setAttachments([attachment])).assertTrue();
        f.provider.respond = async (index) => index === 0 ? { content: '', toolCalls: [{ id: 'read-large', type: 'function',
          function: { name: 'read_attachment', arguments: JSON.stringify({ id: 'large', offset: 2 }) } }] } : reply('Read the end.');
        f.session.setDraft('Read the last line of the attachment.'); await f.session.send();
        expect(f.provider.requests.length).assertEqual(2);
        expect(f.provider.requests[0].tools.some((tool) => tool.function.name === 'read_attachment')).assertTrue();
        expect(f.provider.requests[1].messages.some((message) => message.role === 'tool' && message.content.includes('ATTACHMENT-END'))).assertTrue();
        expect(active(await f.repository.load()).messages[0].attachments?.[0].text).assertEqual(text);
      }
    });
    it('forksBeforeSelectedUserAndPreservesOriginalAndDraftAttachment', 0, async () => {
      const data = historySeed();
      data.threads[0].messages[2].attachments = [{ id: 'photo', name: 'photo', path: 'photo.jpg', mime: 'image/jpeg', size: 12 }];
      const f = new Fixture(data); await f.session.initialize();
      expect(await f.session.forkThread('user-1')).assertTrue();
      const snapshot = f.session.snapshot(); const branch = active(snapshot);
      expect(branch.parentThreadId).assertEqual('thread-1'); expect(branch.messages.length).assertEqual(2);
      expect(branch.draft).assertEqual(data.threads[0].messages[2].content);
      expect(branch.attachments?.[0].id).assertEqual('photo');
      expect(snapshot.threads.find((item) => item.id === 'thread-1')?.messages.length).assertEqual(8);
      parseAppData(f.repository.saved);
    });
    it('regeneratesSelectedAnswerOnANewBranchWithAttachmentsAndReferences', 0, async () => {
      const data = historySeed(); const original = data.threads[0];
      data.productivity = defaultProductivity(); data.productivity.options = defaultAssistantOptions();
      data.productivity.options.autoMemory = false; data.productivity.options.readOnly = true;
      original.draft = 'unfinished next question'; original.reasoningEffort = 'high'; original.disabledMcpIds = ['offline'];
      original.messages[2].attachments = [{ id: 'note', name: 'note.txt', path: 'note.txt', mime: 'text/plain', size: 4, text: 'note' }];
      original.messages[2].references = [{ threadId: 'reference', title: 'Reference', content: 'saved reference context', capturedAt: 1, truncated: false }];
      const f = new Fixture(data); await f.session.initialize();
      expect(await f.session.regenerateReply('answer-1')).assertTrue();
      const snapshot = f.session.snapshot(); const branch = active(snapshot);
      expect(JSON.stringify(snapshot.productivity?.options)).assertEqual(JSON.stringify(data.productivity.options));
      expect(branch.id === original.id).assertFalse(); expect(branch.parentMessageId).assertEqual('user-1');
      expect(branch.messages.length).assertEqual(4); expect(branch.reasoningEffort).assertEqual('high');
      expect(branch.disabledMcpIds?.[0]).assertEqual('offline');
      expect(branch.messages[2].attachments?.[0].text).assertEqual('note');
      expect(branch.messages[2].references?.[0].content).assertEqual('saved reference context');
      expect(f.provider.requests.length).assertEqual(1);
      expect(JSON.stringify(f.provider.requests[0].messages).includes('saved reference context')).assertTrue();
      const preserved = snapshot.threads.find((item) => item.id === original.id) as ThreadData;
      expect(JSON.stringify(preserved.messages)).assertEqual(JSON.stringify(original.messages));
      expect(preserved.draft).assertEqual('unfinished next question'); parseAppData(f.repository.saved);
    });
    it('doesNotRegenerateWhenBranchCannotBeSavedOrTheTargetIsInvalid', 0, async () => {
      const f = new Fixture(historySeed()); await f.session.initialize();
      expect(await f.session.regenerateReply('user-1')).assertFalse();
      expect(await f.session.regenerateReply('missing')).assertFalse();
      expect(f.session.snapshot().threads.length).assertEqual(1);
      f.repository.beforeSave = async () => { throw new Error('disk full'); };
      expect(await f.session.regenerateReply('answer-1')).assertFalse();
      expect(f.provider.requests.length).assertEqual(0);
      expect(f.session.snapshot().threads.find((item) => item.id === 'thread-1')?.messages.length).assertEqual(8);
    });
    it('rejectsRepeatedRegenerationWhileOneBranchIsSaving', 0, async () => {
      const f = new Fixture(historySeed()); await f.session.initialize();
      const gate = new Gate(); f.repository.beforeSave = async () => { await gate.promise; };
      const first = f.session.regenerateReply('answer-1');
      expect(await f.session.regenerateReply('answer-1')).assertFalse(); gate.open(); await first;
      expect(f.provider.requests.length).assertEqual(1); expect(f.session.snapshot().threads.length).assertEqual(2);
    });
    it('injectsOnlyApplicableMemoryIntoTheNextModelRequest', 0, async () => {
      const f = new Fixture(); await f.session.initialize(); const data = defaultProductivity();
      data.memories = [{ id: 'g', content: 'global fact', threadId: '', updatedAt: 1 },
        { id: 'p', content: 'other secret', threadId: 'other', updatedAt: 1 }];
      expect(await f.session.saveProductivity(data)).assertTrue();
      f.session.setDraft('hello'); await f.session.send();
      expect(f.provider.requests[0].messages[0].content.includes('global fact')).assertTrue();
      expect(f.provider.requests[0].messages[0].content.includes('other secret')).assertFalse();
    });
    it('keepsAttachmentsOutOfTextOnlyQueueAndRetainsDraft', 0, async () => {
      const f = new Fixture(); await f.session.initialize();
      await f.session.setAttachments([{ id: 'photo', name: 'photo', path: 'photo.jpg', mime: 'image/jpeg', size: 12 }]);
      f.session.setDraft('image task'); await f.session.enqueueInput('followUp');
      expect(active(f.session.snapshot()).pendingInputs?.length).assertEqual(0);
      expect(active(f.session.snapshot()).draft).assertEqual('image task');
      expect(active(f.session.snapshot()).attachments?.length).assertEqual(1);
    });
    it('runsSteeringAndQueuedTasksThroughTheRealRuntimeWithoutUi', 0, async () => {
      const f = new Fixture(); await f.session.initialize();
      const entered = new Gate(); const release = new Gate();
      f.provider.respond = async (index: number) => { if (index === 0) { entered.open(); await release.promise; } return reply('answer-' + index); };
      f.session.setDraft('first'); const running = f.session.send(); await entered.promise;
      f.session.setDraft('steer'); await f.session.enqueueInput('steer');
      f.session.setDraft('second'); await f.session.enqueueInput('followUp');
      f.session.setDraft('third'); await f.session.enqueueInput('followUp');
      f.session.setDraft('unsent draft');
      expect(await f.session.newThread()).assertFalse();
      expect(await f.session.selectModel('test', 'model')).assertFalse();
      await f.session.send();
      release.open(); await running;
      expect(f.provider.requests.length).assertEqual(4);
      expect(f.provider.requests[1].messages.filter((item) => item.role === 'user').map((item) => item.content).join(',')).assertEqual('first,steer');
      const thread = active(f.session.snapshot());
      expect(thread.messages.filter((item) => item.role === 'user').map((item) => item.content).join(',')).assertEqual('first,second,third');
      expect(thread.messages[1].steps?.some((step) => step.steering?.text === 'steer')).assertTrue();
      expect(thread.pendingInputs?.length).assertEqual(0);
      expect(thread.draft).assertEqual('unsent draft');
      expect(active(await f.repository.load()).messages.length).assertEqual(6);
      expect(f.session.state.phase).assertEqual('idle');
    });

    it('waitsForTheWholeQueueAndFinalSaveBeforeReportingIdle', 0, async () => {
      const f = new Fixture(); await f.session.initialize();
      f.session.setDraft('first'); await f.session.enqueueInput('followUp');
      f.session.setDraft('second'); await f.session.enqueueInput('followUp');
      const saving = new Gate(); const saved = new Gate(); const second = new Gate(); const finish = new Gate();
      f.repository.beforeSave = async (data: AppData) => {
        const messages = active(data).messages;
        if (messages.length === 2 && messages[1].status === 'complete') { saving.open(); await saved.promise; }
      };
      f.provider.respond = async (index: number) => { if (index === 1) { second.open(); await finish.promise; } return reply(); };
      const running = f.session.resumeQueue(); await saving.promise;
      let idle = false; const waiting = f.session.waitForIdle().then(() => { idle = true; });
      expect(f.provider.requests.length).assertEqual(1); expect(idle).assertFalse();
      expect(await f.session.newThread()).assertFalse();
      saved.open(); await second.promise;
      expect(idle).assertFalse(); expect(f.session.state.phase).assertEqual('running');
      finish.open(); await running; await waiting;
      expect(idle).assertTrue(); expect(f.session.state.phase).assertEqual('idle');
    });

    it('pausesOnFinalSaveFailureAndRequiresExplicitResumeAfterRetry', 0, async () => {
      const f = new Fixture(); await f.session.initialize();
      f.session.setDraft('first'); await f.session.enqueueInput('followUp');
      f.session.setDraft('second'); await f.session.enqueueInput('followUp');
      f.repository.beforeSave = async (data: AppData) => {
        if (active(data).messages[1]?.status === 'complete') { throw new Error('disk full'); }
      };
      await f.session.resumeQueue();
      const failed = active(f.session.snapshot());
      expect(failed.messages[1].status).assertEqual('failed');
      expect(failed.messages[1].content).assertEqual('done');
      expect(failed.queuePaused).assertTrue(); expect(failed.pendingInputs?.length).assertEqual(1);
      expect(f.session.state.saveError.includes('disk full')).assertTrue();
      await f.session.resumeQueue(); expect(f.provider.requests.length).assertEqual(1);
      f.repository.beforeSave = async () => {}; await f.session.retrySave();
      expect(f.session.state.saveError).assertEqual(''); expect(f.provider.requests.length).assertEqual(1);
      expect(active(await f.repository.load()).messages[1].status).assertEqual('failed');
      await f.session.resumeQueue(); expect(f.provider.requests.length).assertEqual(2);
    });

    it('stopsAndRestoresPendingInputsWithoutAutomaticallySendingThem', 0, async () => {
      const f = new Fixture(); await f.session.initialize(); const entered = new Gate();
      f.provider.respond = async (_index: number, signal: Cancellation) => {
        entered.open();
        await new Promise<void>((_resolve, reject) => { signal.onCancel(() => reject(new RunCancelledError())); });
        return reply();
      };
      f.session.setDraft('first'); const running = f.session.send(); await entered.promise;
      f.session.setDraft('remaining'); await f.session.enqueueInput('followUp');
      await f.session.stop(); await running;
      expect(active(f.session.snapshot()).messages[1].status).assertEqual('stopped');
      const restored = new Fixture(await f.repository.load()); await restored.session.initialize();
      expect(restored.provider.requests.length).assertEqual(0);
      expect(active(restored.session.snapshot()).queuePaused).assertTrue();
      restored.session.setDraft('manual message'); await restored.session.send();
      expect(restored.provider.requests.length).assertEqual(1);
      expect(active(restored.session.snapshot()).pendingInputs?.length).assertEqual(1);
      await restored.session.resumeQueue(); expect(restored.provider.requests.length).assertEqual(2);
    });

    it('abortsOnDraftSaveFailureAndRetainsQueuedWork', 0, async () => {
      const f = new Fixture(); await f.session.initialize(); const entered = new Gate();
      f.provider.respond = async (_index: number, signal: Cancellation) => {
        entered.open();
        await new Promise<void>((_resolve, reject) => { signal.onCancel(() => reject(new RunCancelledError())); });
        return reply();
      };
      f.session.setDraft('first'); const running = f.session.send(); await entered.promise;
      f.session.setDraft('remaining'); await f.session.enqueueInput('followUp');
      f.repository.beforeSave = async () => { throw new Error('disk offline'); };
      f.session.setDraft('unsaved'); await f.session.flushDraft(); await running;
      expect(active(f.session.snapshot()).queuePaused).assertTrue();
      expect(active(f.session.snapshot()).pendingInputs?.length).assertEqual(1);
      expect(f.session.state.saveError.includes('disk offline')).assertTrue();
      expect(f.provider.requests.length).assertEqual(1);
    });

    it('retainsInvalidSkillAtQueueHeadForEditing', 0, async () => {
      const f = new Fixture(); await f.session.initialize();
      f.session.setDraft('/skill:missing task'); await f.session.enqueueInput('followUp');
      const id = active(f.session.snapshot()).pendingInputs?.[0].id || '';
      await f.session.resumeQueue();
      expect(f.provider.requests.length).assertEqual(0);
      expect(active(f.session.snapshot()).pendingInputs?.length).assertEqual(1);
      f.session.setDraft('existing draft'); await f.session.removePendingInput(id, true);
      expect(active(f.session.snapshot()).draft).assertEqual('existing draft');
      expect(active(f.session.snapshot()).pendingInputs?.length).assertEqual(1);
      f.session.setDraft(''); await f.session.removePendingInput(id, true);
      expect(active(f.session.snapshot()).draft).assertEqual('/skill:missing task');
      expect(active(f.session.snapshot()).pendingInputs?.length).assertEqual(0);
    });

    it('isolatesDraftsQueuesAndArchivedSessionsAcrossSwitches', 0, async () => {
      const f = new Fixture(); await f.session.initialize();
      f.session.setDraft('first queue'); await f.session.enqueueInput('followUp');
      f.session.setDraft('first draft'); await f.session.newThread();
      const second = f.session.snapshot().activeThreadId;
      f.session.setDraft('second draft'); await f.session.selectThread('thread-1');
      expect(active(f.session.snapshot()).draft).assertEqual('first draft');
      expect(active(f.session.snapshot()).pendingInputs?.length).assertEqual(1);
      await f.session.archiveThread('thread-1'); expect(f.session.snapshot().activeThreadId).assertEqual(second);
      await f.session.selectThread('thread-1'); f.session.setDraft('forbidden'); await f.session.send();
      expect(active(f.session.snapshot()).draft).assertEqual('first draft'); expect(f.provider.requests.length).assertEqual(0);
      await f.session.deleteThread('thread-1');
      expect(f.session.snapshot().threads.length).assertEqual(1);
      expect(active(await f.repository.load()).draft).assertEqual('second draft');
    });

    it('preservesTypingDuringSettingsCommitAndSerializesItAfterTheNewConfig', 0, async () => {
      const f = new Fixture(); await f.session.initialize();
      const entered = new Gate(); const release = new Gate(); let blocked = false;
      f.repository.beforeSave = async () => { if (!blocked) { blocked = true; entered.open(); await release.promise; } };
      const saving = f.session.saveSettings('new prompt', false, false); await entered.promise;
      f.session.setDraft('typed during save'); await f.session.flushDraft();
      expect(await f.session.newThread()).assertFalse();
      release.open(); expect(await saving).assertTrue();
      const saved = await f.repository.load();
      expect(saved.config.userDocument).assertEqual('new prompt'); expect(saved.extensions?.webEnabled).assertFalse();
      expect(active(saved).draft).assertEqual('typed during save');
      expect(active(f.session.snapshot()).draft).assertEqual('typed during save');
    });

    it('routesLateComposerChangesToTheDisplayedThreadDuringASwitch', 0, async () => {
      const f = new Fixture(); await f.session.initialize(); await f.session.newThread();
      const second = f.session.snapshot().activeThreadId;
      const entered = new Gate(); const release = new Gate(); let blocked = false;
      f.repository.beforeSave = async () => { if (!blocked) { blocked = true; entered.open(); await release.promise; } };
      const switching = f.session.selectThread('thread-1'); await entered.promise;
      f.session.setDraft('late second draft', second);
      release.open(); expect(await switching).assertTrue();
      const saved = await f.repository.load();
      expect(active(saved).draft).assertEqual('');
      expect(saved.threads.find((item) => item.id === second)?.draft).assertEqual('late second draft');
    });

    it('keepsUiEventsDetachedAndReportsObserverFailuresWithoutFailingTheRun', 0, async () => {
      const f = new Fixture(); await f.session.initialize();
      f.session.subscribe((event: SessionEvent) => {
        if (event.data) { event.data.config.systemPrompt = 'changed by view'; }
        if (event.message) { event.message.content = 'changed by view'; }
        if (event.kind === 'text') { expect(event.data === undefined).assertTrue(); throw new Error('broken view'); }
      });
      f.session.setDraft('first'); await f.session.send();
      const copy = f.session.snapshot(); active(copy).draft = 'changed copy';
      expect(active(f.session.snapshot()).draft).assertEqual('');
      expect(active(f.session.snapshot()).messages[1].content).assertEqual('done');
      expect(active(f.session.snapshot()).messages[1].status).assertEqual('complete');
      expect(f.session.snapshot().config.systemPrompt === 'changed by view').assertFalse();
      expect(f.resources.errors.some((error) => error.includes('broken view'))).assertTrue();
    });

    it('commitsCompactionWithoutChangingFullHistoryOrAddingAnAssistantTurn', 0, async () => {
      const f = new Fixture(historySeed()); await f.session.initialize();
      f.provider.respond = async () => reply('short summary');
      const before = JSON.stringify(active(f.session.snapshot()).messages);
      await f.session.compactHistory();
      expect(active(f.session.snapshot()).compaction?.summary).assertEqual('short summary');
      expect(JSON.stringify(active(f.session.snapshot()).messages)).assertEqual(before);
      expect(f.provider.requests.length).assertEqual(1);
      expect(active(await f.repository.load()).compaction?.summary).assertEqual('short summary');
    });

    it('rollsBackCompactionWhenItsSaveFails', 0, async () => {
      const f = new Fixture(historySeed()); await f.session.initialize();
      f.provider.respond = async () => reply('short summary');
      f.repository.beforeSave = async (data: AppData) => { if (active(data).compaction) { throw new Error('summary save failed'); } };
      await f.session.compactHistory();
      expect(active(f.session.snapshot()).compaction === undefined).assertTrue();
      expect(active(await f.repository.load()).compaction === undefined).assertTrue();
      expect(f.session.state.error.includes('summary save failed')).assertTrue();
      expect(f.session.state.phase).assertEqual('idle');
    });

    it('doesNotCommitNewKeysOrSettingsWhenTheConfigWriteFails', 0, async () => {
      const f = new Fixture(); await f.session.initialize();
      const draft = providerDraft(); draft.noApiKey = false; draft.apiKey = 'new-secret';
      f.repository.beforeSave = async () => { throw new Error('config write failed'); };
      expect(await f.session.saveProvider(draft)).assertFalse();
      expect(f.keys.values.size).assertEqual(0); expect(f.keys.removed.length).assertEqual(1);
      expect(f.session.snapshot().providerProfiles?.[0].name).assertEqual('Test');
      expect(f.session.state.error.includes('config write failed')).assertTrue();
      expect(f.session.state.saveError).assertEqual('');
    });

    it('rotatesKeysOnlyAfterCommitAndRejectsReuseAcrossEndpoints', 0, async () => {
      const data = seed(); const profile = data.providerProfiles?.[0];
      if (!profile) { throw new Error('missing profile'); }
      profile.noApiKey = false; profile.credentialAlias = 'old-key';
      const f = new Fixture(data); f.keys.values.set('old-key', 'old-secret'); await f.session.initialize();
      f.repository.beforeSave = async () => { expect(f.keys.values.has('old-key')).assertTrue(); };
      const draft = providerDraft(); draft.noApiKey = false; draft.apiKey = 'new-secret';
      expect(await f.session.saveProvider(draft)).assertTrue();
      expect(f.keys.values.has('old-key')).assertFalse();
      const alias = f.session.snapshot().providerProfiles?.[0].credentialAlias || '';
      expect(await f.keys.read(alias)).assertEqual('new-secret');
      draft.apiKey = ''; draft.baseUrl = 'https://different.example/v1';
      expect(await f.session.saveProvider(draft)).assertFalse();
      expect(f.session.snapshot().providerProfiles?.[0].baseUrl).assertEqual('https://example.com/v1');
      expect(await f.keys.read(alias)).assertEqual('new-secret');
    });

    it('preservesSavedKeyWhenChangingProtocolAndOrdinaryProviderSettings', 0, async () => {
      const f = new Fixture(); await f.session.initialize();
      const draft = providerDraft(); draft.noApiKey = false; draft.apiKey = 'existing-secret';
      expect(await f.session.saveProvider(draft)).assertTrue();
      const alias = f.session.snapshot().providerProfiles?.[0].credentialAlias || '';
      const removals = f.keys.removed.length;
      draft.apiKey = ''; draft.protocol = 'responses'; draft.baseUrl += '/responses/';
      draft.name = 'Renamed'; draft.models = 'model,second-model'; draft.contextWindow = '65536';
      expect(await f.session.saveProvider(draft)).assertTrue();
      expect(f.session.snapshot().providerProfiles?.[0].credentialAlias).assertEqual(alias);
      expect((await f.repository.load()).providerProfiles?.[0].protocol).assertEqual('responses');
      draft.protocol = 'chat-completions'; draft.baseUrl = 'https://example.com/v1'; draft.enabled = false;
      expect(await f.session.saveProvider(draft)).assertTrue();
      expect(f.session.snapshot().providerProfiles?.[0].credentialAlias).assertEqual(alias);
      expect(await f.keys.read(alias)).assertEqual('existing-secret'); expect(f.keys.removed.length).assertEqual(removals);
      draft.baseUrl = 'https://example.com/other-tenant/v1';
      expect(await f.session.saveProvider(draft)).assertFalse();
      expect((await f.repository.load()).providerProfiles?.[0].baseUrl).assertEqual('https://example.com/v1');
    });

    it('requiresReplacingAMissingSavedKeyBeforeKeepingItsAlias', 0, async () => {
      const f = new Fixture(); await f.session.initialize();
      const draft = providerDraft(); draft.noApiKey = false; draft.apiKey = 'old-secret';
      expect(await f.session.saveProvider(draft)).assertTrue();
      const oldAlias = f.session.snapshot().providerProfiles?.[0].credentialAlias || '';
      f.keys.values.delete(oldAlias);
      const before = JSON.stringify(f.session.snapshot());
      const writes = f.repository.writes.length;
      draft.apiKey = ''; draft.name = 'Renamed';
      expect(await f.session.saveProvider(draft)).assertFalse();
      expect(JSON.stringify(f.session.snapshot())).assertEqual(before);
      expect(f.repository.writes.length).assertEqual(writes);
      expect(await f.session.selectModel('test', 'model')).assertFalse();
      draft.apiKey = 'replacement-secret';
      expect(await f.session.saveProvider(draft)).assertTrue();
      const alias = f.session.snapshot().providerProfiles?.[0].credentialAlias || '';
      expect(alias === oldAlias).assertFalse();
      expect(await f.keys.read(alias)).assertEqual('replacement-secret');
      expect(await f.session.selectModel('test', 'model')).assertTrue();
      draft.apiKey = ''; draft.name = 'Retain valid key';
      expect(await f.session.saveProvider(draft)).assertTrue();
      expect(f.session.snapshot().providerProfiles?.[0].credentialAlias).assertEqual(alias);
      f.session.setDraft('recovered'); await f.session.send();
      expect(f.provider.requests.length).assertEqual(1);
      expect(f.provider.requests[0].apiKey).assertEqual('replacement-secret');
    });

    it('persistsSkillsAndRejectsTheirMutationDuringExecution', 0, async () => {
      const f = new Fixture(); await f.session.initialize();
      const document = '---\nname: demo\ndescription: demo skill\n---\nRead the reference.';
      expect(await f.session.saveSkill('', document, [{ path: 'references/a.md', content: 'reference' }])).assertTrue();
      expect(await f.session.saveSkill('', document, [])).assertFalse();
      const entered = new Gate(); const release = new Gate();
      f.provider.respond = async () => { entered.open(); await release.promise; return reply(); };
      f.session.setDraft('/skill:demo task'); const running = f.session.send(); await entered.promise;
      const sent = f.provider.requests[0].messages.find((message) => message.role === 'user')?.content || '';
      expect(sent.includes('<skill name="demo">')).assertTrue();
      expect(sent.includes('Read the reference.')).assertTrue();
      expect(sent.includes('references/a.md')).assertTrue();
      expect(sent.endsWith('task')).assertTrue();
      expect(await f.session.changeSkill('demo', true)).assertFalse(); release.open(); await running;
      expect(await f.session.changeSkill('demo')).assertTrue();
      expect((await f.repository.load()).extensions?.skills[0].enabled).assertFalse();
      expect(await f.session.changeSkill('demo', true)).assertTrue();
      expect((await f.repository.load()).extensions?.skills.length).assertEqual(0);
      expect(active(await f.repository.load()).messages[0].skillPrompt).assertEqual(sent);
      f.provider.respond = async () => reply();
      f.session.setDraft('continue'); await f.session.send();
      expect(f.provider.requests[1].messages.some((message) => message.content === sent)).assertTrue();
    });
  });
}
