import { Attachment } from '../model/Productivity';
import { AgentMode } from '../model/AgentMode';
import { FileDiff } from '../model/FileDiff';
import { TurnFileChange } from '../model/TurnFileChanges';
import { MemoryReviewRecord } from '../model/MemoryMaintenance';
import { ThreadReference } from '../model/ThreadReferences';
import { AgentStep, ToolCall, ToolExecution, RequestRetry, PreviewScreenshot } from '../model/Agent';
import { CompactionData, MessageData, ThreadData } from '../model/Conversation';
import { ModelReference } from '../model/ProviderProfiles';
import { PendingInput } from '../model/PendingInput';
import { t } from '../model/I18n';
import { UiSavedState } from '../model/InteractiveUi';
import { UiPresentation } from '../model/UiPresentation';
import { latestPreviewIds } from '../model/PublishedPreview';
import { DisclosureStore } from './DisclosureState';
import { PlanProgressViewModel } from './PlanProgressViewModel';
import { buildTimeline, TimelineEntry } from '../model/ProcessPresentation';

@Observed
export class ToolExecutionViewModel implements ToolExecution {
  previewScreenshot?: PreviewScreenshot;
  previewContent?: string;
  turnFileChange?: TurnFileChange;
  fileDiff?: FileDiff;
  websiteIcon?: string;
  call: ToolCall;
  status: string;
  output: string;
  children: ToolExecution[] = [];
  constructor(data: ToolExecution) { this.previewScreenshot = data.previewScreenshot; this.previewContent = data.previewContent; this.turnFileChange = data.turnFileChange; this.fileDiff = data.fileDiff; this.websiteIcon = data.websiteIcon; this.call = data.call; this.status = data.status; this.output = data.output; this.children = data.children?.slice() || []; }
}

@Observed
export class AgentStepViewModel implements AgentStep {
  retries?: RequestRetry[];
  requestError?: string;
  uiValidation?: string;
  content: string = '';
  reasoningContent: string = '';
  steering?: PendingInput;
  tools: ToolExecutionViewModel[] = [];
  constructor(data: AgentStep) { this.update(data); }
  update(data: AgentStep): void {
    this.retries = data.retries?.map((retry): RequestRetry => ({ attempt: retry.attempt, delayMs: retry.delayMs, code: retry.code, waiting: retry.waiting }));
    this.requestError = data.requestError;
    this.uiValidation = data.uiValidation;
    this.content = data.content; this.reasoningContent = data.reasoningContent || ''; this.steering = data.steering;
    this.tools = data.tools.map((tool: ToolExecution, index: number) => {
      const existing = this.tools[index];
      if (existing && existing.call.id === tool.call.id) {
        existing.output = tool.output; existing.previewScreenshot = tool.previewScreenshot; existing.previewContent = tool.previewContent;
        existing.turnFileChange = tool.turnFileChange; existing.fileDiff = tool.fileDiff; existing.websiteIcon = tool.websiteIcon; existing.children = tool.children?.slice() || [];
        // Status observers may render synchronously: publish the complete receipt first.
        existing.status = tool.status;
        return existing;
      }
      return new ToolExecutionViewModel(tool);
    });
  }
}

@Observed
export class MessageViewModel {
  uiPresentation: UiPresentation = new UiPresentation();
  plan: PlanProgressViewModel = new PlanProgressViewModel();
  uiStates: UiSavedState[] = [];
  references: ThreadReference[] = [];
  // Deliberately excluded from MessageData: keep reading choices across live updates,
  // while newly loaded history starts with compact defaults.
  processOpen: boolean = false;
  usageOpen: boolean = false;
  disclosures: DisclosureStore = new DisclosureStore();
  // Aggregate only when requested; token updates must not concatenate all prior thoughts.
  get reasoningContent(): string {
    return this.stepViews.filter((step) => !step.requestError).map((step) => step.reasoningContent).filter((text) => text.length > 0).join('\n\n');
  }
  attachments: Attachment[] = [];
  id: string = '';
  role: string = '';
  content: string = '';
  status: string = '';
  error: string = '';
  steps: AgentStep[] = [];
  stepViews: AgentStepViewModel[] = [];
  timeline: TimelineEntry[] = [];
  modelRef?: ModelReference;
  constructor(data: MessageData) { this.update(data); }
  updateReasoning(index: number, content: string): void {
    const step = this.stepViews[index];
    if (!step) { return; }
    const hadThought = step.reasoningContent.trim().length > 0;
    step.reasoningContent = content;
    if (hadThought !== (content.trim().length > 0)) { this.timeline = buildTimeline(this.stepViews); }
  }
  updateText(content: string, index: number, stepContent: string): void {
    this.content = content;
    const step = this.stepViews[index];
    if (!step) { return; }
    const hadText = step.content.trim().length > 0;
    step.content = stepContent;
    if (hadText !== (stepContent.trim().length > 0)) { this.timeline = buildTimeline(this.stepViews); }
  }
  update(data: MessageData): void {
    this.uiStates = data.uiStates || [];
    this.references = data.references || [];
    this.id = data.id; this.role = data.role; this.content = data.content; this.status = data.status; this.error = data.error;
    this.attachments = data.attachments || [];
    this.modelRef = data.modelRef; this.steps = data.steps || [];
    this.plan.update(this.steps, data.status);
    this.stepViews = this.steps.map((step: AgentStep, index: number) => {
      const existing = this.stepViews[index];
      if (existing) { existing.update(step); return existing; }
      return new AgentStepViewModel(step);
    });
    this.timeline = buildTimeline(this.stepViews);
  }
}

@Observed
export class ThreadViewModel {
  latestPreviewIds: string[] = [];
  refreshPreviews(): void {
    const ids = latestPreviewIds(this.messages);
    if (ids.length !== this.latestPreviewIds.length || ids.some((id, index) => id !== this.latestPreviewIds[index])) {
      this.latestPreviewIds = ids;
    }
  }
  agentMode: AgentMode = 'full';
  disabledTools: string[] = [];
  projectId?: string;
  memoryReview?: MemoryReviewRecord;
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
  updateMetadata(data: ThreadData): void {
    this.agentMode = data.agentMode || 'full'; this.disabledTools = data.disabledTools || [];
    this.projectId = data.projectId;
    this.memoryReview = data.memoryReview;
    this.reasoningEffort = data.reasoningEffort || 'default';
    this.references = data.references || [];
    this.teamEnabled = data.teamEnabled === true;
    this.parentThreadId = data.parentThreadId; this.parentMessageId = data.parentMessageId; this.disabledMcpIds = data.disabledMcpIds || [];
    this.id = data.id; this.title = data.title; this.updatedAt = data.updatedAt;
    this.pinned = data.pinned === true; this.archived = data.archived === true; this.titleEdited = data.titleEdited === true;
    this.attachments = data.attachments || [];
    this.draft = data.draft || ''; this.compaction = data.compaction; this.modelRef = data.modelRef;
    this.pendingInputs = data.pendingInputs || []; this.queuePaused = data.queuePaused === true;
  }
  update(data: ThreadData): void {
    this.updateMetadata(data);
    const existing = new Map<string, MessageViewModel>();
    for (const message of this.messages) { existing.set(message.id, message); }
    this.messages = data.messages.map((message: MessageData) => {
      const view = existing.get(message.id);
      if (view) { view.update(message); return view; }
      return new MessageViewModel(message);
    });
    this.refreshPreviews();
  }
}
