import { AppData, MessageData } from '../model/Conversation';
import { ProviderProfile } from '../model/ProviderProfiles';
import { ExtensionSettings } from '../model/Skills';
import { AgentTools } from './AgentLoop';

export interface SessionRepository {
  load(): Promise<AppData>;
  save(data: AppData): Promise<void>;
}

export interface SessionResources {
  createId(): string;
  ensureWorkspace(threadId: string): Promise<void>;
  tools(threadId: string, extensions: ExtensionSettings, selected: string): AgentTools;
  configureProviders(profiles: ProviderProfile[]): void;
  reportError(message: string): void;
}

export type SessionPhase = 'idle' | 'loading' | 'saving' | 'running' | 'compacting';

export interface SessionState {
  ready: boolean;
  phase: SessionPhase;
  error: string;
  saveError: string;
  contextStatus: string;
  contextTokens: number;
  acceptingSteering: boolean;
}

// Structural changes carry detached snapshots; text events carry only the changed prose.
export interface SessionEvent {
  kind: 'snapshot' | 'message' | 'text' | 'draft' | 'state';
  state: SessionState;
  data?: AppData;
  threadId?: string;
  message?: MessageData;
  messageId?: string;
  content?: string;
  step?: number;
  stepContent?: string;
}
