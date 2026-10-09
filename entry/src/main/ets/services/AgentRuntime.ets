import { t } from '../model/I18n';
import { AgentTurn, MAX_AGENT_STEPS, ModelMessage, ToolExecutionMode } from '../model/Agent';
import { ModelConfig, copyModelConfig } from '../model/Conversation';
import { UsageOrigin, UsageRecorder } from '../model/Usage';
import { AgentTools, LoopEvent, LoopEventType, SteeringInput, runAgentLoop } from './AgentLoop';
import { Cancellation, RunCancelledError } from './Cancellation';
import { CredentialReader, ModelSession } from './providers/Provider';
import { ProviderRegistry } from './providers/ProviderRegistry';
import { contextSettings } from '../model/ConversationContext';
import { PromptSection, runEntries } from '../model/ContextProjection';
import { ContextSource, RequestContext } from './RequestContext';
import { ContextTools } from './ContextTools';

export type RunStatus = 'running' | 'complete' | 'stopped' | 'failed';
export type RunPhase = 'preparing' | 'executing' | 'finalizing';
export type AgentEventType = LoopEventType | 'run_start' | 'run_stopping' | 'run_finishing' | 'run_end';

export interface AgentRunState {
  id: number;
  sessionId: string;
  phase: RunPhase;
  status: RunStatus;
  error: string;
  turn: AgentTurn;
}

export interface AgentEvent {
  type: AgentEventType;
  run: AgentRunState;
  step?: number;
  toolCallId?: string;
  delta?: string;
}

export interface AgentRunRequest {
  toolExecution?: ToolExecutionMode;
  usageOrigin?: UsageOrigin;
  sessionId: string;
  config: ModelConfig;
  messages: ModelMessage[];
  tools: AgentTools;
  maxSteps?: number;
  contextOnly?: boolean;
}

export interface AgentRunHooks {
  context?: ContextSource;
  prepare: (cancellation: Cancellation) => Promise<void>;
  checkpoint: () => Promise<void>;
  steering?: SteeringInput;
  prepareContext?: (model: ModelSession, messages: ModelMessage[], cancellation: Cancellation) => Promise<ModelMessage[]>;
}

interface ActiveRun {
  state: AgentRunState;
  cancellation: Cancellation;
  idle: Promise<void>;
  resolveIdle: () => void;
}

// Owns one active run, from preflight through the final persistence barrier.
export class AgentRuntime {
  private providers: ProviderRegistry;
  private credentials: CredentialReader;
  private usage?: UsageRecorder;
  private validateAnswer?: (content: string, cancellation: Cancellation) => Promise<void>;
  private active?: ActiveRun;
  private sequence: number = 0;
  private listeners: Set<(event: AgentEvent) => void> = new Set<(event: AgentEvent) => void>();

  constructor(providers: ProviderRegistry, credentials: CredentialReader, usage?: UsageRecorder,
    validateAnswer?: (content: string, cancellation: Cancellation) => Promise<void>) {
    this.providers = providers;
    this.credentials = credentials;
    this.usage = usage;
    this.validateAnswer = validateAnswer;
  }

  fork(): AgentRuntime { return new AgentRuntime(this.providers, this.credentials, this.usage, this.validateAnswer); }

  get isRunning(): boolean {
    return this.active !== undefined;
  }

  get acceptsSteering(): boolean {
    return this.active !== undefined && this.active.state.phase !== 'finalizing' && !this.active.cancellation.cancelled;
  }

  // UI subscriptions are synchronous. Durable work belongs in the awaited checkpoint hook.
  subscribe(listener: (event: AgentEvent) => void): () => void {
    this.listeners.add(listener);
    return () => { this.listeners.delete(listener); };
  }

  abort(): void {
    const active = this.active;
    if (!active || active.state.phase === 'finalizing' || active.cancellation.cancelled) {
      return;
    }
    active.cancellation.cancel();
    this.emit({ type: 'run_stopping', run: active.state });
  }

  waitForIdle(): Promise<void> {
    return this.active?.idle || Promise.resolve();
  }

