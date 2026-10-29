import { Diagnostics } from '../model/Diagnostics';
import { HuaweiAccount } from '../services/HuaweiAccount';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { systemMaterialAttribute } from '../common/MaterialAttributes';
import { t } from '../model/I18n';
import { agentModeName } from '../model/AgentMode';
import { ProjectData } from '../model/Project';
import { AnswerSpeech } from '../services/AnswerSpeech';
import { LaunchActions } from '../services/LaunchActions';
import { supportsReasoningEffort, reasoningEfforts, reasoningEffortName, isHighestReasoningEffort } from '../model/ReasoningEffort';
import { ComposerGlow } from '../common/ComposerGlow';
import { ReasoningEffortPicker } from './ReasoningEffortPicker';
import { ModelPickerPanel } from './ModelPickerPanel';
import { SpeechInput } from '../services/SpeechInput';
import { DictationDraft } from '../model/DictationDraft';
import { VoiceHoldButton } from '../common/VoiceHoldButton';
import { VoiceRecordingOverlay } from '../common/VoiceRecordingOverlay';
import { VoiceAction, VoiceTargetRect, voiceActionAtPoint } from '../model/VoiceGesture';
import { pasteboard } from '@kit.BasicServicesKit';
import { ThreadReference, referenceQuery } from '../model/ThreadReferences';
import { ThreadReferenceCard } from './ThreadReferenceCard';
import { curves, FrameCallback, SymbolGlyphModifier } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { Attachment, MAX_MESSAGE_ATTACHMENTS, PromptTemplate } from '../model/Productivity';
import { Attachments } from '../services/Attachments';
import { AttachmentDrop, ATTACHMENT_DROP_TYPES, importDroppedAttachments } from '../services/AttachmentDrop';
import { image } from '@kit.ImageKit';
import { DrawingBoardOptions, DrawingDraft } from '../model/DrawingDraft';
import { deviceInfo } from '@kit.BasicServicesKit';
import { SkillData } from '../model/Skills';
import { SkillQuery, matchingSkills, skillDisplayName, skillDraft, skillQuery } from '../model/SkillCompletion';
import { builtinSkillInfo } from '../model/BuiltinSkills';
import { selectAttachments } from '../services/NativeActions';
import { ToolApproval } from '../services/ToolApproval';
import { BrowserSession } from '../services/BrowserSession';
import { BrowserStatusCard } from './BrowserPanel';
import { InputFormCard } from './InputFormCard';
import { ChatTeamCard } from './ChatTeamCard';
import { ChatPlanPanel } from './ChatPlanPanel';
import { MemoryDraftPanel } from './MemoryDraftPanel';
import { ChatViewModel, MessageViewModel, ThreadViewModel } from '../viewmodel/ChatViewModel';
import { UiValues } from '../model/InteractiveUi';
import { MessageBubble } from './MessageBubble';
import { ImageViewer } from './ImageViewer';
import { InputQueuePanel } from './InputQueuePanel';
import { ContextDetails } from './ContextDetails';
import { Btn, Font, Motion, Radius, Space, fileSize, systemInsets } from '../common/Theme';
import { Banner, IconBadge, IconButton } from '../common/Widgets';
import { WindowViewport } from '../viewmodel/WindowViewport';
import { MessageListSource } from '../viewmodel/MessageListSource';
import { SendFrame, SendOrigin } from '../common/SendBubbleMotion';

// onFrame runs before dirty properties are applied. Focus needs the editor's rendered visibility and focusability.
class ComposerKeyboardFrame extends FrameCallback {
  private action: () => void;
  constructor(action: () => void) { super(); this.action = action; }
  onIdle(): void { this.action(); }
}

@Component
export struct ChatPanel {
  @ObjectLink account: HuaweiAccount;
  onAccount: () => void = () => {};
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink @Watch('syncMessages') app: ChatViewModel;
  @ObjectLink @Watch('syncMessages') thread: ThreadViewModel;
  private messageSource: MessageListSource = new MessageListSource();
  private syncMessages(): void {
    this.messageSource.update(this.thread.id, this.app.visibleMessages);
  }
  @Prop topInset: number = 0;
  @Prop workbench: boolean = false;
  @State private panelHeight: number = 0;
  onToolScope: () => void = () => {};
  onHeaderProgress: (progress: number) => void = () => {};
  private lastHeaderProgress: number = -1;
  @Prop @Watch('speechAvailabilityChanged') speechEnabled: boolean = true;
  @StorageProp('tinybot.foreground') @Watch('focusForegroundChanged') private foreground: boolean = true;
  private focusOwner: number = 0;
  @Prop @Watch('speechThreadChanged') activeThreadId: string = '';
  @Prop @Watch('receiveVoiceShortcut') voiceRequest: string = '';
  private consumedVoiceRequest: string = '';
  onVoiceShortcutConsumed: () => void = () => {};
  onSettings: () => void = () => {};
  onHistoryDragStart: (event: GestureEvent) => void = () => {};
  onHistoryDragUpdate: (event: GestureEvent) => void = () => {};
  onHistoryDragEnd: (event: GestureEvent) => void = () => {};
  onHistoryDragCancel: () => void = () => {};
  onFiles: () => void = () => {};
  onOpenFile: (path: string) => void = () => {};
  @Prop previewInspectable: boolean = false;
  @Prop inspectedPreviewId: string = '';
  onInspectPreview: (messageId: string, previewId: string) => void = () => {};
  onTools: (tab: string) => void = () => {};
  @ObjectLink approval: ToolApproval;
  @ObjectLink browser: BrowserSession;
  onBrowser: () => void = () => {};
  @State private importing: boolean = false;
  @State private dropHover: boolean = false;
  private attachmentDrop: AttachmentDrop = new AttachmentDrop();
  private dropGeneration: number = 0;
  @State private showPlus: boolean = false;
  private pendingPlusAction?: () => void;
  private plusActionThreadId: string = '';
  private plusMenuTimer: number = -1;
  // Tablets open the add actions as a menu above the plus; phones keep the sheet.
  @State private showPlusMenu: boolean = false;
  @State private plusPane: string = 'root';
  @State private showModelMenu: boolean = false;
  @State private showDrawing: boolean = false;
  @State private drawingDraft: DrawingDraft = new DrawingDraft();
  private drawingThreadId: string = '';
  private drawingOpening: boolean = false;
  private drawingBuilder?: WrappedBuilder<[DrawingBoardOptions]>;
  @State private speech: SpeechInput = new SpeechInput();
  @State private voiceMode: boolean = false;
  @State private speechHolding: boolean = false;
  @State private speechTarget: VoiceAction = 'send';
  private speechOutcome?: VoiceAction;
  private cancelVoiceRect?: VoiceTargetRect;
  private editVoiceRect?: VoiceTargetRect;
  private composerController: TextAreaController = new TextAreaController();
  private keyboardFocusRequest: number = 0;
  @State private reading: AnswerSpeech = new AnswerSpeech();
  @State private unwrittenSpeech: string = '';
  private dictationDraft?: DictationDraft;
  private speechThreadId: string = '';
  @State private showApprovalDetails: boolean = false;
  @State private previewing: boolean = false;
  @State private previewPath: string = '';
  private inspectingOutput: boolean = false;
  @State private followOutput: boolean = true;
  @State private atBottom: boolean = true;
  @State private showContext: boolean = false;
  @State private insetBottom: number = 0;
  @State private showQueue: boolean = false;
  @State private showSummary: boolean = false;
  @State private showMemoryDraft: boolean = false;
  @State private memoryMessageId: string = '';
  @State private memoryThreadId: string = '';
  @State private composerFocused: boolean = false;
  @State private composerSelectionStart: number = -1;
  @State private composerSelectionEnd: number = -1;
  @State private sendingMessageId: string = '';
  @State private sendOrigin: SendOrigin | undefined = undefined;
  @State private viewport: WindowViewport = new WindowViewport();
  @State private showReasoning: boolean = false;
  @State private reasoningPreview: string = '';
  @State private reasoningPreviewKey: string = '';
  private reasoningSaving: boolean = false;

  private scroller: Scroller = new Scroller();
  private scrollTimer: number = -1;
  private scrollStopTimer: number = -1;
  // Messages already on screen when a thread opens render in place; only later ones animate in.
  private baselineThread: string = '';
  private baseline: Set<string> = new Set<string>();
  private isLive(id: string): boolean {
    if (this.baselineThread !== this.thread.id) {
      this.baselineThread = this.thread.id;
      this.baseline = new Set<string>(this.thread.messages.map((item: MessageViewModel) => item.id));
    }
    return !this.baseline.has(id);
  }
  // The user's turn lifts in first; the answer follows a beat later.
  private messageEnter(message: MessageViewModel): TransitionEffect {
    if (message.id === this.sendingMessageId) { return TransitionEffect.IDENTITY; }
    if (!this.isLive(message.id)) { return TransitionEffect.IDENTITY; }
    return message.role === 'user' ? Motion.rise(0, 16) : Motion.rise(2, 10);
  }
  private locate(): void {
    const index = this.app.visibleMessages.findIndex((item) => item.id === this.app.searchMessageId);
    if (index >= 0) { this.followOutput = false; this.scroller.scrollToIndex(index + (this.thread.messages.length > this.app.visibleMessageCount ? 1 : 0), false, ScrollAlign.CENTER); }
  }

  aboutToAppear(): void {
    this.syncMessages();
    systemInsets(this.getUIContext()).then((insets: number[]) => { this.insetBottom = insets[1]; });
    this.viewport.onKeyboard = (shown: boolean): void => {
      if (shown && this.composerFocused) { this.inspectingOutput = false; this.followOutput = true; this.follow(); }
    };
    this.viewport.observe(this.getUIContext());
    this.speech.onResult = (text: string): void => {
      if (!this.dictationDraft || this.speechThreadId !== this.app.active.id || !this.speechEnabled) {
        this.endSpeech(); return;
      }
      // Partial recognition stays in the floating preview; cancellation never edits the existing draft.
    };
    this.speech.onComplete = (): void => { if (!this.speechHolding) { this.completeSpeech(); } };
    this.speech.onError = (): void => {
      this.speechHolding = false; this.speechOutcome = undefined; this.speechTarget = 'send';
      // An interrupted recognition is recoverable text, never an automatically sent message.
      if (this.applySpeechDraft()) { this.voiceMode = false; this.app.flushDraft(); }
    };
    this.speech.onBackground = (): void => this.endSpeech();
    this.receiveVoiceShortcut();
  }

  aboutToDisappear(): void {
    this.focusOwner++;
    this.cancelPlusAction();
    this.cancelAttachmentDrop();
    this.setScrollActivity(false);
    this.viewport.dispose();
    this.endSpeech();
    this.reading.stop();
    clearTimeout(this.scrollTimer);
  }

  private setScrollActivity(scrolling: boolean): void {
    clearTimeout(this.scrollStopTimer); this.scrollStopTimer = -1;
    if (AppStorage.get<boolean>('tinybot.chat.scrolling') === scrolling) { return; }
    AppStorage.setOrCreate('tinybot.chat.scrolling', scrolling);
    if (Diagnostics.recording) { Diagnostics.event('scroll.activity', { enabled: scrolling ? 1 : 0 }); }
  }

  private stopScrollActivity(): void {
    clearTimeout(this.scrollStopTimer);
    // A brief pause between successive gestures must not cold-start a preview.
    this.scrollStopTimer = setTimeout(() => { this.setScrollActivity(false); }, 200);
  }

  private voiceOverlayVisible(): boolean { return this.speechHolding || this.speechActive(); }

