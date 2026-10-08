import { Attachment } from '../model/Productivity';
import { ThreadReference } from '../model/ThreadReferences';
import { AgentStep, ToolCall, ToolExecution } from '../model/Agent';
import { CompactionData, MessageData, ThreadData } from '../model/Conversation';
import { ModelReference } from '../model/ProviderProfiles';
import { PendingInput } from '../model/PendingInput';
import { t } from '../model/I18n';
import { UiSavedState } from '../model/InteractiveUi';
import { DisclosureStore } from './DisclosureState';

@Observed
export class ToolExecutionViewModel implements ToolExecution {
  call: ToolCall;
  status: string;
  output: string;
  constructor(data: ToolExecution) { this.call = data.call; this.status = data.status; this.output = data.output; }
}

@Observed
export class AgentStepViewModel implements AgentStep {
  content: string = '';
  reasoningContent: string = '';
  steering?: PendingInput;
  tools: ToolExecutionViewModel[] = [];
  constructor(data: AgentStep) { this.update(data); }
  update(data: AgentStep): void {
    this.content = data.content; this.reasoningContent = data.reasoningContent || ''; this.steering = data.steering;
    this.tools = data.tools.map((tool: ToolExecution, index: number) => {
      const existing = this.tools[index];
      if (existing && existing.call.id === tool.call.id) { existing.status = tool.status; existing.output = tool.output; return existing; }
      return new ToolExecutionViewModel(tool);
    });
  }
}

@Observed
export class MessageViewModel {
  uiStates: UiSavedState[] = [];
  references: ThreadReference[] = [];
  // Deliberately excluded from MessageData: keep reading choices across live updates,
  // while newly loaded history starts with compact defaults.
  processOpen: boolean = false;
  usageOpen: boolean = false;
  disclosures: DisclosureStore = new DisclosureStore();
  reasoningContent: string = '';
  attachments: Attachment[] = [];
  id: string = '';
  role: string = '';
  content: string = '';
  status: string = '';
  error: string = '';
  steps: AgentStep[] = [];
  stepViews: AgentStepViewModel[] = [];
  modelRef?: ModelReference;
  constructor(data: MessageData) { this.update(data); }
  update(data: MessageData): void {
    this.uiStates = data.uiStates || [];
    this.references = data.references || [];
    this.id = data.id; this.role = data.role; this.content = data.content; this.status = data.status; this.error = data.error;
    this.attachments = data.attachments || [];
    this.modelRef = data.modelRef; this.steps = data.steps || [];
    this.reasoningContent = this.steps.map((step) => step.reasoningContent || '').filter((text) => text.length > 0).join('\n\n');
    this.stepViews = this.steps.map((step: AgentStep, index: number) => {
      const existing = this.stepViews[index];
      if (existing) { existing.update(step); return existing; }
      return new AgentStepViewModel(step);
    });
  }
}

@Observed
export class ThreadViewModel {
  reasoningEffort: string = 'default';
  references: ThreadReference[] = [];
  get displayTitle(): string {
    return !this.titleEdited && this.messages.length === 0 && (this.title === '新对话' || this.title === 'New chat') ? t('新对话') : this.title;
  }
  teamEnabled: boolean = false;
  parentThreadId?: string;
  parentMessageId?: string;
  disabledMcpIds: string[] = [];
  attachments: Attachment[] = [];
  id: string = '';
  title: string = '';
  updatedAt: number = 0;
  messages: MessageViewModel[] = [];
  pinned: boolean = false;
  archived: boolean = false;
  titleEdited: boolean = false;
  draft: string = '';
  compaction?: CompactionData;
  modelRef?: ModelReference;
  pendingInputs: PendingInput[] = [];
  queuePaused: boolean = false;
  constructor(data: ThreadData) { this.update(data); }
  update(data: ThreadData): void {
    this.reasoningEffort = data.reasoningEffort || 'default';
    this.references = data.references || [];
    this.teamEnabled = data.teamEnabled === true;
    this.parentThreadId = data.parentThreadId; this.parentMessageId = data.parentMessageId; this.disabledMcpIds = data.disabledMcpIds || [];
    this.id = data.id; this.title = data.title; this.updatedAt = data.updatedAt;
    this.pinned = data.pinned === true; this.archived = data.archived === true; this.titleEdited = data.titleEdited === true;
    this.attachments = data.attachments || [];
    this.draft = data.draft || ''; this.compaction = data.compaction; this.modelRef = data.modelRef;
    this.pendingInputs = data.pendingInputs || []; this.queuePaused = data.queuePaused === true;
    const existing = new Map<string, MessageViewModel>();
    for (const message of this.messages) { existing.set(message.id, message); }
    this.messages = data.messages.map((message: MessageData) => {
      const view = existing.get(message.id);
      if (view) { view.update(message); return view; }
      return new MessageViewModel(message);
    });
  }
}