  async run(request: AgentRunRequest, hooks: AgentRunHooks): Promise<AgentRunState> {
    if (this.active) {
      throw new Error(t("Agent 正在执行，请等待本轮结束。"));
    }
    let resolveIdle = (): void => {};
    const idle = new Promise<void>((resolve) => { resolveIdle = resolve; });
    const active: ActiveRun = {
      state: { id: ++this.sequence, sessionId: request.sessionId, phase: 'preparing', status: 'running',
        error: '', turn: { content: '', steps: [] } },
      cancellation: new Cancellation(), idle: idle, resolveIdle: resolveIdle
    };
    this.active = active;
    try {
      try {
        // Freeze routing/config/history before the first await or caller notification.
        let model: ModelSession | undefined = undefined;
        let bindingError: Error | undefined = undefined;
        const config = copyModelConfig(request.config);
        try {
          model = this.providers.bind(config, this.credentials, request.usageOrigin);
        } catch (error) {
          bindingError = error as Error;
        }
        let messages = JSON.parse(JSON.stringify(request.messages)) as ModelMessage[];
        const window = contextSettings(config).window;
        const limit = request.maxSteps === undefined ? MAX_AGENT_STEPS : request.maxSteps;
        const tools = request.tools;
        const toolExecution = request.toolExecution;
        const contextOnly = request.contextOnly === true;
        this.emit({ type: 'run_start', run: active.state });
        if (bindingError) {
          throw bindingError;
        }
        if (!model) {
          throw new Error(t("模型服务未能完成绑定。"));
        }
        await hooks.checkpoint();
        active.cancellation.check();
        await hooks.prepare(active.cancellation);
        active.cancellation.check();
        if (hooks.prepareContext) {
          messages = await hooks.prepareContext(model, messages, active.cancellation);
          active.cancellation.check();
        }
        active.state.phase = 'executing';
        if (!contextOnly) {
          const defaultSource: ContextSource = { state: active.state.turn,
            entries: () => runEntries(messages, active.state.turn, request.sessionId),
            sections: () => messages.filter((message) => message.role === 'system').map((message, index): PromptSection => ({ name: 'instructions_' + index, content: message.content })),
            persist: hooks.checkpoint, progress: () => {} };
          const source = hooks.context || defaultSource;
          const preparedContext = new RequestContext(source, config);
          const contextTools = new ContextTools(tools, source.entries, window);
          const boundModel = model;
          await runAgentLoop({ model: model, messages: messages, tools: contextTools, toolExecution: toolExecution,
            prepareRequest: async (definitions, pending, cancellation, recoverOverflow) => {
              const prepared = await preparedContext.prepare(boundModel, definitions, cancellation, pending, false, recoverOverflow);
              this.usage?.recordContext?.(request.sessionId, prepared.context);
              return prepared;
            },
            recordResponse: (response) => preparedContext.recordResponse(response),
            turn: active.state.turn, maxSteps: limit, contextWindow: window, validateAnswer: this.validateAnswer }, active.cancellation, {
            event: (event: LoopEvent) => {
              if (this.active === active) {
                this.emit({ type: event.type, run: active.state, step: event.step,
                  toolCallId: event.toolCallId, delta: event.delta });
              }
            },
            checkpoint: hooks.checkpoint, steering: hooks.steering,
            toolActivity: (id, activity) => { this.usage?.recordTool(id, activity); }
          });
        }
        active.state.status = 'complete';
      } catch (error) {
        active.state.status = error instanceof RunCancelledError ? 'stopped' : 'failed';
        active.state.error = (error as Error).message;
      }
      active.state.phase = 'finalizing';
      this.emit({ type: 'run_finishing', run: active.state });
      try {
        await hooks.checkpoint();
      } catch (error) {
        active.state.status = 'failed';
        active.state.error = (error as Error).message;
      }
      this.emit({ type: 'run_end', run: active.state });
      return active.state;
    } finally {
      // Includes synchronous run_end listeners; no next run can overlap final persistence.
      this.active = undefined;
      active.resolveIdle();
    }
  }

  private emit(event: AgentEvent): void {
    for (const listener of Array.from(this.listeners)) {
      listener(event);
    }
  }
}
