import { BrowserPreview } from '../model/BrowserPreview';
import { LogFields } from '../model/DiagnosticLog';
import { TeamRun } from '../model/Team';
import { ProductivityData, Attachment, McpServer } from '../model/Productivity';
import { AppData, MessageData, ModelConfig, ThreadData } from '../model/Conversation';
import { ProviderProfile } from '../model/ProviderProfiles';
import { ExtensionSettings, SkillData } from '../model/Skills';
import { LiveResources, McpRequest } from '../model/ResourceManagement';
import { Cancellation } from './Cancellation';
import { AgentTools } from './AgentLoop';
import { ContextTokenItem } from '../model/ContextBreakdown';
import { ProjectData } from '../model/Project';
import { SharedFolder } from '../model/SharedFolders';
import { ToolExecution } from '../model/Agent';
import { FileAnnotation } from '../model/FileAnnotation';

export interface ThreadCheckpoint { threadId: string; messageId?: string; }

export interface SessionRepository {
  load(): Promise<AppData>;
  // Capture call-time values synchronously. Omitted IDs mean a full save; otherwise unchanged threads are reused.
  // A checkpoint can change only metadata, or one message in addition to metadata.
  save(data: AppData, changedThreadIds?: string[], checkpoint?: ThreadCheckpoint): Promise<void>;
}

export interface SessionResources {
  authorizeGeneration?(): Promise<void>;
  prepareGeneration?(): Promise<void>;
  recoverUi?(threadId: string, content: string, error: Error, cancellation: Cancellation, workspaceId?: string): Promise<string>;
  afterTask?(threadId: string, messageId: string, content: string, workspaceId?: string): Promise<void>;
  createId(): string;
  ensureWorkspace(threadId: string, workspaceId?: string): Promise<void>;
  prepareAttachments?(items: Attachment[], threadId: string, workspaceId?: string): Promise<Attachment[]>;
  verifyFileAnnotations?(threadId: string, items: FileAnnotation[], project?: ProjectData): Promise<void>;
  tools(threadId: string, extensions: ExtensionSettings, selected: string, productivity?: ProductivityData, attachments?: Attachment[], live?: LiveResources, workspaceId?: string, project?: ProjectData, resolvePreview?: (previewId: string) => BrowserPreview): AgentTools;
  persistProjectFolders?(folders: SharedFolder[]): Promise<void>;
  revokeProjectFolders?(folders: SharedFolder[]): Promise<void>;
  activateProjectFolders?(projects: ProjectData[]): Promise<void>;
  installSkill?(source: string, paths: string[], cancellation: Cancellation): Promise<SkillData>;
  prepareMcp?(server: McpServer, request: McpRequest, cancellation: Cancellation, confirm?: boolean): Promise<McpServer>;
  testMcp?(server: McpServer, cancellation: Cancellation): Promise<number>;
  reportResources?(event: string, fields?: LogFields): void;
  configureProviders(profiles: ProviderProfile[]): void;
  reportError(event: string, error: Error | string, fields?: LogFields): void;
  reportMemory?(event: string, fields?: LogFields): void;
}

export type SessionPhase = 'idle' | 'loading' | 'saving' | 'running' | 'compacting' | 'memory';

export interface SessionState {
  // phase/context/error describe the selected chat; these fields describe the application.
  runningThreadIds?: string[];
  canNavigate?: boolean;
  compatibilityWarnings?: string[];
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

export type SettingsToggle = 'autoMemory' | 'readOnly' | 'saveSummary' | 'autoCompact' | 'webEnabled' | 'miniAppsEnabled';

export interface SessionPreferences {
  config: ModelConfig;
  extensions: ExtensionSettings;
  productivity: ProductivityData;
}

export interface ReasoningSelection {
  threadIds: string[];
  value: string;
  config?: ModelConfig;
}

// Structural changes carry detached snapshots; preference changes omit transcripts.
export interface SessionEvent {
  kind: 'snapshot' | 'preferences' | 'reasoning-effort' | 'message' | 'tool' | 'text' | 'reasoning' | 'draft' | 'state' | 'thread' | 'teams' | 'task-complete';
  state: SessionState;
  preferences?: SessionPreferences;
  reasoningSelection?: ReasoningSelection;
  data?: AppData;
  thread?: ThreadData;
  teams?: TeamRun[];
  threadId?: string;
  message?: MessageData;
  messageId?: string;
  tool?: ToolExecution;
  parentToolCallId?: string;
  content?: string;
  step?: number;
  stepContent?: string;
}