  private speechActive(): boolean {
    return this.speech.phase === 'preparing' || this.speech.phase === 'listening' || this.speech.phase === 'finishing';
  }
  private speechAvailabilityChanged(): void {
    if (!this.speechEnabled) { this.focusOwner++; this.cancelPlusAction(); this.endSpeech(); this.reading.stop(); }
    else { this.receiveVoiceShortcut(); }
  }
  private focusForegroundChanged(): void {
    if (!this.foreground) { this.focusOwner++; this.keyboardFocusRequest++; this.cancelPlusAction(); }
  }
  private speechThreadChanged(): void {
    this.cancelPlusAction();
    this.cancelAttachmentDrop();
    this.composerSelectionStart = -1; this.composerSelectionEnd = -1;
    this.lastHeaderProgress = -1;
    this.onHeaderProgress(0);
    this.sendingMessageId = ''; this.sendOrigin = undefined;
    if (this.speechThreadId !== this.activeThreadId) { this.endSpeech(); }
    this.reading.stop();
    this.receiveVoiceShortcut();
  }
  private receiveVoiceShortcut(): void {
    if (!this.voiceRequest || this.voiceRequest === this.consumedVoiceRequest ||
      this.voiceRequest !== this.activeThreadId || this.voiceRequest !== this.thread.id || !this.speechEnabled) { return; }
    this.consumedVoiceRequest = this.voiceRequest;
    this.onVoiceShortcutConsumed();
    if (LaunchActions.isForeground()) { this.enterVoiceMode(); }
  }
  private readAnswer(id: string): void {
    if (this.reading.messageId === id) { this.reading.stop(); return; }
    const message = this.thread.messages.find((item: MessageViewModel) => item.id === id);
    if (!message || message.role !== 'assistant' || message.status === 'generating' || !this.speechEnabled) { return; }
    this.endSpeech();
    this.reading.start(this.getUIContext().getHostContext() as common.UIAbilityContext, id, message.content);
  }
  private enterVoiceMode(): void {
    this.keyboardFocusRequest++;
    this.getUIContext().getFocusController().clearFocus();
    this.composerFocused = false; this.voiceMode = true;
  }
  private showSpeechKeyboard(): void {
    this.voiceMode = false;
    const threadId = this.thread.id;
    const request = ++this.keyboardFocusRequest;
    this.getUIContext().postFrameCallback(new ComposerKeyboardFrame(() => {
      if (request !== this.keyboardFocusRequest || this.thread.id !== threadId || this.app.active.id !== threadId ||
        !this.speechEnabled || !this.foreground || this.showPlus || this.showPlusMenu || this.showDrawing || this.previewing ||
        this.showContext || this.showQueue || this.showSummary || this.showMemoryDraft || this.showReasoning || this.showModelMenu ||
        this.thread.archived || this.voiceMode || this.speechActive()) { return; }
      if (Diagnostics.acceptsLog('debug')) { Diagnostics.log('debug', 'voice', 'focus_requested', { request: request }); };
      this.getUIContext().getFocusController().requestFocus('composer');
      this.composerController.caretPosition(this.app.draft.length);
    }));
  }
  private canRecordSpeech(): boolean {
    return this.app.ready && this.speechEnabled && !this.thread.archived && !this.app.saveError && !this.importing &&
      !this.speech.permissionSettingsPending && (!this.app.busy || this.app.canQueueInput);
  }
  private startSpeech(): boolean {
    if (this.speechActive() || !this.canRecordSpeech()) { return false; }
    this.reading.stop();
    this.getUIContext().getFocusController().clearFocus();
    this.voiceMode = true; this.speechHolding = true; this.speechTarget = 'send'; this.speechOutcome = undefined;
    this.cancelVoiceRect = undefined; this.editVoiceRect = undefined;
    this.speechThreadId = this.app.active.id;
    this.dictationDraft = new DictationDraft(this.app.draft);
    this.unwrittenSpeech = '';
    this.speech.start(this.getUIContext().getHostContext() as common.UIAbilityContext);
    return true;
  }
  private moveSpeech(x: number, y: number): void {
    if (this.speechHolding) { this.speechTarget = voiceActionAtPoint(x, y, this.cancelVoiceRect, this.editVoiceRect); }
  }
  private cancelSpeechHold(): void { if (this.speechHolding) { this.endSpeech(); } }
  private releaseSpeech(action: VoiceAction = this.speechTarget): void {
    if (!this.dictationDraft) { return; }
    this.speechHolding = false;
    if (Diagnostics.acceptsLog('debug')) { Diagnostics.log('debug', 'voice', 'released', { action: action, phase: this.speech.phase, chars: this.speech.text.length }); };
    if (action === 'cancel' || this.speech.phase === 'preparing') {
      this.endSpeech();
      if (action === 'edit') { this.showSpeechKeyboard(); }
      return;
    }
    this.speechOutcome = action;
    if (this.speech.phase === 'complete') { this.completeSpeech(); }
    else { this.speech.finish(); }
  }
  private applySpeechDraft(): boolean {
    const transaction = this.dictationDraft; this.dictationDraft = undefined;
    if (!transaction || this.speechThreadId !== this.app.active.id || !this.speechEnabled || !this.speech.text.trim()) { return false; }
    try { this.app.setDraft(transaction.update(this.app.draft, this.speech.text)); return true; }
    catch (error) {
      this.unwrittenSpeech = this.speech.text; this.speech.error = (error as Error).message; this.speech.phase = 'error';
      Diagnostics.log('error', 'voice', 'draft_failed', undefined, this.speech.error); return false;
    }
  }
  private completeSpeech(): void {
    const action = this.speechOutcome; this.speechOutcome = undefined;
    if (!action || !this.dictationDraft) { return; }
    if (!this.speech.text.trim()) {
      this.endSpeech();
      if (action === 'edit') { this.showSpeechKeyboard(); }
      else { this.getUIContext().getPromptAction().showToast({ systemMaterial: this.appearance.surface, message: t('未识别到文字，请重试。') }); }
      return;
    }
    if (!this.applySpeechDraft()) { return; }
    this.speech.cancel(); this.speechTarget = 'send';
    if (action === 'edit') { this.showSpeechKeyboard(); this.app.flushDraft(); }
    else if (this.canSend()) { this.send(); }
    else if (this.app.generating && this.app.canQueueInput) { this.app.enqueueInput('followUp'); }
    else {
      this.voiceMode = false; this.app.flushDraft();
      this.speech.error = t('识别文字已保留为草稿，当前无法发送。');
    }
  }
  private endSpeech(): void {
    this.keyboardFocusRequest++;
    this.dictationDraft = undefined; this.speechOutcome = undefined; this.speechHolding = false; this.speechTarget = 'send';
    this.cancelVoiceRect = undefined; this.editVoiceRect = undefined;
    this.speech.cancel();
  }
  private async speechErrorAction(): Promise<void> {
    if (this.unwrittenSpeech) {
      try {
        await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.unwrittenSpeech));
        this.getUIContext().getPromptAction().showToast({ systemMaterial: this.appearance.surface, message: t('已复制') });
        this.unwrittenSpeech = ''; this.speech.error = '';
      } catch (error) { this.speech.error = t('复制失败：') + (error as Error).message; }
    } else if (this.speech.permissionDenied) {
      this.enterVoiceMode();
      await this.speech.requestPermissionSetting(this.getUIContext().getHostContext() as common.UIAbilityContext);
    }
    else { this.speech.error = ''; }
  }

  private follow(): void {
    if (!this.followOutput || this.sendingMessageId || this.scrollTimer !== -1) {
      return;
    }
    this.scrollTimer = setTimeout(() => {
      this.scrollTimer = -1;
      if (this.followOutput && this.thread.messages.length > 0) {
        if (Diagnostics.recording) { Diagnostics.event('scroll.follow'); }
        this.scroller.scrollEdge(Edge.Bottom);
      }
    }, 80);
  }
  private messageAreaChanged(id: string, previous: Area, current: Area): void {
    if (Diagnostics.recording) {
      Diagnostics.measure('layout.messageCallback', 1, 'count');
      if (previous.height !== current.height || previous.width !== current.width) {
        Diagnostics.event('layout.message', { previousHeightVp: Number(previous.height), heightVp: Number(current.height), following: this.followOutput ? 1 : 0 });
      }
    }
    if (previous.height !== current.height && id === this.thread.messages[this.thread.messages.length - 1]?.id) {
      this.follow();
    }
  }

  private scrollToLatest(): void {
    this.inspectingOutput = false;
    // Resume following at onReachEnd so streaming updates cannot interrupt the native spring's soft landing.
    this.followOutput = false;
    clearTimeout(this.scrollTimer); this.scrollTimer = -1;
    const earlier = this.app.visibleMessageCount < this.thread.messages.length ? 1 : 0;
    const team = this.app.teams.some((run) => !run.ownerMessageId) ? 1 : 0;
    const lastIndex = earlier + this.app.visibleMessages.length + team - 1;
    this.scroller.scrollToIndex(lastIndex, true, ScrollAlign.END);
  }

  private updateHeaderProgress(): void {
    // Item coordinates already include contentStartOffset; no accumulated gesture deltas or offset baselines.
    const first = this.scroller.getItemRect(0);
    const distance = this.topInset + Space.sm - first.y;
    const fraction = first.height > 0 ? Math.max(0, Math.min(1, distance / 96)) : 1;
    const progress = fraction * fraction * (3 - 2 * fraction);
    if (progress !== this.lastHeaderProgress) {
      this.lastHeaderProgress = progress;
      this.onHeaderProgress(progress);
    }
  }

  private uiHandler(threadId: string, messageId: string): (key: string, values: UiValues, action: string) => Promise<UiValues> {
    return (key: string, values: UiValues, action: string) => this.app.interactUi(threadId, messageId, key, values, action);
  }
  private send(): void {
    if (this.speechActive()) { return; }
    if (!this.account.signedIn) { this.onAccount(); return; }
    this.inspectingOutput = false; this.followOutput = true;
    const context = this.getUIContext();
    const composer = context.getComponentUtils().getRectangleById('composer');
    const viewport = context.getComponentUtils().getRectangleById('chat-swipe-area');
    const origin: SendOrigin = { x: context.px2vp(composer.windowOffset.x + composer.size.width / 2),
      y: context.px2vp(composer.windowOffset.y + composer.size.height / 2),
      height: context.px2vp(composer.size.height), viewportHeight: context.px2vp(viewport.size.height) };
    const threadId = this.thread.id;
    const previous = new Set(this.thread.messages.map((message: MessageViewModel) => message.id));
    let accepted = false;
    this.app.send(() => {
      if (this.thread.id !== threadId) { return; }
      if (!accepted) {
        const message = this.thread.messages.find((item: MessageViewModel) => item.role === 'user' && !previous.has(item.id));
        if (message) {
          accepted = true; this.sendOrigin = origin; this.sendingMessageId = message.id;
          this.keyboardFocusRequest++;
          context.getFocusController().clearFocus(); this.composerFocused = false;
          clearTimeout(this.scrollTimer); this.scrollTimer = -1;
          context.postFrameCallback(new SendFrame(() => {
            if (this.thread.id === threadId && this.sendingMessageId === message.id) { this.scroller.scrollEdge(Edge.Bottom); }
          }));
        }
      }
      this.follow();
    });
  }

  private finishSendFlight(id: string): void {
    if (this.sendingMessageId !== id) { return; }
    this.sendingMessageId = ''; this.sendOrigin = undefined; this.follow();
  }

  // Use methods: ordinary accessors in a V1 @Component are omitted by the ArkUI compiler.
  private hasDraft(): boolean {
    return this.app.draft.trim().length > 0 || this.thread.attachments.length > 0 || this.thread.references.length > 0;
  }

  private composerExpanded(): boolean {
    if (this.voiceMode) { return false; }
    return this.workbench || this.composerFocused || this.app.draft.length > 0 || this.hasDraft() || this.importing || this.speechActive() ||
      this.app.generating || this.thread.pendingInputs.length > 0 || this.showPlus || this.showPlusMenu || this.showContext ||
      this.showReasoning || this.showModelMenu || this.showQueue;
  }

  private canSend(): boolean {
    return !this.speechActive() && this.app.ready && !this.app.busy && !this.importing && !this.thread.archived && this.hasDraft() && this.app.saveError.length === 0;
  }

  private cancelAttachmentDrop(): void {
    this.dropGeneration++; this.dropHover = false;
    try { this.attachmentDrop.cancel(this.getUIContext()); }
    catch (error) { this.app.error = t('添加拖入附件失败：') + (error as Error).message; }
  }

  private dropEditable(): boolean {
    return this.app.ready && !this.app.busy && !this.speechActive() && !this.thread.archived &&
      !this.showDrawing && !this.previewing && this.app.saveError.length === 0;
  }

  private dragAttachment(event: DragEvent): void {
    this.dropHover = this.dropEditable() && !this.importing && this.thread.attachments.length < MAX_MESSAGE_ATTACHMENTS;
    event.setResult(this.dropHover ? DragResult.DROP_ENABLED : DragResult.DROP_DISABLED);
    event.dragBehavior = DragBehavior.COPY;
  }

  private composerDrop(event: DragEvent): void {
    // Keep the TextArea's native text insertion; file drops use the same handler as the surrounding chat.
    const types = Object.keys(event.getSummary().summary);
    if (types.length > 0 && types.every((type: string) =>
      ['general.plain-text', 'general.text', 'general.hyperlink', 'general.html'].includes(type))) { return; }
    this.receiveAttachmentDrop(event);
  }

  private async receiveAttachmentDrop(event: DragEvent): Promise<void> {
    this.dropHover = false;
    event.dragBehavior = DragBehavior.COPY;
    if (!this.dropEditable() || this.importing || this.thread.attachments.length >= MAX_MESSAGE_ATTACHMENTS) {
      event.setResult(DragResult.DRAG_FAILED);
      this.app.error = this.thread.attachments.length >= MAX_MESSAGE_ATTACHMENTS ?
        t('每条消息最多添加 {0} 个附件。', [MAX_MESSAGE_ATTACHMENTS]) : t('当前无法添加附件，请稍后重试。');
      return;
    }
    const threadId = this.thread.id; const generation = this.dropGeneration;
    const maximum = MAX_MESSAGE_ATTACHMENTS - this.thread.attachments.length;
    this.importing = true;
    try {
      const pending = this.attachmentDrop.load(event);
      // This acknowledges ownership of the drop; the attachment strip stays busy until persistence completes.
      event.setResult(DragResult.DRAG_SUCCESSFUL);
      const data = await pending;
      await importDroppedAttachments(data, maximum,
        () => generation === this.dropGeneration && threadId === this.app.active.id && this.dropEditable(),
        async (items: Attachment[]): Promise<void> => {
          if (!await this.app.setAttachments(this.thread.attachments.concat(items))) {
            throw new Error(this.app.saveError || this.app.error || t('当前无法添加附件，请稍后重试。'));
          }
        });
    } catch (error) { this.app.error = t('添加拖入附件失败：') + (error as Error).message; }
    finally { this.importing = false; }
  }

  private async attach(photo: boolean): Promise<void> {
    if (this.importing || this.app.busy) { return; }
    this.importing = true; const id = this.thread.id;
    try {
      const items = await selectAttachments(this.getUIContext().getHostContext() as common.UIAbilityContext, photo, MAX_MESSAGE_ATTACHMENTS - this.thread.attachments.length);
      if (id !== this.app.active.id) { throw new Error(t("对话已切换，请在当前对话重新添加附件。")); }
      await this.app.setAttachments(this.thread.attachments.concat(items));
    } catch (error) { this.app.error = (error as Error).message; }
    finally { this.importing = false; }
  }
  private remember(messageId: string): void {
    if (this.app.busy || this.app.saveError) { this.app.error = t("请等待当前任务完成并保存后再提炼记忆。"); return; }
    this.getUIContext().getFocusController().clearFocus();
    this.memoryMessageId = messageId; this.memoryThreadId = this.thread.id; this.showMemoryDraft = true;
  }
  private async openDrawing(): Promise<void> {
    if (this.drawingOpening || this.showDrawing || !this.canAttach() || this.thread.attachments.length >= MAX_MESSAGE_ATTACHMENTS) { return; }
    if (deviceInfo.productModel === 'emulator' || !canIUse('SystemCapability.Stylus.Handwrite')) {
      this.app.error = t('此设备不支持系统手写画板。'); return;
    }
    const threadId = this.thread.id;
    this.drawingOpening = true;
    try {
      // Pen Kit is a system HSP absent from emulators. Keep it outside the startup module graph.
      const board = await import('./DrawingBoard');
      if (!this.canAttach() || this.thread.id !== threadId || this.thread.attachments.length >= MAX_MESSAGE_ATTACHMENTS) { return; }
      this.drawingBuilder = board.drawingBoardBuilder;
      this.getUIContext().getFocusController().clearFocus();
      this.drawingThreadId = threadId; this.drawingDraft = new DrawingDraft(); this.showDrawing = true;
    } catch (error) { this.app.error = (error as Error).message; }
    finally { this.drawingOpening = false; }
  }
  private closeDrawing(): void {
    if (this.drawingDraft.saving) { return; }
    if (!this.drawingDraft.dirty()) { this.showDrawing = false; return; }
    this.getUIContext().showAlertDialog({ systemMaterial: this.appearance.surface, title: t('放弃这次绘画？'),
      message: t('尚未添加到消息的绘画将丢失。'), primaryButton: { value: t('继续绘画'), action: () => {} },
      secondaryButton: { value: t('放弃'), action: () => { this.showDrawing = false; } } });
  }
  private async addDrawing(pixel: image.PixelMap): Promise<void> {
    if (this.drawingThreadId !== this.app.active.id) { throw new Error(t('对话已切换，请在当前对话重新添加附件。')); }
    if (!this.canAttach() || this.thread.attachments.length >= MAX_MESSAGE_ATTACHMENTS) { throw new Error(t('当前无法添加附件，请稍后重试。')); }
    this.importing = true;
    try {
      const item = await Attachments.saveDrawing(pixel);
      if (this.drawingThreadId !== this.app.active.id) { throw new Error(t('对话已切换，请在当前对话重新添加附件。')); }
      if (!await this.app.setAttachments(this.thread.attachments.concat([item]))) {
        throw new Error(this.app.saveError || this.app.error || t('添加附件失败，请重试。'));
      }
      this.showDrawing = false;
    } finally { this.importing = false; }
  }
  @Builder
  drawingSheet() {
    if (this.drawingBuilder) {
      this.drawingBuilder.builder({ draft: this.drawingDraft, onClose: () => this.closeDrawing(),
        onAdd: (pixel: image.PixelMap) => this.addDrawing(pixel) })
    }
  }
  @Builder
  chatCover() {
    if (this.showDrawing) { this.drawingSheet() }
    else { this.imageViewer() }
  }
  @Builder
  memoryDraftSheet() {
    MemoryDraftPanel({ app: this.app, threadId: this.memoryThreadId, messageId: this.memoryMessageId, onClose: () => { this.showMemoryDraft = false; } })
  }
  private async fork(id: string): Promise<void> {
    const owner = this.focusOwner;
    const editing = this.thread.messages.some((message) => message.id === id && message.role === 'user');
    if (await this.app.forkThread(id)) {
      if (owner !== this.focusOwner || !this.speechEnabled || !this.foreground) { return; }
      this.getUIContext().getPromptAction().showToast({ systemMaterial: this.appearance.surface, message: t("已切换到新分支，原对话保留在列表中") });
      if (editing) {
        const branchId = this.app.active.id;
        // The model switches before ArkUI applies the new thread prop and its Watch callback.
        this.getUIContext().postFrameCallback(new ComposerKeyboardFrame(() => {
          if (owner === this.focusOwner && this.speechEnabled && this.foreground &&
            this.thread.id === branchId && this.app.active.id === branchId) { this.showSpeechKeyboard(); }
        }));
      }
    }
  }
  private async regenerate(id: string): Promise<void> {
    this.getUIContext().getFocusController().clearFocus();
    this.inspectingOutput = false; this.followOutput = true;
    await this.app.regenerateReply(id, () => this.follow());
  }
  private canAttach(): boolean {
    return !this.speechActive() && !this.app.busy && !this.importing && !this.thread.archived && this.app.saveError.length === 0;
  }
  // A fixed delay can expire while the native sheet still owns the focus scope.
  // Consume the action only from bindSheet's animation-complete onDisappear callback.
  private fromSheet(action: () => void): void {
    this.pendingPlusAction = action;
    this.plusActionThreadId = this.thread.id;
    Diagnostics.log('info', 'composer', 'sheet_action_queued');
    this.showPlus = false;
  }
  private finishPlusAction(): void {
    const action = this.pendingPlusAction;
    const threadId = this.plusActionThreadId;
    this.pendingPlusAction = undefined; this.plusActionThreadId = '';
    if (!action) { return; }
    if (this.showPlus || !this.speechEnabled || !this.foreground || this.thread.id !== threadId ||
      this.app.active.id !== threadId || !this.canAttach()) {
      Diagnostics.log('info', 'composer', 'sheet_action_cancelled');
      return;
    }
    Diagnostics.log('info', 'composer', 'sheet_action_dispatched');
    action();
  }
  private cancelPlusAction(): void {
    clearTimeout(this.plusMenuTimer); this.plusMenuTimer = -1;
    if (this.pendingPlusAction) { Diagnostics.log('info', 'composer', 'sheet_action_cancelled'); }
    this.pendingPlusAction = undefined; this.plusActionThreadId = '';
  }
  private addThreadReference(): void {
    if (referenceQuery(this.app.draft) === undefined) { this.app.setDraft(this.app.draft + (this.app.draft ? ' @' : '@')); }
    this.showSpeechKeyboard();
  }

  // The popup delay must never carry an action into another route or conversation.
  private dismissPlusMenu(action: () => void): void {
    clearTimeout(this.plusMenuTimer);
    const owner = this.focusOwner;
    const threadId = this.thread.id;
    this.showPlusMenu = false;
    this.plusMenuTimer = setTimeout(() => {
      this.plusMenuTimer = -1;
      if (owner !== this.focusOwner || this.thread.id !== threadId || this.app.active.id !== threadId ||
        !this.speechEnabled || !this.foreground || this.showPlusMenu || !this.canAttach()) { return; }
      action();
    }, 250);
  }
  private removeAttachment(id: string): void {
    this.app.setAttachments(this.thread.attachments.filter((file: Attachment) => file.id !== id));
  }

  private contextRatio(): number {
    return this.app.contextWindow > 0 ? Math.min(1, this.app.contextUsed / this.app.contextWindow) : 0;
  }

  private contextColor(): ResourceColor {
    return this.contextRatio() >= 0.85 ? $r('app.color.danger') : this.appearance.accent;
  }

  private confirmCompact(): void {
    this.getUIContext().showAlertDialog({ systemMaterial: this.appearance.surface,
      title: t("压缩较早对话？"),
      message: t("将调用当前模型生成摘要，消耗 Token。完整记录保留，之后请求使用摘要和最近消息。"),
      primaryButton: { value: t("取消"), action: () => {} },
      secondaryButton: { value: t("压缩"), action: () => { this.showContext = false; this.app.compactHistory(); } }
    });
  }

  private centeredWelcome(): boolean {
    return this.workbench && this.thread.messages.length === 0 && this.app.teams.length === 0 &&
      this.panelHeight >= 540 && this.viewport.keyboardHeight === 0 && !this.voiceMode && !this.voiceOverlayVisible() && !this.app.busy;
  }

  @Builder
  projectMenu() {
    Menu() {
      MenuItemGroup({ header: t('在项目中新建对话') }) {
        MenuItem({ content: t('普通聊天') }).onClick(() => { this.app.newThread(''); })
        ForEach(this.app.projects, (project: ProjectData) => {
          MenuItem({ content: project.name }).onClick(() => { this.app.newThread(project.id); })
        }, (project: ProjectData) => project.id)
      }
    }
  }

  @Builder
  workbenchModeMenu() {
    Menu() {
      MenuItem({ content: t('标准模式') }).onClick(() => this.toggleTeam(false))
      MenuItem({ content: t('团队模式') }).onClick(() => this.toggleTeam(true))
    }
  }

  @Builder
  workbenchContext() {
    Row({ space: 8 }) {
      Button() {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.folder')).fontSize(17).fontColor([$r('app.color.text_primary')])
          Text(this.app.activeProject?.name || t('普通聊天')).fontSize(14).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(10).fontColor([$r('app.color.text_secondary')])
        }.constraintSize({ maxWidth: 240 })
      }.id('workbench-project-picker').height(40).padding({ left: 10, right: 10 }).borderRadius(10)
        .backgroundColor(Color.Transparent).fontColor($r('app.color.text_primary')).enabled(!this.app.busy && !this.app.saveError)
        .bindMenu(this.projectMenu, { systemMaterial: this.appearance.surface, mask: false })
      Button() {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.person_2')).fontSize(17).fontColor([$r('app.color.text_secondary')])
          Text(this.thread.teamEnabled ? t('团队模式') : t('标准模式')).fontSize(14)
          SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(10).fontColor([$r('app.color.text_secondary')])
        }
      }.id('workbench-team-mode').height(40).padding({ left: 10, right: 10 }).borderRadius(10)
        .backgroundColor(Color.Transparent).fontColor($r('app.color.text_secondary'))
        .enabled(!this.app.busy && !this.thread.archived && !this.app.saveError)
        .bindMenu(this.workbenchModeMenu, { systemMaterial: this.appearance.surface, mask: false })
    }.width('100%').padding({ left: 6, bottom: 4 })
  }

  @Builder
  welcome() {
    if (this.workbench) {
      Column({ space: 12 }) {
        Row({ space: 12 }) {
          Image($r('app.media.tinybot')).width(38).height(38)
          Text(t('今天想一起做点什么？')).fontFamily(this.appearance.fontFamily).fontSize(28).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary')).maxLines(2).textAlign(TextAlign.Center)
        }.justifyContent(FlexAlign.Center).width('100%')
        if (!this.app.configured) {
          Button(t('连接你的模型')).id('setup-workbench-model').attributeModifier(Btn.textSmall).onClick(this.onSettings)
        }
      }.id('workbench-welcome').width('100%').height('100%').justifyContent(FlexAlign.Center)
        .padding({ left: 20, right: 20 })
        .onAppear(() => { this.lastHeaderProgress = 0; this.onHeaderProgress(0); })
    } else {
    Scroll() {
      Column({ space: Space.md }) {
        Blank().layoutWeight(1)
        Image($r('app.media.tinybot')).width(56).height(56)
          .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.6, y: 0.6 }))
            .animation({ curve: curves.springMotion(0.5, 0.7) }))
        Text(t("今天想一起做点什么？")).fontFamily(this.appearance.fontFamily).fontSize(Font.headline).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary')).textAlign(TextAlign.Center)
          .margin({ bottom: Space.md }).transition(Motion.rise(1))
        if (!this.app.configured) {
          Column({ space: 10 }) {
            Text(t("先连接一个模型服务")).fontFamily(this.appearance.fontFamily).fontSize(15).fontWeight(FontWeight.Medium)
              .fontColor(this.appearance.onAccentContainer)
            Text(t("支持 OpenAI、Anthropic 等协议，密钥保存在系统安全存储中。")).fontFamily(this.appearance.fontFamily).fontSize(13).lineHeight(19)
              .textAlign(TextAlign.Center).fontColor(this.appearance.onAccentContainer)
            Button(t("连接你的模型")).fontFamily(this.appearance.fontFamily).id('setup-model').attributeModifier(Btn.primary).width('100%')
              .onClick(() => this.onSettings())
          }.width('100%').padding(Space.lg).borderRadius(Radius.lg).backgroundColor(this.appearance.accentContainer)
          .transition(Motion.rise(3))
        }
        Blank().layoutWeight(1)
      }.width('100%').constraintSize({ minHeight: '100%' })
      .padding({ left: 20, right: 20, top: this.topInset + Space.lg, bottom: Space.md })
    }.layoutWeight(1).width('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
      .onAppear(() => { this.lastHeaderProgress = 0; this.onHeaderProgress(0); })
    }
  }

  @Builder
  messageList() {
    Stack({ alignContent: Alignment.Bottom }) {
      List({ space: 22, scroller: this.scroller }) {
        if (this.app.visibleMessageCount < this.thread.messages.length) {
          ListItem() {
            Button(t("加载更早的消息")).fontFamily(this.appearance.fontFamily).id('load-earlier-messages').attributeModifier(Btn.textSmall)
              .onClick(() => { this.app.visibleMessageCount += 60; })
          }.width('100%')
        }
        LazyForEach(this.messageSource, (message: MessageViewModel) => {
          ListItem() {
            MessageBubble({ message: message, latestPreviewIds: this.thread.latestPreviewIds, turnStatus: message.status, webEnabled: this.app.extensions.webEnabled, onOpenFile: this.onOpenFile,
              previewInspectable: this.previewInspectable, inspectedPreviewId: this.inspectedPreviewId, onInspectPreview: this.onInspectPreview, uiAvailable: !this.app.busy && !this.thread.archived,
              sendOrigin: this.sendingMessageId === message.id ? this.sendOrigin : undefined,
              onSendReady: (): void => { this.scroller.scrollEdge(Edge.Bottom); }, onSendFinish: (): void => { this.finishSendFlight(message.id); },
              readingMessageId: this.reading.messageId, onRead: (id: string) => this.readAnswer(id),
              actionsEnabled: !this.app.busy && !this.app.saveError, onRegenerate: (id: string) => this.regenerate(id),
              onUi: this.uiHandler(this.thread.id, message.id), onFork: (id: string) => { this.fork(id); }, onRemember: (id: string) => { this.remember(id); },
              onInspect: () => { this.inspectingOutput = true; this.followOutput = false; clearTimeout(this.scrollTimer); this.scrollTimer = -1; },
              onReference: (text: string) => this.app.setDraft(this.app.draft + text), onResume: (id: string) => this.app.resumeForm(message.id, id),
              hasExtra: message.role === 'assistant' && this.app.teams.some((run) => run.ownerMessageId === message.id) }) {
              ChatTeamCard({ app: this.app, messageId: message.id, onFiles: this.onFiles })
            }
          }
            .onAreaChange((previous: Area, current: Area) => this.messageAreaChanged(message.id, previous, current))
            .backgroundColor(this.app.searchMessageId === message.id ? this.appearance.accentContainer : Color.Transparent)
            .animation({ duration: Motion.medium, curve: Motion.standard })
            .transition(this.messageEnter(message))
            .onAppear(() => { this.baseline.add(message.id); })
        }, (message: MessageViewModel) => this.thread.id + ":" + message.id)
        if (this.app.teams.some((run) => !run.ownerMessageId)) {
          ListItem() { ChatTeamCard({ app: this.app, onFiles: this.onFiles }) }.width('100%')
        }
      }
      .id('message-list').width('100%').height('100%').clip(!this.sendingMessageId)
      .padding({ left: Space.page, right: Space.page })
      // Scroll the leading space away so messages can pass beneath the floating title bar.
      .contentStartOffset(this.topInset + Space.sm)
      // Only the end of the transcript clears the floating controls; messages scroll behind them.
      .contentEndOffset(48)
      .scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
      .cachedCount(1).maintainVisibleContentPosition(true)
      .onScrollStart(() => this.setScrollActivity(true))
      .onScrollStop(() => this.stopScrollActivity())
      .onTouch((event: TouchEvent) => { if (event.type === TouchType.Down) { this.followOutput = false; } })
      .onReachEnd(() => { if (!this.inspectingOutput) { this.followOutput = true; } })
      .onDidScroll(() => { this.atBottom = this.scroller.isAtEnd(); this.updateHeaderProgress(); })
      .onAreaChange((previous: Area, current: Area) => {
        // RESIZE moves the composer but does not scroll the List. Follow its final viewport size.
        if (previous.height !== current.height && this.composerFocused && this.viewport.keyboardHeight > 0) { this.follow(); }
      })
      if (!this.atBottom) {
        // Toggle supports native immersive material outside navigation bars; expose this momentary action as a button.
        Toggle({ type: ToggleType.Button, isOn: false }) {
          SymbolGlyph($r('sys.symbol.arrow_down')).fontSize(18).fontColor([$r('sys.color.font_primary')])
        }.id('scroll-to-latest').width(38).height(38).padding(0).borderRadius(19)
        .backgroundColor(this.appearance.controlBackground).selectedColor(this.appearance.controlBackground)
        .attributeModifier(systemMaterialAttribute<ToggleAttribute>(this.appearance.control))
        .accessibilityText(t("查看最新消息")).accessibilityRole(AccessibilityRoleType.BUTTON)
        .onClick(() => { this.scrollToLatest(); })
        .margin({ bottom: Space.md })
        .transition(Motion.pop())
      }
    }.layoutWeight(1).width('100%')
  }

  @Builder
  contextSheet() {
    Scroll() {
      Column({ space: Space.lg }) {
        ContextDetails({ app: this.app })
        if (this.thread.compaction) {
          Column({ space: 10 }) {
            Row({ space: Space.sm }) {
              Text(t("较早对话使用摘要")).fontFamily(this.appearance.fontFamily).fontSize(15).fontWeight(FontWeight.Medium).layoutWeight(1)
                .fontColor($r('app.color.text_primary'))
              Button(this.showSummary ? t("收起") : t("查看摘要")).fontFamily(this.appearance.fontFamily).attributeModifier(Btn.textSmall)
                .onClick(() => { this.showSummary = !this.showSummary; })
            }.width('100%')
            Text(t("完整记录仍保留在本机，只有发送给模型时使用摘要。")).fontFamily(this.appearance.fontFamily).fontSize(Font.caption)
              .fontColor($r('app.color.text_secondary')).width('100%')
            if (this.showSummary) {
              Scroll() {
                Text(this.thread.compaction.summary).fontFamily(this.appearance.fontFamily).fontSize(13).lineHeight(20).width('100%')
                  .copyOption(CopyOptions.LocalDevice).fontColor($r('app.color.text_primary'))
              }.constraintSize({ maxHeight: 240 }).width('100%').align(Alignment.TopStart)
              .padding(Space.md).borderRadius(Radius.sm).backgroundColor($r('app.color.surface_variant'))
            }
          }.padding(Space.lg).borderRadius(Radius.lg).backgroundColor($r('app.color.surface'))
        }
        Column({ space: Space.sm }) {
          Button(t("压缩较早对话")).fontFamily(this.appearance.fontFamily).id('compact-history').attributeModifier(Btn.tonal).width('100%')
            .enabled(this.app.configured && !this.app.busy && !this.thread.archived && this.app.saveError.length === 0)
            .onClick(() => this.confirmCompact())
          Text(t("使用当前模型为较早消息生成摘要，会消耗 Token。")).fontFamily(this.appearance.fontFamily).fontSize(Font.caption)
            .fontColor($r('app.color.text_tertiary'))
        }.width('100%')
      }.width('100%').padding({ left: Space.page, right: Space.page, bottom: Space.xl + this.insetBottom })
    }.width('100%').height('100%').scrollBar(BarState.Off)
  }

  @Builder
  queueSheet() {
    InputQueuePanel({ app: this.app, thread: this.thread,
      onContinue: () => {
        this.showQueue = false;
        this.followOutput = true;
        this.app.resumeQueue(() => this.follow());
      },
      onEdited: () => { this.showQueue = false; } })
  }

  @Builder
  sendMenu() {
    Menu() {
      MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.text_and_plus')), content: t("加入队列") })
        .enabled(this.app.canQueueInput && this.hasDraft())
        .onClick(() => this.app.enqueueInput('followUp'))
    }
  }

  @Builder
  plusTile(icon: Resource, label: string, compId: string, enabled: boolean, action: () => void) {
    Column({ space: 8 }) {
      Column() {
        SymbolGlyph(icon).fontSize(24).fontColor([this.appearance.accent])
      }.width(56).height(56).borderRadius(Radius.lg).justifyContent(FlexAlign.Center)
      .backgroundColor($r('app.color.surface'))
      Text(label).fontFamily(this.appearance.fontFamily).fontSize(Font.caption).fontColor($r('app.color.text_secondary'))
    }
    .id(compId).layoutWeight(1).opacity(enabled ? 1 : 0.4).enabled(enabled)
    .clickEffect(enabled ? Motion.press : null)
    .onClick(action)
  }

  @Builder
  plusMenuRow(icon: Resource, label: string, compId: string, enabled: boolean, withChevron: boolean,
              trailing: string, action: () => void) {
    Row({ space: 10 }) {
      SymbolGlyph(icon).fontSize(18).fontColor([enabled ? this.appearance.accent : $r('app.color.text_tertiary')])
      Text(label).fontFamily(this.appearance.fontFamily).fontSize(14).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        .fontColor(enabled ? $r('app.color.text_primary') : $r('app.color.text_tertiary'))
      if (trailing.length > 0) {
        Text(trailing).fontFamily(this.appearance.fontFamily).fontSize(11).fontColor($r('app.color.text_tertiary'))
      }
      if (withChevron) {
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(12).fontColor([$r('app.color.text_tertiary')])
      }
    }
    .id(compId).width('100%').height(46).padding({ left: 10, right: 8 }).borderRadius(10)
    .stateStyles({ pressed: { .backgroundColor($r('app.color.surface_variant')) }, normal: { .backgroundColor(Color.Transparent) } })
    .opacity(enabled ? 1 : 0.45).enabled(enabled).onClick(action)
  }

  @Builder
  plusRootPane() {
    Column({ space: 2 }) {
      this.plusMenuRow($r('sys.symbol.picture'), t('图片'), 'plus-menu-photo',
        this.canAttach() && this.thread.attachments.length < MAX_MESSAGE_ATTACHMENTS, false, '',
        () => this.dismissPlusMenu(() => this.attach(true)))
      this.plusMenuRow($r('sys.symbol.doc_text'), t('文本文件'), 'plus-menu-text',
        this.canAttach() && this.thread.attachments.length < MAX_MESSAGE_ATTACHMENTS, false, '',
        () => this.dismissPlusMenu(() => this.attach(false)))
      this.plusMenuRow($r('sys.symbol.square_and_pencil'), t('画板'), 'plus-menu-drawing',
        this.canAttach() && this.thread.attachments.length < MAX_MESSAGE_ATTACHMENTS, false, '',
        () => this.dismissPlusMenu(() => this.openDrawing()))
      Divider().strokeWidth(0.5).color($r('app.color.divider')).margin({ left: 10, right: 10, top: 4, bottom: 4 })
      this.plusMenuRow($r('sys.symbol.folder'), t('工作区'), 'plus-menu-workspace', !this.app.busy, true, '',
        () => { this.showPlusMenu = false; this.onFiles(); })
      this.plusMenuRow($r('sys.symbol.lightbulb'), t('记忆'), 'plus-menu-memory', !this.app.busy, true, '',
        () => { this.showPlusMenu = false; this.onTools('memory'); })
      this.plusMenuRow($r('sys.symbol.person_2'), this.thread.teamEnabled ? t('关闭团队') : t('Agent 团队'),
        'plus-menu-team', !this.app.busy && !this.thread.archived && this.app.saveError.length === 0, false, '',
        () => { this.showPlusMenu = false; this.toggleTeam(!this.thread.teamEnabled); })
      Divider().strokeWidth(0.5).color($r('app.color.divider')).margin({ left: 10, right: 10, top: 4, bottom: 4 })
      this.plusMenuRow($r('sys.symbol.link'), t('引用其他会话'), 'plus-menu-reference',
        this.canAttach() && this.thread.references.length < 4, false, '', () => this.dismissPlusMenu(() => this.addThreadReference()))
      this.plusMenuRow($r('sys.symbol.doc_plaintext'), t('提示词模板'), 'plus-menu-templates', !this.app.busy, true,
        String(this.app.productivity.templates.length), () => { this.plusPane = 'templates'; })
      Text(this.thread.attachments.length >= MAX_MESSAGE_ATTACHMENTS ? t('已达到每条消息 {0} 个附件的上限', [MAX_MESSAGE_ATTACHMENTS]) : t('每条消息最多 {0} 个附件 · 图片需模型支持视觉输入', [MAX_MESSAGE_ATTACHMENTS]))
        .fontFamily(this.appearance.fontFamily).fontSize(11).lineHeight(16).fontColor($r('app.color.text_tertiary'))
        .width('100%').padding({ left: 10, right: 10, top: 6, bottom: 8 })
    }.width('100%')
  }

  @Builder
  plusTemplateRow(item: PromptTemplate) {
    Column({ space: 2 }) {
      Text(item.name).fontFamily(this.appearance.fontFamily).fontSize(14).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_primary'))
      Text(item.content.replace(/\s+/g, ' ')).fontFamily(this.appearance.fontFamily).fontSize(11).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_tertiary'))
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 10, right: 10, top: 7, bottom: 7 })
    .id('plus-template-' + item.id).width('100%').height(52).borderRadius(10)
    .stateStyles({ pressed: { .backgroundColor($r('app.color.surface_variant')) }, normal: { .backgroundColor(Color.Transparent) } })
    .enabled(!this.thread.archived)
    .onClick(() => {
      this.showPlusMenu = false;
      this.app.useTemplate(item.id);
      this.getUIContext().getPromptAction().showToast({ systemMaterial: this.appearance.surface, message: t('已套用模板，可继续编辑后发送') });
    })
  }

  @Builder
  plusTemplatesPane() {
    Column({ space: 2 }) {
      Row({ space: 2 }) {
        IconButton({ icon: $r('sys.symbol.chevron_left'), label: t('返回'), compId: 'plus-menu-back',
          diameter: 32, iconSize: 16, onTap: () => { this.plusPane = 'root'; } })
        Text(t('提示词模板')).fontFamily(this.appearance.fontFamily).fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary')).layoutWeight(1)
        Text(String(this.app.productivity.templates.length)).fontFamily(this.appearance.fontFamily).fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
      }.width('100%').height(44).padding({ left: 2, right: 10 })
      if (this.app.productivity.templates.length === 0) {
        Text(t('还没有模板')).fontFamily(this.appearance.fontFamily).fontSize(13).fontColor($r('app.color.text_tertiary'))
          .width('100%').padding({ left: 10, right: 10, top: 12, bottom: 12 })
      } else {
        List({ space: 2 }) {
          ForEach(this.app.productivity.templates, (item: PromptTemplate) => {
            ListItem() { this.plusTemplateRow(item) }
          }, (item: PromptTemplate) => item.id)
        }.width('100%').height(Math.min(260, this.app.productivity.templates.length * 52))
          .scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
      }
      Divider().strokeWidth(0.5).color($r('app.color.divider')).margin({ left: 10, right: 10, top: 4, bottom: 4 })
      this.plusMenuRow($r('sys.symbol.gearshape'), t('管理'), 'plus-menu-manage', !this.app.busy, true, '',
        () => { this.showPlusMenu = false; this.onTools('templates'); })
    }.width('100%')
  }

  @Builder
  plusMenu() {
    Column() {
      if (this.plusPane === 'templates') { this.plusTemplatesPane() }
      else { this.plusRootPane() }
    }.width(320).constraintSize({ maxHeight: 480 }).padding(4).borderRadius(20).clip(true)
  }

  @Builder
  plusSheet() {
    Scroll() {
      Column({ space: Space.lg }) {
        Row() {
          this.plusTile($r('sys.symbol.picture'), t("图片"), 'attach-photo',
            this.canAttach() && this.thread.attachments.length < MAX_MESSAGE_ATTACHMENTS, () => this.fromSheet(() => this.attach(true)))
          this.plusTile($r('sys.symbol.doc_text'), t("文本文件"), 'attach-text',
            this.canAttach() && this.thread.attachments.length < MAX_MESSAGE_ATTACHMENTS, () => this.fromSheet(() => this.attach(false)))
          this.plusTile($r('sys.symbol.square_and_pencil'), t('画板'), 'attach-drawing',
            this.canAttach() && this.thread.attachments.length < MAX_MESSAGE_ATTACHMENTS, () => this.fromSheet(() => this.openDrawing()))
        }.width('100%').alignItems(VerticalAlign.Top)
        Row() {
          this.plusTile($r('sys.symbol.folder'), t("工作区"), 'open-workspace', !this.app.busy,
            () => { this.showPlus = false; this.onFiles(); })
          this.plusTile($r('sys.symbol.lightbulb'), t("记忆"), 'open-memory', !this.app.busy,
            () => { this.showPlus = false; this.onTools('memory'); })
          this.plusTile($r('sys.symbol.person_2'), this.thread.teamEnabled ? t("关闭团队") : t("Agent 团队"), 'toggle-team',
            !this.app.busy && !this.thread.archived && this.app.saveError.length === 0,
            () => { this.showPlus = false; this.toggleTeam(!this.thread.teamEnabled); })
        }.width('100%').alignItems(VerticalAlign.Top)
        Text(this.thread.attachments.length >= MAX_MESSAGE_ATTACHMENTS ? t('已达到每条消息 {0} 个附件的上限', [MAX_MESSAGE_ATTACHMENTS]) : t('每条消息最多 {0} 个附件 · 图片需模型支持视觉输入', [MAX_MESSAGE_ATTACHMENTS])).fontFamily(this.appearance.fontFamily)
          .fontSize(Font.caption).fontColor($r('app.color.text_tertiary')).width('100%').textAlign(TextAlign.Center)
        Button(t('引用其他会话')).fontFamily(this.appearance.fontFamily).id('add-thread-reference').attributeModifier(Btn.tonal).width('100%')
          .enabled(this.canAttach() && this.thread.references.length < 4)
          .onClick(() => this.fromSheet(() => this.addThreadReference()))
        Column() {
          Row() {
            Text(t("提示词模板")).fontFamily(this.appearance.fontFamily).fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_secondary'))
              .layoutWeight(1)
            Button(t("管理")).fontFamily(this.appearance.fontFamily).id('manage-templates').attributeModifier(Btn.textSmall).enabled(!this.app.busy)
              .onClick(() => { this.showPlus = false; this.onTools('templates'); })
          }.width('100%').padding({ left: 4 })
          if (this.app.productivity.templates.length === 0) {
            Text(t("还没有模板")).fontFamily(this.appearance.fontFamily).fontSize(13).fontColor($r('app.color.text_tertiary'))
              .padding(Space.lg).width('100%').textAlign(TextAlign.Center)
          }
          Column() {
            ForEach(this.app.productivity.templates, (item: PromptTemplate, index: number) => {
              if (index > 0) { Divider().strokeWidth(0.5).color($r('app.color.divider')).margin({ left: 52 }) }
              Row({ space: Space.md }) {
                SymbolGlyph($r('sys.symbol.doc_plaintext')).fontSize(20).fontColor([this.appearance.accent])
                Column({ space: 2 }) {
                  Text(item.name).fontFamily(this.appearance.fontFamily).fontSize(15).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    .fontColor($r('app.color.text_primary'))
                  Text(item.content.replace(/\s+/g, ' ')).fontFamily(this.appearance.fontFamily).fontSize(Font.caption).maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_tertiary'))
                }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              }
              .id('use-template-' + item.id).width('100%').constraintSize({ minHeight: 56 })
              .padding({ left: Space.lg, right: Space.lg, top: 8, bottom: 8 })
              .stateStyles({ pressed: { .backgroundColor($r('app.color.surface_variant')) }, normal: { .backgroundColor(Color.Transparent) } })
              .enabled(!this.thread.archived)
              .onClick(() => {
                this.showPlus = false; this.app.useTemplate(item.id);
                this.getUIContext().getPromptAction().showToast({ systemMaterial: this.appearance.surface, message: t("已套用模板，可继续编辑后发送") });
              })
            }, (item: PromptTemplate) => item.id)
          }.width('100%').borderRadius(Radius.lg).clip(true).backgroundColor($r('app.color.surface'))
        }.width('100%')
      }.width('100%').padding({ left: Space.page, right: Space.page, top: Space.sm, bottom: Space.xl })
    }.width('100%').scrollBar(BarState.Off).align(Alignment.Top)
  }

  @Builder
  attachmentStrip() {
    Scroll() {
      Row({ space: Space.sm }) {
        ForEach(this.thread.attachments, (item: Attachment) => {
          Stack({ alignContent: Alignment.TopEnd }) {
            if (item.mime === 'image/jpeg') {
              Image('file://' + Attachments.path(item)).width(64).height(64).objectFit(ImageFit.Contain)
                .borderRadius(Radius.md).backgroundColor($r('app.color.surface_variant'))
                .accessibilityText(item.name)
                .onClick(() => { this.previewPath = Attachments.path(item); this.previewing = true; })
            } else {
              Column({ space: 2 }) {
                SymbolGlyph($r('sys.symbol.doc_text')).fontSize(18).fontColor([this.appearance.accent])
                Text(item.name).fontFamily(this.appearance.fontFamily).fontSize(11).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .fontColor($r('app.color.text_primary'))
                Text(fileSize(item.size)).fontFamily(this.appearance.fontFamily).fontSize(10).fontColor($r('app.color.text_tertiary'))
              }.width(112).height(64).padding({ left: 10, right: 14, top: 8, bottom: 8 })
              .alignItems(HorizontalAlign.Start).borderRadius(Radius.md)
              .backgroundColor($r('app.color.surface_variant'))
            }
            Button({ type: ButtonType.Circle }) {
              SymbolGlyph($r('sys.symbol.xmark')).fontSize(10).fontColor([Color.White])
            }.fontFamily(this.appearance.fontFamily).id('remove-attachment-' + item.id).width(20).height(20).backgroundColor('#99000000')
            .margin({ top: 4, right: 4 }).accessibilityText(t("移除 ") + item.name)
            .hitTestBehavior(HitTestMode.Block).responseRegion({ x: -10, y: -10, width: 40, height: 40 })
            .onClick(() => this.removeAttachment(item.id))
          }
          .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.85, y: 0.85 }))
            .animation({ duration: Motion.medium, curve: Motion.standard }))
        }, (item: Attachment) => item.id)
        if (this.importing) {
          Column() { LoadingProgress().width(24).height(24).color(this.appearance.accent) }
            .width(64).height(64).justifyContent(FlexAlign.Center).borderRadius(Radius.md)
            .backgroundColor($r('app.color.surface_variant'))
        }
      }.padding({ left: 4, right: 4, top: 4 })
    }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%').align(Alignment.Start)
    .enabled(!this.app.busy)
  }

  @Builder
  imageViewer() {
    ImageViewer({ source: 'file://' + this.previewPath, onClose: () => { this.previewing = false; } })
  }

  private async toggleTeam(enabled: boolean): Promise<void> {
    await this.app.setTeamEnabled(enabled);
  }

  private teamSuggested(): boolean {
    return this.commandSuggested('/team') && !this.thread.teamEnabled;
  }
  private commandSuggested(command: string): boolean {
    const draft = this.app.draft.trim().toLowerCase();
    return !this.speechActive() && !this.app.busy && !this.thread.archived && this.app.saveError.length === 0 && draft.startsWith('/') && command.startsWith(draft);
  }
  private referenceSuggested(): boolean {
    return this.canAttach() && this.thread.references.length < 4 && !this.skillSuggested() && referenceQuery(this.app.draft) !== undefined;
  }
  private currentSkillQuery(): SkillQuery | undefined {
    if (this.composerSelectionStart !== this.composerSelectionEnd) { return undefined; }
    return skillQuery(this.app.draft, this.composerSelectionEnd < 0 ? this.app.draft.length : this.composerSelectionEnd);
  }
  private skillSuggested(): boolean {
    return !this.voiceMode && !this.speechActive() && !this.app.busy && !this.thread.archived &&
      this.app.saveError.length === 0 && this.currentSkillQuery() !== undefined;
  }
  private skillMatches(): SkillData[] {
    return matchingSkills(this.app.extensions.skills, this.currentSkillQuery()?.text || '');
  }
  private selectSkill(name: string): void {
    const query = this.currentSkillQuery();
    if (!this.skillSuggested() || !query) { return; }
    const next = skillDraft(this.app.draft, name, query);
    if (!this.app.useSkill(name, query)) { return; }
    this.composerSelectionStart = next.caret; this.composerSelectionEnd = next.caret;
    const threadId = this.thread.id;
    const request = ++this.keyboardFocusRequest;
    this.getUIContext().postFrameCallback(new ComposerKeyboardFrame(() => {
      if (request !== this.keyboardFocusRequest || this.thread.id !== threadId || this.app.active.id !== threadId ||
        !this.speechEnabled || !this.foreground || this.showPlus || this.showPlusMenu || this.showDrawing || this.previewing ||
        this.showContext || this.showQueue || this.showSummary || this.showMemoryDraft || this.showReasoning || this.showModelMenu ||
        this.app.draft !== next.text || this.thread.archived || this.voiceMode || this.speechActive()) { return; }
      this.getUIContext().getFocusController().requestFocus('composer');
      this.composerController.caretPosition(next.caret);
    }));
  }
  private referenceMatches(): ThreadViewModel[] {
    const query = (referenceQuery(this.app.draft) || '').trim().toLowerCase();
    return this.app.threads.filter((item) => item.id !== this.thread.id && item.messages.some((message) => message.role === 'assistant' && message.status === 'complete') &&
      !this.thread.references.some((ref) => ref.threadId === item.id) && item.title.toLowerCase().includes(query))
      .sort((a, b) => Number(!!this.thread.projectId && b.projectId === this.thread.projectId) -
        Number(!!this.thread.projectId && a.projectId === this.thread.projectId) || b.updatedAt - a.updatedAt).slice(0, 6);
  }

  @Builder
  skillSuggestions() {
    Column({ space: 2 }) {
      Text(t('选择 Skill · 输入 $ 后搜索')).fontFamily(this.appearance.fontFamily).fontSize(12)
        .fontColor($r('app.color.text_secondary')).padding(8)
      if (this.skillMatches().length === 0) {
        Text(t('没有匹配的已启用 Skill')).fontFamily(this.appearance.fontFamily).fontSize(13)
          .fontColor($r('app.color.text_tertiary')).padding(12)
      }
      Scroll() {
        Column() {
          ForEach(this.skillMatches(), (skill: SkillData) => {
            Row({ space: 8 }) {
              SymbolGlyph($r('sys.symbol.wand_and_stars')).fontSize(16).fontColor([this.appearance.accent])
              Column({ space: 2 }) {
                Text(skillDisplayName(skill)).fontFamily(this.appearance.fontFamily).fontSize(14).maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_primary'))
                Text(builtinSkillInfo(skill) ? t(skill.description) : skill.description).fontFamily(this.appearance.fontFamily)
                  .fontSize(12).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_secondary'))
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            }.id('mention-skill-' + skill.name).height(56).width('100%').padding({ left: 12, right: 12 })
              .onClick(() => this.selectSkill(skill.name))
          }, (skill: SkillData) => skill.name)
        }.width('100%')
      }.width('100%').constraintSize({ maxHeight: 176 }).scrollBar(BarState.Auto)
    }.id('skill-suggestions').width('100%').alignItems(HorizontalAlign.Start)
      .borderRadius(Radius.lg).backgroundColor($r('app.color.surface'))
      .border({ width: 0.5, color: $r('app.color.divider') })
  }

  @Builder
  referenceSuggestions() {
    Column({ space: 2 }) {
      Text(t('引用会话 · 输入 @ 后搜索标题')).fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_secondary')).padding(8)
      if (this.referenceMatches().length === 0) {
        Text(t('没有可引用的匹配会话')).fontFamily(this.appearance.fontFamily).fontSize(13).fontColor($r('app.color.text_tertiary')).padding(12)
      }
      Scroll() {
        Column() {
          ForEach(this.referenceMatches(), (item: ThreadViewModel) => {
            Row({ space: 8 }) {
              SymbolGlyph($r('sys.symbol.ellipsis_message')).fontSize(16).fontColor([this.appearance.accent])
              Text(item.displayTitle).fontFamily(this.appearance.fontFamily).fontSize(14).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                .fontColor($r('app.color.text_primary')).layoutWeight(1)
              if (item.archived) { Text(t('已归档')).fontFamily(this.appearance.fontFamily).fontSize(11).fontColor($r('app.color.text_tertiary')) }
            }.id('mention-thread-' + item.id).height(44).width('100%').padding({ left: 12, right: 12 })
            .onClick(() => { this.app.referenceThread(item.id); })
          }, (item: ThreadViewModel) => item.id)
        }.width('100%')
      }.width('100%').constraintSize({ maxHeight: 176 }).scrollBar(BarState.Auto)
    }.id('reference-suggestions').width('100%').alignItems(HorizontalAlign.Start)
    .borderRadius(Radius.lg).backgroundColor($r('app.color.surface'))
    .border({ width: 0.5, color: $r('app.color.divider') })
  }

  @Builder
  compactSuggestion() {
    Row({ space: Space.md }) {
      IconBadge({ icon: $r('sys.symbol.doc_text'), diameter: 36 })
      Column({ space: 2 }) {
        Text('/compact').fontSize(14).fontWeight(FontWeight.Medium).fontFamily('monospace').fontColor($r('app.color.text_primary'))
        Text(t('压缩较早对话，保留完整记录')).fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_secondary'))
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    }.id('slash-compact').width('100%').padding(12).borderRadius(Radius.lg).backgroundColor($r('app.color.surface'))
    .border({ width: 0.5, color: $r('app.color.divider') })
    .onClick(() => { this.app.setDraft('/compact'); this.send(); })
  }

  @Builder
  teamToggle() {
    // Toggle supports native material in the content area; ordinary Button and Chip do not.
    Toggle({ type: ToggleType.Button, isOn: this.thread.teamEnabled }) {
      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.person_2')).fontSize(16)
          .fontColor([this.thread.teamEnabled ? this.appearance.onAccent : $r('sys.color.font_primary')])
        Text(t('团队模式')).fontFamily(this.appearance.fontFamily).fontSize(13).fontWeight(FontWeight.Medium)
          .fontColor(this.thread.teamEnabled ? this.appearance.onAccent : $r('sys.color.font_primary'))
      }
    }.id('composer-team-toggle').height(32).padding({ left: 12, right: 12 }).borderRadius(16)
      .margin({ left: 14, bottom: Space.sm })
      .backgroundColor(this.appearance.controlBackground).selectedColor(this.appearance.accent)
      .attributeModifier(systemMaterialAttribute<ToggleAttribute>(this.thread.teamEnabled ? this.appearance.accentControl : this.appearance.control))
      .enabled(this.app.ready && !this.app.busy && !this.thread.archived && this.app.saveError.length === 0)
      .accessibilityText(t('团队模式'))
      .accessibilityDescription(this.thread.teamEnabled ? t('关闭团队模式') : t('开启团队模式'))
      .onChange((enabled: boolean) => {
        if (enabled !== this.thread.teamEnabled) { this.toggleTeam(enabled); }
      })
  }

  // Slash-command suggestion shown while the draft is a prefix of /team.
  @Builder
  commandSuggestion() {
    Row({ space: Space.md }) {
      IconBadge({ icon: $r('sys.symbol.person_2'), diameter: 36 })
      Column({ space: 2 }) {
        Row({ space: 6 }) {
          Text('/team').fontSize(14).fontWeight(FontWeight.Medium).fontFamily('monospace').fontColor($r('app.color.text_primary'))
          Text(t("Agent 团队")).fontFamily(this.appearance.fontFamily).fontSize(13).fontColor($r('app.color.text_secondary'))
        }
        Text(t("主 Agent 自主招募员工、并行分工并汇总结果")).fontFamily(this.appearance.fontFamily).fontSize(Font.caption).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_tertiary'))
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([$r('app.color.text_tertiary')])
    }
    .id('slash-team').width('100%').padding({ left: Space.md, right: Space.md, top: 10, bottom: 10 })
    .borderRadius(Radius.lg).backgroundColor($r('app.color.surface'))
    .border({ width: 0.5, color: $r('app.color.divider') }).shadow({ radius: 12, color: '#0F000000', offsetY: 2 })
    .clickEffect(Motion.press).accessibilityText(t("开启团队模式"))
    .transition(Motion.rise(0, 12))
    .onClick(async () => { if (await this.app.setTeamEnabled(true)) { this.app.setDraft(''); } })
  }

  @Builder
  reasoningPicker() {
    ReasoningEffortPicker({ value: this.thread.reasoningEffort, modelName: this.thread.modelRef?.modelId || '',
      selectionKey: this.reasoningKey(),
      efforts: reasoningEfforts(this.app.providerProfiles.find((item) => item.id === this.thread.modelRef?.providerId)?.protocol || '', this.thread.modelRef?.modelId || ''),
      disabled: this.app.busy || this.thread.archived || this.app.saveError.length > 0,
      onPreview: (value: string | undefined): void => {
        if (value !== undefined) {
          this.reasoningPreviewKey = this.reasoningKey();
          this.reasoningPreview = value;
        } else if (!this.reasoningSaving) this.reasoningPreview = '';
      },
      onSelect: async (value: string): Promise<boolean> => {
        this.reasoningSaving = true;
        try {
          const saved = await this.app.setReasoningEffort(value);
          if (!saved && this.app.error) this.getUIContext().getPromptAction().showToast({ systemMaterial: this.appearance.surface, message: this.app.error });
          return saved;
        } finally {
          // SessionService publishes the committed snapshot before resolving.
          this.reasoningSaving = false;
          this.reasoningPreview = '';
        }
      } })
  }

  // Desktop parity: the model seat opens a card above the composer instead of
  // leaving the conversation. Compact keeps the same grouped, searchable list in
  // a bounded popup with clear rows for touch.
  @Builder
  modelMenu() {
    Column() {
      ModelPickerPanel({ app: this.app, compact: true,
        onSelected: () => { this.showModelMenu = false; },
        onSettings: () => { this.showModelMenu = false; this.onSettings(); } })
    }.width(340).height(this.modelMenuHeight()).borderRadius(20).clip(true)
  }

  // Size the card to the catalog instead of reserving a full menu's height: two
  // models must not leave a blank half-screen, and a long catalog still scrolls.
  private modelMenuHeight(): number {
    const choices = this.app.modelChoices;
    if (choices.length === 0) { return 260; }
    const providers: string[] = [];
    for (const choice of choices) {
      if (!providers.includes(choice.providerId)) { providers.push(choice.providerId); }
    }
    const rows = Math.min(choices.length, 8);
    const base = 62 + providers.length * 26 + rows * 46 + (this.app.error.length > 0 ? 56 : 0);
    return Math.min(380, Math.max(180, base));
  }

  private reasoningKey(): string {
    return JSON.stringify([this.thread.id, this.thread.modelRef?.providerId || '', this.thread.modelRef?.modelId || '',
      this.app.providerProfiles.find((item) => item.id === this.thread.modelRef?.providerId)?.protocol || '']);
  }

  private displayedEffort(): string {
    return this.reasoningPreview && this.reasoningPreviewKey === this.reasoningKey() ?
      this.reasoningPreview : this.thread.reasoningEffort;
  }

  private highestEffort(): boolean {
    return this.app.configured && !this.thread.archived && isHighestReasoningEffort(
      this.app.providerProfiles.find((item) => item.id === this.thread.modelRef?.providerId)?.protocol || '',
      this.thread.modelRef?.modelId || '', this.displayedEffort());
  }

  @Builder
  composerAddButton() {
    IconButton({ icon: $r('sys.symbol.plus'), label: t('添加图片、画板、文件或模板'), compId: 'add-attachment', diameter: 36,
      iconSize: 18, fill: $r('app.color.surface_variant'),
      disabled: this.thread.archived || this.app.saveError.length > 0 || this.speechActive() || this.speechHolding,
      onTap: () => {
        this.getUIContext().getFocusController().clearFocus();
        if (this.workbench) {
          this.plusPane = 'root';
          this.showPlusMenu = !this.showPlusMenu;
        } else { this.showPlus = true; }
      } })
      .bindPopup(this.showPlusMenu, { builder: this.plusMenu, placement: Placement.TopLeft,
        popupColor: $r('app.color.page_background'), backgroundBlurStyle: BlurStyle.NONE,
        radius: 20, enableArrow: false, autoCancel: true, mask: false, targetSpace: 8,
        onStateChange: (event) => { this.showPlusMenu = event.isVisible; } })
  }

  @Builder
  composer() {
    Stack({ alignContent: Alignment.Bottom }) {
      if (this.highestEffort() && this.composerExpanded()) {
        ComposerGlow({ active: true })
          .transition(TransitionEffect.OPACITY.animation({ duration: Motion.medium, curve: Motion.standard }))
      }
    // Keep the editor and toolbar mounted. Animate reserved space, never switch layout modes.
    Column() {
      if (this.thread.references.length > 0) {
        Scroll() {
          Column({ space: 4 }) {
            ForEach(this.thread.references, (item: ThreadReference) => {
              ThreadReferenceCard({ reference: item, removable: true, disabled: !this.canAttach(),
                onRemove: () => { this.app.removeThreadReference(item.threadId); } })
            }, (item: ThreadReference) => item.threadId)
          }.width('100%')
        }.width('100%').constraintSize({ maxHeight: 104 }).scrollBar(BarState.Auto)
      }
      if (this.thread.attachments.length > 0 || this.importing) {
        this.attachmentStrip()
      }
      TextArea({ text: this.app.draft, controller: this.composerController,
        placeholder: this.speechActive() ? t('请说出要输入的内容') : this.thread.archived ? t("已归档的对话无法继续") : this.app.generating ? t("补充要求，或排队下一项任务…")
          : !this.composerExpanded() ? t('输入消息…') : this.thread.teamEnabled ? t("描述目标，主 Agent 会按需组建团队…") : t('输入消息，/ 命令，$ 技能，@ 引用会话') }).fontFamily(this.appearance.fontFamily)
        .id('composer').fontSize(Font.body).fontColor($r('app.color.text_primary'))
        .allowDrop(ATTACHMENT_DROP_TYPES.concat(['general.plain-text', 'general.hyperlink', 'general.html']))
        .onDrop((event: DragEvent) => this.composerDrop(event))
        .placeholderColor($r('app.color.text_tertiary')).backgroundColor(Color.Transparent)
        .width('100%')
        .constraintSize({ minHeight: this.workbench && !this.voiceMode ? 88 : 44, maxHeight: this.composerExpanded() ? 160 : 44 }).maxLength(24000)
        .padding({ left: this.composerExpanded() ? 6 : 46, right: this.composerExpanded() ? 6 : 42,
          top: 10, bottom: this.composerExpanded() ? 4 : 10 }).borderRadius(0)
        .align(this.composerExpanded() ? Alignment.TopStart : Alignment.Start)
        .animation({ duration: Motion.medium, curve: Motion.standard })
        .visibility(this.voiceMode ? Visibility.Hidden : Visibility.Visible)
        .enabled(!this.thread.archived).focusable(!this.voiceMode && !this.speechActive()).enableKeyboardOnFocus(!this.voiceMode && !this.speechActive())
        .onWillChange((value: EditableTextChangeValue) => !this.speechActive() || value.content === this.app.draft)
        .onChange((value: string) => {
          if (!this.speechActive()) { this.app.setDraft(value); }
        })
        .onTextSelectionChange((start: number, end: number) => {
          this.composerSelectionStart = start; this.composerSelectionEnd = end;
        })
        .onFocus(() => { this.composerFocused = true; this.inspectingOutput = false; this.followOutput = true; this.follow(); })
        .onBlur(() => { this.composerFocused = false; })
        .onEditChange((editing: boolean) => { this.composerFocused = editing; })
    }
    .width('100%').padding({ left: 8, right: 8, top: this.composerExpanded() ? 4 : 6,
      bottom: this.composerExpanded() ? (this.speechActive() ? 52 : 48) : 6 })
    .animation({ duration: Motion.medium, curve: Motion.standard })
      if (this.voiceMode) {
        Row({ space: 4 }) {
          this.composerAddButton()
          VoiceHoldButton({ phase: this.speech.phase, action: this.speechTarget, disabled: !this.canRecordSpeech(),
            onHold: (): boolean => this.startSpeech(), onMove: (x: number, y: number): void => this.moveSpeech(x, y),
            onRelease: (): void => this.releaseSpeech(), onCancel: (): void => this.cancelSpeechHold() }).layoutWeight(1)
          IconButton({ icon: $r('sys.symbol.keyboard'), label: t('切换到键盘输入'), compId: 'voice-keyboard', diameter: 36,
            iconSize: 20, fill: $r('app.color.surface_variant'), disabled: this.speechActive() || this.speechHolding,
            onTap: () => this.showSpeechKeyboard() })
        }.width('100%').height(56).padding({ left: 8, right: 8 })
      } else {
      Row() {
        if (this.speechActive()) {
          Blank()
        } else {
        this.composerAddButton()
        Scroll() {
        Row({ space: 4 }) {
        if (this.workbench) {
          Button() {
            Row({ space: 5 }) {
              SymbolGlyph($r('sys.symbol.wrench_and_screwdriver')).fontSize(15).fontColor([$r('app.color.text_secondary')])
              Text(agentModeName(this.thread.agentMode)).fontSize(12)
            }
          }.id('workbench-tool-scope').height(36).padding({ left: 8, right: 8 }).borderRadius(18)
            .backgroundColor(Color.Transparent).fontColor($r('app.color.text_secondary'))
            .enabled(!this.app.busy && !this.thread.archived && !this.app.saveError).onClick(this.onToolScope)
        }
        // A bare ring reads as a spinner at low usage; the percentage makes it a gauge.
        Row({ space: 4 }) {
          Progress({ value: this.app.contextUsed, total: Math.max(1, this.app.contextWindow), type: ProgressType.Ring })
            .width(16).height(16).color(this.contextColor()).backgroundColor($r('app.color.divider'))
            .style({ strokeWidth: 2.5 })
          Text(Math.round(this.contextRatio() * 100) + '%').fontFamily(this.appearance.fontFamily).fontSize(11)
            .fontColor(this.contextRatio() >= 0.85 ? $r('app.color.danger') : $r('app.color.text_tertiary'))
        }.id('context-usage').height(36).padding({ left: 8, right: 8 }).borderRadius(18)
        .stateStyles({ pressed: { .backgroundColor($r('app.color.surface_variant')) }, normal: { .backgroundColor(Color.Transparent) } })
        .accessibilityText(this.app.contextLabel)
        .onClick(() => { this.showContext = true; })
        .bindSheet($$this.showContext, this.contextSheet(), {
          title: { title: t("上下文") }, detents: [SheetSize.LARGE, SheetSize.MEDIUM],
          detentSelection: SheetSize.LARGE, preferType: this.workbench ? SheetType.CENTER : SheetType.BOTTOM,
          maskColor: '#33000000', dragBar: true,
          backgroundColor: $r('app.color.page_background'), onDisappear: () => { this.showSummary = false; }
        })
        if (!this.app.generating && this.app.configured && supportsReasoningEffort(
          this.app.providerProfiles.find((item) => item.id === this.thread.modelRef?.providerId)?.protocol || '', this.thread.modelRef?.modelId || '')) {
          Button({ type: ButtonType.Capsule }) {
            Text(reasoningEffortName(this.displayedEffort())).fontFamily(this.appearance.fontFamily).fontSize(12)
              .fontWeight(this.highestEffort() ? FontWeight.Medium : FontWeight.Regular)
              .fontColor(this.highestEffort() ? this.appearance.onAccentContainer : $r('app.color.text_secondary'))
          }.fontFamily(this.appearance.fontFamily).id('open-reasoning-effort').height(32).padding({ left: 8, right: 8 })
          .backgroundColor(this.highestEffort() ? this.appearance.userBubble : Color.Transparent)
          .enabled(!this.app.busy && !this.thread.archived && this.app.saveError.length === 0)
          .accessibilityText(t('推理强度') + '：' + reasoningEffortName(this.displayedEffort()))
          .onClick(() => { this.getUIContext().getFocusController().clearFocus(); this.showReasoning = !this.showReasoning; })
          .bindPopup(this.showReasoning, { builder: this.reasoningPicker, placement: Placement.Top,
            systemMaterial: this.appearance.surface, radius: 20, enableArrow: false, autoCancel: true,
            mask: false,
            onStateChange: (event) => {
              this.showReasoning = event.isVisible;
              if (!event.isVisible && !this.reasoningSaving) this.reasoningPreview = '';
            } })
        }
        if (this.thread.pendingInputs.length > 0) {
          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.clock')).fontSize(14).fontColor([this.appearance.onAccentContainer])
            Text(`${this.thread.queuePaused ? t("已暂停") : t("待发送")} ${this.thread.pendingInputs.length}`).fontFamily(this.appearance.fontFamily)
              .fontSize(Font.caption).fontWeight(FontWeight.Medium).fontColor(this.appearance.onAccentContainer)
          }
          .id('toggle-input-queue').height(30).padding({ left: 10, right: 12 }).borderRadius(15)
          .backgroundColor(this.appearance.accentContainer)
          .onClick(() => { this.showQueue = true; })
          .bindSheet($$this.showQueue, this.queueSheet(), {
            title: { title: t("待发送队列") }, detents: [SheetSize.MEDIUM, SheetSize.LARGE], dragBar: true,
            backgroundColor: $r('app.color.page_background')
          })
        }
        }
        }.layoutWeight(1).margin({ left: 4 }).align(Alignment.Start).scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
          .opacity(this.composerExpanded() ? 1 : 0)
          .translate({ y: this.composerExpanded() ? 0 : 4 })
          .animation({ duration: Motion.fast, curve: Motion.standard })
          .enabled(this.composerExpanded())
          .accessibilityLevel(this.composerExpanded() ? 'auto' : 'no-hide-descendants')
          .hitTestBehavior(this.composerExpanded() ? HitTestMode.Default : HitTestMode.None)
        }
        if (this.workbench) {
          Button() {
            Row({ space: 4 }) {
              Text(this.thread.modelRef?.modelId || t('选择模型')).fontSize(13).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: 170 })
              SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(9).fontColor([$r('app.color.text_secondary')])
                .rotate({ angle: this.showModelMenu ? 180 : 0 })
                .animation({ duration: Motion.fast, curve: Motion.standard })
            }.padding({ left: 8, right: 8 })
          }.id('workbench-model-picker').height(36).borderRadius(18)
            .constraintSize({ minWidth: 96, maxWidth: 220 })
            .backgroundColor(Color.Transparent).fontColor($r('app.color.text_secondary'))
            .stateStyles({ pressed: { .backgroundColor($r('app.color.surface_variant')) }, normal: { .backgroundColor(Color.Transparent) } })
            .enabled(!this.app.busy && !this.thread.archived && !this.app.saveError)
            .accessibilityText(t('选择模型') + '：' + (this.thread.modelRef?.modelId || t('选择模型')))
            .onClick(() => {
              this.getUIContext().getFocusController().clearFocus();
              this.showModelMenu = !this.showModelMenu;
            })
            .bindPopup(this.showModelMenu, { builder: this.modelMenu, placement: Placement.Top,
              popupColor: $r('app.color.page_background'), backgroundBlurStyle: BlurStyle.NONE,
              radius: 20, enableArrow: false, autoCancel: true, mask: false, targetSpace: 8,
              onStateChange: (event) => { this.showModelMenu = event.isVisible; } })
        }
        IconButton({ icon: $r('sys.symbol.mic'), label: t('切换到语音输入'), compId: 'start-speech', diameter: 36,
          iconSize: 19, fill: $r('app.color.surface_variant'), disabled: !this.canRecordSpeech(),
          onTap: () => this.enterVoiceMode() })
          .margin({ left: 4 })
        if (this.app.generating) {
          if (!this.speechActive() && this.hasDraft() && this.app.canQueueInput) {
            Button(t("追加")).fontFamily(this.appearance.fontFamily).id('steer-message').attributeModifier(Btn.tonalSmall)
              .margin({ left: 4 })
              .enabled(this.app.acceptingSteering).onClick(() => this.app.enqueueInput('steer'))
            Button(t("排队")).fontFamily(this.appearance.fontFamily).id('queue-message').attributeModifier(Btn.plainSmall)
              .margin({ left: 4 })
              .onClick(() => this.app.enqueueInput('followUp'))
          }
          IconButton({ icon: $r('sys.symbol.square_fill'), label: t("停止"), compId: 'stop-generation', diameter: 36,
            iconSize: 14, fill: $r('app.color.text_primary'), tint: $r('app.color.page_background'),
            onTap: () => { this.app.stop(); } })
            .margin({ left: 4 })
            .transition(Motion.pop())
        } else {
          if (!this.speechActive() && this.thread.pendingInputs.length > 0 && this.hasDraft()) {
            Button(t("排队")).fontFamily(this.appearance.fontFamily).id('queue-message').attributeModifier(Btn.plainSmall)
              .margin({ left: 4 })
              .enabled(this.app.canQueueInput).onClick(() => this.app.enqueueInput('followUp'))
          }
          Row() {
          IconButton({ icon: $r('sys.symbol.arrow_up'), label: t("发送"), compId: 'send-message', diameter: 36, iconSize: 18,
            fill: this.canSend() ? this.appearance.accent : $r('app.color.surface_variant'),
            tint: this.canSend() ? this.appearance.onAccent : $r('app.color.text_tertiary'),
            disabled: !this.canSend(), onTap: () => this.send() })
            .bindContextMenu(this.sendMenu, ResponseType.LongPress, {
              systemMaterial: this.appearance.surface, mask: false })
          }.width((this.workbench || this.hasDraft()) && !this.speechActive() ? 40 : 0).height(36)
            .padding({ left: (this.workbench || this.hasDraft()) && !this.speechActive() ? 4 : 0 }).clip(true)
            .opacity((this.workbench || this.hasDraft()) && !this.speechActive() ? 1 : 0)
            .animation({ duration: Motion.fast, curve: Motion.standard })
            .hitTestBehavior((this.workbench || this.hasDraft()) && !this.speechActive() ? HitTestMode.Default : HitTestMode.None)
            .accessibilityLevel((this.workbench || this.hasDraft()) && !this.speechActive() ? 'auto' : 'no-hide-descendants')
        }
      }.width('100%').height(this.speechActive() ? 48 : this.composerExpanded() ? 44 : 46)
        .padding({ left: 8, right: 8, bottom: this.composerExpanded() ? 8 : 10 })
        .animation({ duration: Motion.medium, curve: Motion.standard })
        .hitTestBehavior(this.composerExpanded() ? HitTestMode.Default : HitTestMode.Transparent)
      }
    }.id('composer-shell').width('100%').borderRadius(this.composerExpanded() ? Radius.xl : 28).clip(true)
    .backgroundColor($r('app.color.surface'))
    .border({ width: this.composerFocused ? 1 : 0.5,
      color: this.composerFocused ? this.appearance.accentOutline : $r('app.color.divider') })
    .shadow(this.composerFocused ? { radius: 28, color: this.appearance.accentGlow, offsetY: 4 }
      : { radius: 12, color: '#0A000000', offsetY: 2 })
    .animation({ duration: Motion.medium, curve: Motion.standard })
    // Anchor the sheet to the stable shell, not an add button that moves when the composer expands.
    .bindSheet($$this.showPlus, this.plusSheet(), {
      detents: [SheetSize.MEDIUM, SheetSize.LARGE], dragBar: true, showClose: false,
      backgroundColor: $r('app.color.page_background'), onDisappear: () => this.finishPlusAction()
    })
  }

  // Remote MCP calls pause the agent until the user decides; keep the card compact but impossible to miss.
  @Builder
  approvalCard() {
    Column({ space: 10 }) {
      Row({ space: Space.sm }) {
        SymbolGlyph($r('sys.symbol.connection')).fontSize(20).fontColor([this.appearance.accent])
        Column({ space: 2 }) {
          Text(t("允许调用远程工具？")).fontFamily(this.appearance.fontFamily).fontSize(Font.caption).fontColor($r('app.color.text_secondary'))
          Text(this.approval.title).fontFamily(this.appearance.fontFamily).id('approval-title').fontSize(15).fontWeight(FontWeight.Medium).maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_primary'))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Button(this.showApprovalDetails ? t("收起") : t("详情")).fontFamily(this.appearance.fontFamily).attributeModifier(Btn.textSmall)
          .onClick(() => { this.showApprovalDetails = !this.showApprovalDetails; })
      }.width('100%')
      if (this.showApprovalDetails) {
        Scroll() {
          Text(this.approval.details).fontSize(12).lineHeight(18).fontFamily('monospace').width('100%')
            .copyOption(CopyOptions.LocalDevice).fontColor($r('app.color.text_secondary'))
        }.constraintSize({ maxHeight: 160 }).width('100%').align(Alignment.TopStart).padding(10)
        .borderRadius(Radius.sm).backgroundColor($r('app.color.surface_variant'))
      }
      Row({ space: Space.sm }) {
        Button(t("拒绝")).fontFamily(this.appearance.fontFamily).id('deny-tool').attributeModifier(Btn.plainSmall).height(40).layoutWeight(1)
          .onClick(() => { this.showApprovalDetails = false; this.approval.respond(false); })
        Button(t("允许本次")).fontFamily(this.appearance.fontFamily).id('approve-tool').attributeModifier(Btn.primarySmall).height(40).layoutWeight(1)
          .onClick(() => { this.showApprovalDetails = false; this.approval.respond(true); })
      }.width('100%')
    }.width('100%').padding(Space.md).backgroundColor($r('app.color.surface')).borderRadius(Radius.lg)
    .border({ width: 1, color: this.appearance.accentContainer })
    .shadow({ radius: 16, color: '#1A000000', offsetY: 2 })
    .transition(Motion.rise(0, 24))
  }

  build() {
    // Keep the cover on its own node: a false bindSheet on the same node removes an active cover on device.
    Stack() {
    Column() {
      Blank().height(0).layoutWeight(this.centeredWelcome() ? 1 : 0)
      Stack({ alignContent: Alignment.BottomStart }) {
        Column() {
          if (this.thread.messages.length === 0 && this.app.teams.length === 0) {
            this.welcome()
          } else {
            this.messageList()
          }
        }.width('100%').height('100%').zIndex(this.sendingMessageId ? 1 : 0)
        if (this.viewport.keyboardHeight > 0 && !this.voiceMode && !this.voiceOverlayVisible()) { this.teamToggle() }
        if (this.voiceOverlayVisible()) {
          VoiceRecordingOverlay({ phase: this.speech.phase === 'complete' ? 'finishing' : this.speech.phase,
            text: this.speech.text, speaking: this.speech.speaking, action: this.speechTarget,
            onTargetArea: (action: VoiceAction, rect: VoiceTargetRect): void => {
              if (action === 'cancel') { this.cancelVoiceRect = rect; } else { this.editVoiceRect = rect; }
            }, onCancel: (): void => this.releaseSpeech('cancel'), onEdit: (): void => this.releaseSpeech('edit') })
            .align(Alignment.Bottom).zIndex(5).transition(Motion.rise(0, 52))
        }
      }.id('chat-swipe-area').height(this.centeredWelcome() ? 112 : 0).layoutWeight(this.centeredWelcome() ? 0 : 1).width('100%').zIndex(this.sendingMessageId ? 1 : 0)
      // Normal priority lets nested horizontal scrollers keep their gestures. The composer
      // stays outside this region so selecting or moving through draft text does not open history.
      .gesture(PanGesture({ fingers: 1, isFingerCountLimited: true, direction: PanDirection.Right, distance: 8 })
        .onActionStart((event: GestureEvent) => this.onHistoryDragStart(event))
        .onActionUpdate((event: GestureEvent) => this.onHistoryDragUpdate(event))
        .onActionEnd((event: GestureEvent) => this.onHistoryDragEnd(event))
        .onActionCancel(() => this.onHistoryDragCancel()))
      Column({ space: Space.sm }) {
        if (this.app.searchMessageId) { Banner({ text: this.app.searchQuery ? t("匹配：") + this.app.searchQuery : t("历史节点"), danger: false, actionLabel: t("定位"), onAction: () => this.locate() }).onAppear(() => { setTimeout(() => this.locate(), 100); }) }
        if (this.browser.permissionPending || this.browser.open || this.browser.error) {
          BrowserStatusCard({ browser: this.browser, onOpen: this.onBrowser })
        }
        if (this.approval.form) { InputFormCard({ approval: this.approval }) }
        if (this.approval.title) {
          this.approvalCard()
        }
        if (this.thread.archived) {
          Banner({ text: t("这段对话已归档"), danger: false, actionLabel: t("恢复对话"), actionId: 'restore-thread',
            actionEnabled: !this.app.busy && this.app.saveError.length === 0,
            onAction: () => { this.app.archiveThread(this.thread.id); } })
        }
        if (this.app.compatibilityWarnings.length > 0) {
          Banner({ text: t('部分配置来自较新版本，相关功能暂不可用。原配置已保留。'), danger: false,
            compId: 'configuration-compatibility', actionLabel: t('查看详情'), actionId: 'configuration-compatibility-details',
            onAction: () => this.getUIContext().showAlertDialog({ systemMaterial: this.appearance.surface,
              title: t('配置兼容性'), message: this.app.compatibilityWarnings.join('\n\n'),
              confirm: { value: t('知道了'), action: () => {} } }) })
        }
        if (this.app.error.length > 0) {
          Banner({ text: this.app.error, compId: 'chat-error', actionLabel: t("关闭"), actionId: 'dismiss-error',
            onAction: () => { this.app.error = ''; } })
        }
        if (this.reading.messageId) {
          Banner({ text: this.reading.preparing ? t('正在准备朗读…') : t('正在朗读回答'), danger: false,
            compId: 'answer-speech', actionId: 'stop-answer-speech', actionLabel: t('停止朗读'), onAction: () => this.reading.stop() })
        }
        if (this.reading.error) {
          Banner({ text: this.reading.error, compId: 'answer-speech-error', actionLabel: t('关闭'),
            onAction: () => { this.reading.error = ''; } })
        }
        if (this.speech.error.length > 0) {
          Banner({ text: this.speech.error, compId: 'speech-error', actionId: 'speech-error-action',
            actionLabel: this.unwrittenSpeech ? t('复制识别文字') : this.speech.permissionDenied ? t('允许麦克风') : t('关闭'),
            onAction: () => this.speechErrorAction() })
        }
        if (this.app.saveError.length > 0) {
          Banner({ text: this.app.saveError, actionLabel: t("重试保存"), actionId: 'retry-save',
            actionEnabled: !this.app.busy, onAction: () => { this.app.retrySave(); } })
        }
        if (!this.app.busy && this.thread.messages.length > 0
          && this.thread.messages[this.thread.messages.length - 1].status !== 'complete') {
          Button() {
            Row({ space: 6 }) {
              SymbolGlyph($r('sys.symbol.arrow_clockwise')).fontSize(15).fontColor([this.appearance.onAccentContainer])
              Text(t("重新编辑并发送")).fontFamily(this.appearance.fontFamily).fontSize(13).fontColor(this.appearance.onAccentContainer)
            }
          }.fontFamily(this.appearance.fontFamily).id('retry-message').attributeModifier(Btn.tonalSmall).clickEffect(Motion.press)
          .transition(Motion.rise()).onClick(() => this.app.retryPrompt())
        }
        if (this.teamSuggested()) {
          this.commandSuggestion()
        }
        if (this.commandSuggested('/compact')) { this.compactSuggestion() }
        if (this.skillSuggested()) { this.skillSuggestions() }
        if (this.referenceSuggested()) { this.referenceSuggestions() }
        // The latest turn's plan stays beside the composer, outside the scrolling transcript.
        ForEach(this.thread.messages.slice(-1).filter((message) => message.role === 'assistant'), (message: MessageViewModel) => {
          ChatPlanPanel({ plan: message.plan })
        }, (message: MessageViewModel) => this.thread.id + ':' + message.id)
        if (this.account.ready && !this.account.signedIn && !this.workbench) {
          Banner({ text: t('登录华为账号后即可使用 AI 生成功能。'), danger: false, compId: 'chat-login-required',
            actionLabel: t('去登录'), actionId: 'chat-open-account', onAction: this.onAccount })
        }
        if (this.workbench && this.thread.messages.length === 0) { this.workbenchContext() }
        this.composer()
        if (this.workbench && this.account.ready && !this.account.signedIn) {
          Row({ space: 8 }) {
            Text(t('登录华为账号后即可使用 AI 生成功能。')).fontSize(12).fontColor($r('app.color.text_secondary')).layoutWeight(1)
            Button(t('去登录')).id('workbench-open-account').attributeModifier(Btn.textSmall).onClick(this.onAccount)
          }.width('100%').padding({ left: 8, right: 8 })
        }
        if (this.viewport.keyboardHeight === 0) {
          Text(t('AI生成内容可能有误，请仔细鉴别。')).fontFamily(this.appearance.fontFamily).id('ai-disclaimer')
            .fontSize(Font.caption).fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Center).width('100%').padding({ left: Space.sm, right: Space.sm })
        }
      }.width('100%').padding({ left: this.workbench ? 24 : 10, right: this.workbench ? 24 : 10, bottom: Space.sm })
      Blank().height(0).layoutWeight(this.centeredWelcome() ? 1 : 0)
    }.height('100%').width('100%')
      .bindSheet($$this.showMemoryDraft, this.memoryDraftSheet(), { title: { title: t("提炼并确认记忆") }, detents: [SheetSize.LARGE], dragBar: true, keyboardAvoidMode: SheetKeyboardAvoidMode.RESIZE_ONLY,
        backgroundColor: $r('app.color.page_background') })
      if (this.dropHover) {
        Column() {
          Text(t('松开以添加到当前会话')).fontFamily(this.appearance.fontFamily).fontSize(Font.body)
            .fontColor($r('app.color.text_primary')).padding(20).backgroundColor($r('app.color.page_background')).borderRadius(Radius.xl)
        }.width('100%').height('100%').justifyContent(FlexAlign.Center).backgroundColor('#33000000')
          .hitTestBehavior(HitTestMode.None).id('attachment-drop-hint')
      }
    }.width('100%').height('100%')
      .allowDrop(ATTACHMENT_DROP_TYPES)
      .onDragEnter((event: DragEvent) => this.dragAttachment(event))
      .onDragMove((event: DragEvent) => this.dragAttachment(event))
      .onDragLeave(() => { this.dropHover = false; })
      .onDrop((event: DragEvent) => { this.receiveAttachmentDrop(event); }, { disableDataPrefetch: true })
      .onAreaChange((_old: Area, area: Area) => { this.panelHeight = Number(area.height); })
      .bindContentCover(this.showDrawing || this.previewing, this.chatCover(), { modalTransition: ModalTransition.ALPHA,
        backgroundColor: $r('app.color.page_background'), onWillDismiss: () => {
          if (this.showDrawing) { this.closeDrawing(); } else { this.previewing = false; }
        } })
  }
}
