import { describe, expect, it } from '@ohos/hypium';
import { ModelMessage, ModelTurn, ToolCall, ToolDefinition, validateSteps } from '../main/ets/model/Agent';
import { defaultConfig, emptyData, ModelConfig, parseAppData } from '../main/ets/model/Conversation';
import { ProviderInfo } from '../main/ets/model/Provider';
import { AgentTools } from '../main/ets/services/AgentLoop';
import { AgentEvent, AgentRunHooks, AgentRunRequest, AgentRuntime } from '../main/ets/services/AgentRuntime';
import { Cancellation, RunCancelledError } from '../main/ets/services/Cancellation';
import { chatRequest, completionUrl } from '../main/ets/services/providers/ChatCompletionsProtocol';
import { CredentialReader, ModelProvider, ModelSession, ProviderRequest } from '../main/ets/services/providers/Provider';
import { ProviderRegistry } from '../main/ets/services/providers/ProviderRegistry';
import { UsageOrigin, UsageToolActivity, UsageRecorder } from '../main/ets/model/Usage';

class TestUsageRecorder implements UsageRecorder {
  records: UsageToolActivity[] = [];
  recordTool(_id: string, activity: UsageToolActivity): void { this.records.push(JSON.parse(JSON.stringify(activity)) as UsageToolActivity); }
}

class Gate {
  private release: () => void = () => {};
  promise: Promise<void> = new Promise<void>((resolve) => { this.release = resolve; });
  open(): void { this.release(); }
}

class TestCredentials implements CredentialReader {
  aliases: string[] = [];
  entered: Gate = new Gate();
  blocked?: Gate;
  failure: string = '';

  async read(alias: string): Promise<string> {
    this.aliases.push(alias);
    this.entered.open();
    if (this.blocked) { await this.blocked.promise; }
    if (this.failure.length > 0) { throw new Error(this.failure); }
    return 'fake-secret-' + this.aliases.length;
  }
}

class TestProvider implements ModelProvider {
  readonly info: ProviderInfo;
  inputs: ProviderRequest[] = [];
  signals: Cancellation[] = [];
  callbacks: ((text: string) => void)[] = [];
  onStream?: (cancellation: Cancellation) => Promise<void>;
  emitText: boolean = true;
  private responses: ModelTurn[];

  constructor(id: string, responses: ModelTurn[]) {
    this.info = { id: id, name: id, protocol: 'test', defaultBaseUrl: 'https://example.com/v1', defaultModel: 'test-model' };
    this.responses = responses;
  }

  endpoint(baseUrl: string): string { return completionUrl(baseUrl); }

  async stream(request: ProviderRequest, cancellation: Cancellation, onText: (text: string) => void): Promise<ModelTurn> {
    const index = this.inputs.length;
    this.inputs.push(request);
    this.signals.push(cancellation);
    this.callbacks.push(onText);
    await this.onStream?.(cancellation);
    cancellation.check();
    const response = this.responses[index];
    if (!response) { throw new Error('Provider fixture exhausted'); }
    if (this.emitText && response.content.length > 0) { onText(response.content); }
    return response;
  }
}

class TestTools implements AgentTools {
  calls: ToolCall[] = [];
  definitions(): ToolDefinition[] { return []; }
  async execute(call: ToolCall, cancellation: Cancellation): Promise<string> {
    cancellation.check();
    this.calls.push(call);
    return '{"ok":true}';
  }
}

function answer(content: string = 'done'): ModelTurn { return { content: content, toolCalls: [] }; }
function toolAnswer(): ModelTurn {
  return { content: '', toolCalls: [{ id: 'call_1', type: 'function', function: { name: 'list_files', arguments: '{"path":"."}' } }] };
}
function config(providerId: string = 'test'): ModelConfig {
  const value = defaultConfig();
  value.configured = true;
  value.providerId = providerId;
  value.baseUrl = 'https://example.com/v1';
  value.model = 'test-model';
  value.credentialAlias = 'test-alias';
  return value;
}
function request(tools: TestTools = new TestTools()): AgentRunRequest {
  return { sessionId: 'test-session', config: config(), messages: [{ role: 'user', content: 'test prompt' }], tools: tools };
}
function hooks(): AgentRunHooks { return { prepare: async () => {}, checkpoint: async () => {} }; }
function registry(provider: TestProvider): ProviderRegistry {
  const result = new ProviderRegistry();
  result.register(provider);
  return result;
}
function rejects(action: () => void, fragment: string): void {
  let error = '';
  try { action(); } catch (caught) { error = (caught as Error).message; }
  expect(error.includes(fragment)).assertTrue();
}
async function rejectsAsync(action: () => Promise<void>, fragment: string): Promise<void> {
  let error = '';
  try { await action(); } catch (caught) { error = (caught as Error).message; }
  expect(error.includes(fragment)).assertTrue();
}

