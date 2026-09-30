import { AgentTurn, MAX_AGENT_STEPS, ModelMessage } from '../model/Agent';
import { ModelConfig } from '../model/Conversation';
import { AgentTools, LoopEvent, LoopEventType, SteeringInput, runAgentLoop } from './AgentLoop';
import { Cancellation, RunCancelledError } from './Cancellation';
import { CredentialReader, ModelSession } from './providers/Provider';
import { ProviderRegistry } from './providers/ProviderRegistry';
import { contextSettings } from '../model/ConversationContext';

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
  sessionId: string;
  config: ModelConfig;
  messages: ModelMessage[];
  tools: AgentTools;
  maxSteps?: number;
  contextOnly?: boolean;
}

export interface AgentRunHooks {
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
  private active?: ActiveRun;
  private sequence: number = 0;
  private listeners: Set<(event: AgentEvent) => void> = new Set<(event: AgentEvent) => void>();

  constructor(providers: ProviderRegistry, credentials: CredentialReader) {
    this.providers = providers;
    this.credentials = credentials;
  }

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
      throw new Error('Agent 正在执行，请等待本轮结束。');
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
        try {
          model = this.providers.bind(request.config, this.credentials);
        } catch (error) {
          bindingError = error as Error;
        }
        let messages = JSON.parse(JSON.stringify(request.messages)) as ModelMessage[];
        const window = contextSettings(request.config).window;
        const limit = request.maxSteps === undefined ? MAX_AGENT_STEPS : request.maxSteps;
        const tools = request.tools;
        const contextOnly = request.contextOnly === true;
        this.emit({ type: 'run_start', run: active.state });
        if (bindingError) {
          throw bindingError;
        }
        if (!model) {
          throw new Error('模型服务未能完成绑定。');
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
          await runAgentLoop({ model: model, messages: messages, tools: tools,
            turn: active.state.turn, maxSteps: limit, contextWindow: window }, active.cancellation, {
            event: (event: LoopEvent) => {
              if (this.active === active) {
                this.emit({ type: event.type, run: active.state, step: event.step,
                  toolCallId: event.toolCallId, delta: event.delta });
              }
            },
            checkpoint: hooks.checkpoint, steering: hooks.steering
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
