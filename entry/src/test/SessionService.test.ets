import { describe, expect, it } from '@ohos/hypium';
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
import { ModelProvider, ProviderRequest } from '../main/ets/services/providers/Provider';
import { ProviderRegistry } from '../main/ets/services/providers/ProviderRegistry';

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
  ids: number = 100;
  workspaces: string[] = [];
  errors: string[] = [];
  createId(): string { return 'id-' + ++this.ids; }
  async ensureWorkspace(id: string): Promise<void> { this.workspaces.push(id); }
  tools(_id: string, _extensions: ExtensionSettings, _selected: string): AgentTools { return new EmptyTools(); }
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

export default function sessionServiceTests(): void {
  describe('SessionService', () => {
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
      expect(saved.config.systemPrompt).assertEqual('new prompt'); expect(saved.extensions?.webEnabled).assertFalse();
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

    it('persistsSkillsAndRejectsTheirMutationDuringExecution', 0, async () => {
      const f = new Fixture(); await f.session.initialize();
      const document = '---\nname: demo\ndescription: demo skill\n---\nRead the reference.';
      expect(await f.session.saveSkill('', document, [{ path: 'references/a.md', content: 'reference' }])).assertTrue();
      expect(await f.session.saveSkill('', document, [])).assertFalse();
      const entered = new Gate(); const release = new Gate();
      f.provider.respond = async () => { entered.open(); await release.promise; return reply(); };
      f.session.setDraft('/skill:demo task'); const running = f.session.send(); await entered.promise;
      expect(await f.session.changeSkill('demo', true)).assertFalse(); release.open(); await running;
      expect(await f.session.changeSkill('demo')).assertTrue();
      expect((await f.repository.load()).extensions?.skills[0].enabled).assertFalse();
      expect(await f.session.changeSkill('demo', true)).assertTrue();
      expect((await f.repository.load()).extensions?.skills.length).assertEqual(0);
    });
  });
}