export default function runtimeTests(): void {
  describe('ProviderRegistry', () => {
    it('registersExplicitlyRejectsDuplicatesAndHasNoFallback', 0, () => {
      const providers = registry(new TestProvider('test', [answer()]));
      rejects(() => providers.register(new TestProvider('test', [answer()])), '已注册');
      rejects(() => providers.register(new TestProvider('invalid id', [answer()])), '无效');
      providers.register(new TestProvider('second', [answer()]));
      expect(providers.list().length).assertEqual(2);
      providers.list()[0].name = 'changed copy';
      expect(providers.require('test').info.name).assertEqual('test');
      providers.unregister('test');
      rejects(() => { providers.bind(config(), new TestCredentials()); }, '未注册');
      expect(providers.list()[0].id).assertEqual('second');
    });
    it('bindsASnapshotAndResolvesCredentialsForEveryRequest', 0, async () => {
      const original = new TestProvider('test', [answer('old-1'), answer('old-2')]);
      const replacement = new TestProvider('test', [answer('new')]);
      const providers = registry(original);
      const keys = new TestCredentials();
      const settings = config();
      const session = providers.bind(settings, keys);
      settings.baseUrl = 'https://changed.example/v1';
      settings.model = 'changed-model';
      settings.credentialAlias = 'changed-alias';
      providers.unregister('test');
      providers.register(replacement);
      const messages: ModelMessage[] = [{ role: 'user', content: 'hi' }];
      await session.stream(messages, [], new Cancellation(), () => {});
      await session.stream(messages, [], new Cancellation(), () => {});
      expect(original.inputs[0].baseUrl).assertEqual('https://example.com/v1');
      expect(original.inputs[1].model).assertEqual('test-model');
      expect(keys.aliases.join(',')).assertEqual('test-alias,test-alias');
      expect(original.inputs[0].apiKey).assertEqual('fake-secret-1');
      expect(original.inputs[1].apiKey).assertEqual('fake-secret-2');
      await providers.bind(settings, keys).stream(messages, [], new Cancellation(), () => {});
      expect(replacement.inputs[0].model).assertEqual('changed-model');
    });
    it('doesNotReuseKeysAcrossProvidersOrEndpoints', 0, () => {
      const providers = registry(new TestProvider('test', [answer()]));
      providers.register(new TestProvider('other', [answer()]));
      expect(providers.sameCredentialScope(config(), 'test', 'https://example.com/v1/')).assertTrue();
      expect(providers.sameCredentialScope(config(), 'other', 'https://example.com/v1')).assertFalse();
      expect(providers.sameCredentialScope(config(), 'test', 'https://other.example/v1')).assertFalse();
    });
    it('migratesLegacySettingsWithoutGuessingTheProviderFromTheUrl', 0, () => {
      const data = emptyData();
      data.config.baseUrl = 'https://custom.example/v1';
      data.config.model = 'custom-model';
      data.config.credentialAlias = 'saved-alias';
      const legacy = JSON.stringify(data).replace('"providerId":"deepseek",', '');
      expect(legacy.includes('providerId')).assertFalse();
      const restored = parseAppData(legacy);
      expect(restored.config.providerId).assertEqual('openai-compatible');
      expect(restored.config.baseUrl).assertEqual(data.config.baseUrl);
      expect(restored.config.model).assertEqual(data.config.model);
      expect(restored.config.credentialAlias).assertEqual('saved-alias');
      restored.config.providerId = 'uninstalled-provider';
      expect(parseAppData(JSON.stringify(restored)).config.providerId).assertEqual('uninstalled-provider');
    });
    it('encodesProtocolFieldsOnlyAtTheProviderBoundary', 0, () => {
      const messages: ModelMessage[] = [
        { role: 'assistant', content: '', toolCalls: toolAnswer().toolCalls },
        { role: 'tool', content: '{"ok":true}', toolCallId: 'call_1' }
      ];
      const body = chatRequest('model', messages, []);
      expect(body.messages[0].tool_calls?.[0].id).assertEqual('call_1');
      expect(body.messages[1].tool_call_id).assertEqual('call_1');
      expect(JSON.stringify(body).includes('toolCallId')).assertFalse();
      expect(JSON.stringify(messages).includes('tool_call_id')).assertFalse();
    });
  });

  describe('AgentRuntime', () => {
    it('keepsTurnOriginAcrossCallsAndSeparatesPreparationPurpose', 0, async () => {
      const provider = new TestProvider('test', [answer('summary'), toolAnswer(), answer()]);
      const runtime = new AgentRuntime(registry(provider), new TestCredentials());
      const run = request(); run.usageOrigin = { threadId: 'thread', turnId: 'turn', purpose: 'conversation' };
      const callbacks = hooks(); callbacks.prepareContext = async (model, messages, cancellation) => {
        await model.stream([], [], cancellation, () => {}, { usagePurpose: 'compaction', usageStep: 1 }); return messages;
      };
      expect((await runtime.run(run, callbacks)).status).assertEqual('complete');
      expect(provider.inputs.length).assertEqual(3);
      expect(provider.inputs[0].usageOrigin?.purpose).assertEqual('compaction');
      expect(provider.inputs[1].usageOrigin?.purpose).assertEqual('conversation');
      expect(provider.inputs[2].usageOrigin?.turnId).assertEqual('turn');
      expect(provider.inputs[2].usageOrigin?.step).assertEqual(2);
    });
    it('forkedConcurrentRuntimesFreezeSeparateOrigins', 0, async () => {
      const provider = new TestProvider('test', [answer(), answer()]);
      const credentials = new TestCredentials(); credentials.blocked = new Gate();
      const first = new AgentRuntime(registry(provider), credentials); const second = first.fork();
      const origin: UsageOrigin = { threadId: 'one', turnId: 'a', taskId: 'task-a', purpose: 'team_task' };
      const a = request(); a.usageOrigin = origin;
      const b = request(); b.usageOrigin = { threadId: 'two', turnId: 'b', taskId: 'task-b', purpose: 'title' };
      const pending = first.run(a, hooks()); const other = second.run(b, hooks());
      origin.threadId = 'mutated'; await credentials.entered.promise; credentials.blocked.open(); await Promise.all([pending, other]);
      expect(provider.inputs.map((item) => item.usageOrigin?.threadId).sort().join(',')).assertEqual('one,two');
      expect(provider.inputs.find((item) => item.usageOrigin?.threadId === 'one')?.usageOrigin?.taskId).assertEqual('task-a');
    });
    it('recordsExecutedToolsWithoutArgumentsAndSkipsUnexecutedIntents', 0, async () => {
      const response = toolAnswer(); response.usage = { id: 'request', provider: 'test', model: 'model', startedAt: 1, durationMs: 20, status: 'complete' };
      const recorder = new TestUsageRecorder();
      const runtime = new AgentRuntime(registry(new TestProvider('test', [response, answer()])), new TestCredentials(), recorder);
      await runtime.run(request(), hooks());
      expect(recorder.records.length).assertEqual(2); expect(recorder.records[0].status).assertEqual('running');
      expect(recorder.records[1].status).assertEqual('complete'); expect(JSON.stringify(recorder.records).includes('arguments')).assertFalse();
      const blocked = new TestUsageRecorder();
      const second = new AgentRuntime(registry(new TestProvider('test', [response])), new TestCredentials(), blocked);
      let checkpoints = 0; const callbacks = hooks(); callbacks.checkpoint = async () => { if (++checkpoints === 2) { throw new Error('save failed'); } };
      await second.run(request(), callbacks); expect(blocked.records.length).assertEqual(0);
    });
    it('preparesCompactedContextWithTheSameBoundModelBeforeTheAgentRequest', 0, async () => {
      const provider = new TestProvider('test', [answer('summary'), answer('final')]);
      const agent = new AgentRuntime(registry(provider), new TestCredentials());
      const result = await agent.run(request(), { prepare: async () => {}, checkpoint: async () => {},
        prepareContext: async (model: ModelSession, messages: ModelMessage[], cancellation: Cancellation) => {
          const summary = await model.stream([{ role: 'user', content: 'summarize history' }], [], cancellation,
            () => {}, { maxOutputTokens: 4096 });
          const prepared: ModelMessage[] = [{ role: 'user', content: summary.content }];
          return prepared.concat(messages);
        }
      });
      expect(result.status).assertEqual('complete');
      expect(provider.inputs.length).assertEqual(2);
      expect(provider.inputs[0].tools.length).assertEqual(0);
      expect(provider.inputs[0].maxOutputTokens).assertEqual(4096);
      expect(provider.inputs[1].messages[0].content).assertEqual('summary');
      expect(provider.inputs[1].messages[1].content).assertEqual('test prompt');
      expect(result.turn.content).assertEqual('final');
    });
    it('manualCompactionDoesNotGenerateAnExtraAssistantTurn', 0, async () => {
      const provider = new TestProvider('test', [answer('summary')]);
      const agent = new AgentRuntime(registry(provider), new TestCredentials());
      const input = request();
      input.contextOnly = true;
      let saves = 0;
      const result = await agent.run(input, { prepare: async () => {}, checkpoint: async () => { saves++; },
        prepareContext: async (model: ModelSession, messages: ModelMessage[], cancellation: Cancellation) => {
          await model.stream(messages, [], cancellation, () => {});
          return messages;
        }
      });
      expect(result.status).assertEqual('complete');
      expect(provider.inputs.length).assertEqual(1);
      expect(result.turn.steps.length).assertEqual(0);
      expect(saves).assertEqual(2);
    });
    it('failedCompactionDoesNotDispatchTheNormalModelRequest', 0, async () => {
      const provider = new TestProvider('test', [answer()]);
      const agent = new AgentRuntime(registry(provider), new TestCredentials());
      const result = await agent.run(request(), { prepare: async () => {}, checkpoint: async () => {},
        prepareContext: async () => { throw new Error('summary persistence failed'); }
      });
      expect(result.status).assertEqual('failed');
      expect(result.error).assertEqual('summary persistence failed');
      expect(provider.inputs.length).assertEqual(0);
      expect(agent.isRunning).assertFalse();
    });
    it('cancelsSummaryRequestsThroughTheRuntimeSignal', 0, async () => {
      const provider = new TestProvider('test', [answer()]);
      const started = new Gate();
      provider.onStream = async (signal: Cancellation) => {
        started.open();
        await new Promise<void>((_resolve, reject) => { signal.onCancel(() => reject(new RunCancelledError())); });
      };
      const agent = new AgentRuntime(registry(provider), new TestCredentials());
      const pending = agent.run(request(), { prepare: async () => {}, checkpoint: async () => {},
        prepareContext: async (model: ModelSession, messages: ModelMessage[], cancellation: Cancellation) => {
          await model.stream(messages, [], cancellation, () => {});
          return messages;
        }
      });
      await started.promise;
      agent.abort();
      expect((await pending).status).assertEqual('stopped');
      expect(provider.inputs.length).assertEqual(1);
      expect(agent.isRunning).assertFalse();
    });
    it('emitsOrderedLifecycleEventsAndKeepsCredentialsOutOfThem', 0, async () => {
      const provider = new TestProvider('test', [toolAnswer(), answer()]);
      const keys = new TestCredentials();
      const agent = new AgentRuntime(registry(provider), keys);
      const types: string[] = [];
      const snapshots: string[] = [];
      const tools = new TestTools();
      let checkpoints = 0;
      agent.subscribe((event: AgentEvent) => {
        types.push(event.type);
        snapshots.push(JSON.stringify(event));
        if (event.type === 'tool_start') { expect(checkpoints > 0).assertTrue(); }
        if (event.type === 'run_end') { expect(agent.isRunning).assertTrue(); }
      });
      const persistence: AgentRunHooks = { prepare: async () => {}, checkpoint: async () => { checkpoints++; } };
      const result = await agent.run(request(tools), persistence);
      expect(result.status).assertEqual('complete');
      expect(result.turn.content).assertEqual('done');
      expect(types.join(',')).assertEqual('run_start,step_start,model_end,tool_start,tool_end,step_end,step_start,text_delta,model_end,step_end,run_finishing,run_end');
      expect(keys.aliases.length).assertEqual(2);
      expect(tools.calls.length).assertEqual(1);
      expect(snapshots.join('').includes('fake-secret')).assertFalse();
      expect(agent.isRunning).assertFalse();
    });
    it('blocksOverlappingRunsAndWaitsForFinalPersistenceBeforeIdle', 0, async () => {
      const agent = new AgentRuntime(registry(new TestProvider('test', [answer(), answer()])), new TestCredentials());
      const finalSave = new Gate();
      const saving = new Gate();
      let count = 0;
      let idle = false;
      const pending = agent.run(request(), { prepare: async () => {}, checkpoint: async () => {
        if (++count === 2) { saving.open(); await finalSave.promise; }
      } });
      await saving.promise;
      const idlePromise = agent.waitForIdle().then(() => { idle = true; });
      expect(idle).assertFalse();
      expect(agent.isRunning).assertTrue();
      await rejectsAsync(async () => { await agent.run(request(), hooks()); }, '正在执行');
      agent.abort(); // Finishing is a persistence barrier; completion is already known.
      finalSave.open();
      expect((await pending).status).assertEqual('complete');
      await idlePromise;
      expect(idle).assertTrue();
      expect((await agent.run(request(), hooks())).id).assertEqual(2);
    });
    it('cancelsWhilePreparingWithoutReadingCredentialsOrCallingTheModel', 0, async () => {
      const provider = new TestProvider('test', [answer()]);
      const keys = new TestCredentials();
      const agent = new AgentRuntime(registry(provider), keys);
      const entered = new Gate();
      const prepared = new Gate();
      const pending = agent.run(request(), { prepare: async () => { entered.open(); await prepared.promise; }, checkpoint: async () => {} });
      await entered.promise;
      agent.abort();
      prepared.open();
      expect((await pending).status).assertEqual('stopped');
      expect(keys.aliases.length).assertEqual(0);
      expect(provider.inputs.length).assertEqual(0);
    });
    it('cancelsWhileResolvingCredentialsAndDoesNotLeakTheRequest', 0, async () => {
      const provider = new TestProvider('test', [answer()]);
      const keys = new TestCredentials();
      keys.blocked = new Gate();
      const agent = new AgentRuntime(registry(provider), keys);
      const pending = agent.run(request(), hooks());
      await keys.entered.promise;
      agent.abort();
      keys.blocked.open();
      expect((await pending).status).assertEqual('stopped');
      expect(provider.inputs.length).assertEqual(0);
    });
    it('propagatesCancellationToTheProviderAndIsolatesTheNextRun', 0, async () => {
      const provider = new TestProvider('test', [answer(), answer('next')]);
      const started = new Gate();
      provider.onStream = async (signal: Cancellation) => {
        started.open();
        await new Promise<void>((_resolve, reject) => { signal.onCancel(() => reject(new RunCancelledError())); });
      };
      const agent = new AgentRuntime(registry(provider), new TestCredentials());
      const pending = agent.run(request(), hooks());
      await started.promise;
      agent.abort();
      expect((await pending).status).assertEqual('stopped');
      provider.onStream = undefined;
      expect((await agent.run(request(), hooks())).turn.content).assertEqual('next');
      expect(provider.signals[0].cancelled).assertTrue();
      expect(provider.signals[1].cancelled).assertFalse();
    });
    it('freezesInputBeforeAwaitingPreparationAndIgnoresLateProviderText', 0, async () => {
      const provider = new TestProvider('test', [answer('canonical')]);
      provider.emitText = false;
      const agent = new AgentRuntime(registry(provider), new TestCredentials());
      const input = request();
      agent.subscribe((event: AgentEvent) => {
        if (event.type === 'run_start') { input.config.model = 'mutated'; input.messages[0].content = 'mutated'; }
      });
      const result = await agent.run(input, hooks());
      expect(provider.inputs[0].model).assertEqual('test-model');
      expect(provider.inputs[0].messages[0].content).assertEqual('test prompt');
      expect(result.turn.content).assertEqual('canonical');
      provider.callbacks[0]('late text');
      expect(result.turn.content).assertEqual('canonical');
      expect(result.turn.steps[0].content).assertEqual('canonical');
    });
    it('reportsUnknownProvidersAndCanRunAfterRegistration', 0, async () => {
      const providers = new ProviderRegistry();
      const agent = new AgentRuntime(providers, new TestCredentials());
      const events: string[] = [];
      const unsubscribe = agent.subscribe((event: AgentEvent) => { events.push(event.type); });
      const failed = await agent.run(request(), hooks());
      expect(failed.status).assertEqual('failed');
      expect(failed.error.includes('未注册')).assertTrue();
      expect(events.join(',')).assertEqual('run_start,run_finishing,run_end');
      unsubscribe();
      providers.register(new TestProvider('test', [answer()]));
      expect((await agent.run(request(), hooks())).status).assertEqual('complete');
      expect(events.length).assertEqual(3);
    });
    it('preservesStorageErrorsInsteadOfCallingThemCancellation', 0, async () => {
      const provider = new TestProvider('test', [answer()]);
      const agent = new AgentRuntime(registry(provider), new TestCredentials());
      const entered = new Gate();
      const release = new Gate();
      let saves = 0;
      const pending = agent.run(request(), { prepare: async () => {}, checkpoint: async () => {
        if (++saves === 1) { entered.open(); await release.promise; throw new Error('disk full'); }
      } });
      await entered.promise;
      agent.abort();
      release.open();
      const result = await pending;
      expect(result.status).assertEqual('failed');
      expect(result.error).assertEqual('disk full');
      expect(provider.inputs.length).assertEqual(0);
      expect(agent.isRunning).assertFalse();
    });
    it('reportsFinalSaveFailureAndReleasesTheRun', 0, async () => {
      const agent = new AgentRuntime(registry(new TestProvider('test', [answer()])), new TestCredentials());
      let count = 0;
      const result = await agent.run(request(), { prepare: async () => {}, checkpoint: async () => {
        if (++count === 2) { throw new Error('final save failed'); }
      } });
      expect(result.status).assertEqual('failed');
      expect(result.error).assertEqual('final save failed');
      expect(result.turn.content).assertEqual('done');
      await agent.waitForIdle();
      expect(agent.isRunning).assertFalse();
    });
    it('enforcesTheConfiguredLimitAndRejectsInvalidLimits', 0, async () => {
      const tools = new TestTools();
      const provider = new TestProvider('test', [toolAnswer()]);
      const agent = new AgentRuntime(registry(provider), new TestCredentials());
      const input = request(tools);
      input.maxSteps = 1;
      const result = await agent.run(input, hooks());
      expect(result.status).assertEqual('failed');
      expect(result.error.includes('1 次')).assertTrue();
      expect(tools.calls.length).assertEqual(0);
      input.maxSteps = 201;
      expect((await agent.run(input, hooks())).error.includes('1 至 200')).assertTrue();
      expect(provider.inputs.length).assertEqual(1);
    });
    it('allowsTwoHundredRequestsByDefaultWithoutCappingNormalOutput', 0, async () => {
      const responses: ModelTurn[] = [];
      for (let index = 0; index < 199; index++) {
        const response = toolAnswer();
        response.toolCalls[0].id = 'call_' + index;
        response.toolCalls[0].function.arguments = JSON.stringify({ path: 'dir' + index });
        responses.push(response);
      }
      responses.push(answer());
      const provider = new TestProvider('test', responses);
      const tools = new TestTools();
      const result = await new AgentRuntime(registry(provider), new TestCredentials()).run(request(tools), hooks());
      expect(result.status).assertEqual('complete');
      expect(provider.inputs.length).assertEqual(200);
      expect(tools.calls.length).assertEqual(199);
      expect(provider.inputs.every((input) => input.maxOutputTokens === undefined)).assertTrue();
      validateSteps(result.turn.steps);
    });
    it('releasesTheRunEvenWhenAUiListenerThrows', 0, async () => {
      const agent = new AgentRuntime(registry(new TestProvider('test', [answer()])), new TestCredentials());
      agent.subscribe((event: AgentEvent) => { if (event.type === 'run_end') { throw new Error('UI listener failed'); } });
      await rejectsAsync(async () => { await agent.run(request(), hooks()); }, 'UI listener failed');
      await agent.waitForIdle();
      expect(agent.isRunning).assertFalse();
    });
  });
}
