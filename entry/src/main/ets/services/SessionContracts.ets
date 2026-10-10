import { ProductivityData, Attachment, McpServer } from '../model/Productivity';
import { AppData, MessageData } from '../model/Conversation';
import { ProviderProfile } from '../model/ProviderProfiles';
import { ExtensionSettings, SkillData } from '../model/Skills';
import { LiveResources, McpRequest } from '../model/ResourceManagement';
import { Cancellation } from './Cancellation';
import { AgentTools } from './AgentLoop';
import { ContextTokenItem } from '../model/ContextBreakdown';

export interface SessionRepository {
  load(): Promise<AppData>;
  save(data: AppData): Promise<void>;
}

export interface SessionResources {
  afterTask?(threadId: string, messageId: string, content: string): Promise<void>;
  createId(): string;
  ensureWorkspace(threadId: string): Promise<void>;
  tools(threadId: string, extensions: ExtensionSettings, selected: string, productivity?: ProductivityData, attachments?: Attachment[], live?: LiveResources): AgentTools;
  installSkill?(source: string, paths: string[], cancellation: Cancellation): Promise<SkillData>;
  prepareMcp?(server: McpServer, request: McpRequest, cancellation: Cancellation): Promise<McpServer>;
  testMcp?(server: McpServer, cancellation: Cancellation): Promise<number>;
  reportResources?(message: string): void;
  configureProviders(profiles: ProviderProfile[]): void;
  reportError(message: string): void;
  reportMemory?(message: string): void;
}

export type SessionPhase = 'idle' | 'loading' | 'saving' | 'running' | 'compacting' | 'memory' | 'team';

export interface SessionState {
  ready: boolean;
  phase: SessionPhase;
  error: string;
  saveError: string;
  contextStatus: string;
  contextTokens: number;
  contextBreakdown?: ContextTokenItem[];
  contextSource?: string;
  acceptingSteering: boolean;
}

// Structural changes carry detached snapshots; text events carry only the changed prose.
export interface SessionEvent {
  kind: 'snapshot' | 'message' | 'text' | 'reasoning' | 'draft' | 'state';
  state: SessionState;
  data?: AppData;
  threadId?: string;
  message?: MessageData;
  messageId?: string;
  content?: string;
  step?: number;
  stepContent?: string;
}
