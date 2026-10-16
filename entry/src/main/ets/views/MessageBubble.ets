import { AppearanceStyle } from '../common/AppearanceStyle';
import { t } from '../model/I18n';
import { stepDisplayContent, stepPreviews, PublishedPreview } from '../model/PublishedPreview';
import { PublishedPreviewCard } from './PublishedPreviewCard';
import { PresentedFile, deliveredFiles } from '../model/Deliverables';
import { turnFileChanges } from '../model/TurnFileChanges';
import { TurnChangesCard } from './TurnChangesCard';
import { pasteboard } from '@kit.BasicServicesKit';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { MarkdownView } from './MarkdownView';
import { InteractiveAnswer } from './InteractiveAnswer';
import { UiValues } from '../model/InteractiveUi';
import { DocumentPreview } from './DocumentPreview';
import { DataViewCard } from './DataViewCard';
import { Attachment } from '../model/Productivity';
import { Attachments } from '../services/Attachments';
import { MessageViewModel, ToolExecutionViewModel } from '../viewmodel/ChatViewModel';
import { Btn, Font, Motion, Radius, Space, fileSize, systemInsets } from '../common/Theme';
import { MessageUsage } from './MessageUsage';
import { ThinkingDisclosure } from './ThinkingDisclosure';
import { ThreadReferenceCard } from './ThreadReferenceCard';
import { ThreadReference } from '../model/ThreadReferences';
import { DisclosureState } from '../viewmodel/DisclosureState';
import { ToolDetails } from './ToolDetails';
import { OrchestrationReceipts } from './OrchestrationReceipts';
import { ProcessItem, TimelineEntry, buildTimeline, describeTools, durationLabel, elapsedMs, foldsToAnswer, persistentTool,
  summarizeProcess, thoughtTail, turnPhase, workflowEntryState } from '../model/ProcessPresentation';
import { toolFavicon, toolStat, toolTitle, toolStatusLabel } from '../model/ToolPresentation';
import { WebsiteIcon } from '../common/WebsiteIcon';
import { ThinkingLine } from '../common/Widgets';
import { SendBubbleMotion, SendOrigin } from '../common/SendBubbleMotion';

interface ToolArguments { path?: string; url?: string; query?: string; pattern?: string; name?: string; tool?: string; prompt?: string; title?: string;
  goal?: string; members?: Object[]; tasks?: Object[]; waitFor?: string; action?: string; }

function TEAM_ACTIONS(): Record<string, string> { return { 'pause': t("暂停派发"), 'cancel': t("取消员工"), 'retry': t("重试任务") }; }

@Builder
function noContent() {}


// The most telling argument (file, link, query…) shown next to the tool name.
function toolDetail(execution: ToolExecutionViewModel): string {
  const name = execution.call.function.name;
  try {
    const args = JSON.parse(execution.call.function.arguments) as ToolArguments;
    if (name === 'team_recruit') {
      const members = args.members?.length || 0; const tasks = args.tasks?.length || 0;
      return members ? t('{0} 位员工 · {1} 个任务', [members, tasks]) : t('{0} 个任务', [tasks]);
    }
    if (name === 'team_wait') { return args.waitFor === 'all_tasks' ? t("全部任务") : t("下一份交接"); }
    if (name === 'team_control') { return TEAM_ACTIONS()[args.action || ''] || ''; }
    if (name.startsWith('team_')) { return ''; }
    return args.path || args.url || args.query || args.pattern || args.tool || args.title || args.name || args.prompt || '';
  } catch (_) { return ''; }
}

function toolIcon(name: string): Resource {
  if (name.startsWith('team_')) { return $r('sys.symbol.person_2'); }
  if (name === 'read_web') { return $r('sys.symbol.magnifyingglass'); }
  if (name === 'read_skill') { return $r('sys.symbol.wand_and_stars'); }
  if (name === 'list_files') { return $r('sys.symbol.rectangle_stack'); }
  if (name === 'write_file' || name === 'edit_file') { return $r('sys.symbol.square_and_pencil'); }
  if (name === 'read_file' || name === 'read_file_lines' || name === 'read_attachment') { return $r('sys.symbol.doc_text'); }
  if (name === 'find_files' || name === 'search_file_content' || name === 'mcp_search_tools') { return $r('sys.symbol.magnifyingglass'); }
  if (name === 'generate_image') { return $r('sys.symbol.picture'); }
  if (name === 'update_plan') { return $r('sys.symbol.list_bullet'); }
  if (name === 'request_user_input') { return $r('sys.symbol.questionmark_circle'); }
  if (name === 'publish_data_view') { return $r('sys.symbol.text_alignleft'); }
  return $r('sys.symbol.connection');
}

function activeTool(tool: ToolExecutionViewModel): boolean { return tool.status === 'running' || tool.status === 'pending'; }

// Results that stay in view even when their process group or the whole answer is folded: charts and forms to resume.
@Component
struct RichToolResult {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink execution: ToolExecutionViewModel;
  onResume: (id: string) => void = () => {};

  private name(): string { return this.execution.call.function.name; }
  build() {
    Column({ space: Space.sm }) {
      if (this.name() === 'request_user_input' && ['interrupted', 'cancelled'].includes(this.execution.status)) {
        Button() {
          Row({ space: 6 }) {
            SymbolGlyph($r('sys.symbol.arrow_clockwise')).fontSize(15).fontColor([this.appearance.onAccentContainer])
            Text(t("重新填写并继续")).fontFamily(this.appearance.fontFamily).fontSize(13).fontColor(this.appearance.onAccentContainer)
          }
        }.fontFamily(this.appearance.fontFamily).attributeModifier(Btn.tonalSmall).onClick(() => this.onResume(this.execution.call.id))
      }
      if (this.execution.status === 'complete' && this.name() === 'publish_data_view') {
        DataViewCard({ content: this.execution.output })
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}

// One tool inside an opened process group; tapping expands its details in place.
@Component
struct ToolRow {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop webEnabled: boolean = false;
  @ObjectLink @Watch('statusChanged') execution: ToolExecutionViewModel;
  @ObjectLink disclosure: DisclosureState;
  onInspect: () => void = () => {};
  @State private glyphShift: number = 0;
  @State private glyphOpacity: number = 1;
  private lastStatus: string = '';

  aboutToAppear(): void { this.lastStatus = this.execution.status; }

  // Live status changes get feedback; results restored from history mount quietly.
  statusChanged(): void {
    const previous = this.lastStatus;
    const next = this.execution.status;
    this.lastStatus = next;
    if (previous === next || (previous !== 'running' && previous !== 'pending')) { return; }
    this.glyphShift = 8; this.glyphOpacity = 0;
    this.getUIContext().animateTo({ duration: 180, curve: Motion.standard }, () => { this.glyphShift = 0; this.glyphOpacity = 1; });
  }

  private name(): string { return this.execution.call.function.name; }
  private stat(): string {
    return toolStat(this.name(), this.execution.call.function.arguments, this.execution.output, this.execution.status, this.execution.fileDiff);
  }

  build() {
    Column() {
      Row({ space: 6 }) {
        if (this.name() === 'read_web' && this.execution.status === 'complete') {
          WebsiteIcon({ source: toolFavicon(this.name(), this.execution.websiteIcon, this.execution.status, this.webEnabled) })
        } else {
          SymbolGlyph(toolIcon(this.name())).fontSize(13)
            .fontColor([this.execution.status === 'failed' ? $r('app.color.danger') : $r('app.color.text_tertiary')])
        }
        Text(toolTitle(this.name())).fontFamily(this.appearance.fontFamily).fontSize(13).maxLines(1).flexShrink(0).fontColor($r('app.color.text_secondary'))
        Text(toolDetail(this.execution)).fontFamily(this.appearance.fontFamily).fontSize(12).maxLines(1).layoutWeight(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_tertiary'))
        Stack() {
          if (this.execution.status === 'running') {
            LoadingProgress().width(12).height(12).color(this.appearance.accent)
          } else if (this.execution.status === 'complete') {
            Text(this.stat()).fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_tertiary'))
          } else {
            Text(toolStatusLabel(this.execution.status)).fontFamily(this.appearance.fontFamily).fontSize(12)
              .fontColor(this.execution.status === 'failed' ? $r('app.color.danger') : $r('app.color.text_tertiary'))
          }
        }.translate({ y: this.glyphShift }).opacity(this.glyphOpacity)
        SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(11).fontColor([$r('app.color.text_tertiary')])
          .rotate({ angle: this.disclosure.open ? 180 : 0 })
      }.id('tool-' + this.execution.call.id).width('100%').height(44)
      .accessibilityText((this.disclosure.open ? t('收起') : t('展开')) + ' ' + toolTitle(this.name()) + ' ' + toolStatusLabel(this.execution.status))
      .onClick(() => {
        this.onInspect();
        this.getUIContext().animateTo({ duration: Motion.medium, curve: Motion.standard }, () => { this.disclosure.open = !this.disclosure.open; });
      })
      if (this.disclosure.open) {
        Column() {
          ToolDetails({ disclosure: this.disclosure, identity: this.execution.call.id, name: this.name(), argumentsText: this.execution.call.function.arguments,
            output: this.execution.output, status: this.execution.status, diff: this.execution.fileDiff, onInspect: this.onInspect })
          if (this.execution.children.length > 0) {
            OrchestrationReceipts({ children: this.execution.children, disclosures: this.disclosure.children, onInspect: this.onInspect })
          }
        }.width('100%').padding({ left: 19 })
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}

// Everything between two pieces of narration: thinking and tool calls folded into one line that reads like a sentence.
@Component
struct ProcessGroup {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop webEnabled: boolean = false;
  @ObjectLink message: MessageViewModel;
  @ObjectLink disclosure: DisclosureState;
  @Prop groupKey: string = '';
  // When the whole answer is folded only results that need attention remain.
  @Prop richOnly: boolean = false;
  onResume: (id: string) => void = () => {};
  onInspect: () => void = () => {};

  // Resolved from the message on every render so a growing group never shows a stale snapshot.
  private items(): ProcessItem[] {
    return buildTimeline(this.message.stepViews).find((entry: TimelineEntry) => entry.key === this.groupKey)?.items || [];
  }
  private toolAt(item: ProcessItem): ToolExecutionViewModel | undefined {
    return item.tool < 0 ? undefined : this.message.stepViews[item.step]?.tools[item.tool];
  }
  private tools(): ToolExecutionViewModel[] {
    const tools: ToolExecutionViewModel[] = [];
    for (const item of this.items()) {
      const tool = this.toolAt(item);
      if (tool) { tools.push(tool); }
    }
    return tools;
  }
  private richTools(): ToolExecutionViewModel[] {
    return this.tools().filter((tool: ToolExecutionViewModel) => persistentTool(tool));
  }
  private thought(): boolean { return this.items().some((item: ProcessItem) => item.tool < 0); }
  private failures(): number { return this.tools().filter((tool: ToolExecutionViewModel) => tool.status === 'failed').length; }
  private running(): ToolExecutionViewModel | undefined {
    return this.message.status === 'generating' ? this.tools().find(activeTool) : undefined;
  }
  // The model is still thinking when the group ends in the latest step's thought with nothing said or called after it.
  private thinkingNow(): boolean {
    const items = this.items();
    if (this.message.status !== 'generating' || !items.length) { return false; }
    const last = items[items.length - 1];
    const step = this.message.stepViews[last.step];
    return last.tool < 0 && step !== undefined && last.step === this.message.stepViews.length - 1 &&
      step.tools.length === 0 && step.content.trim().length === 0;
  }
  private active(): boolean { return this.running() !== undefined || this.thinkingNow(); }
  private label(): string {
    const running = this.running();
    if (running) { return t('正在{0}', [toolTitle(running.call.function.name)]); }
    if (this.thinkingNow()) { return t('正在思考'); }
    const parts: string[] = [];
    if (this.thought()) { parts.push(t('已思考')); }
    if (this.tools().length) { parts.push(describeTools(this.tools())); }
    return parts.join(t('，'));
  }
  private detail(): string {
    const running = this.running();
    if (running) { return toolDetail(running); }
    const items = this.items();
    return this.thinkingNow() ? thoughtTail(this.message.stepViews[items[items.length - 1].step].reasoningContent) : '';
  }
  private icon(): Resource {
    const tools = this.tools();
    if (!tools.length) { return $r('sys.symbol.lightbulb'); }
    const edit = tools.find((tool: ToolExecutionViewModel) => ['write_file', 'edit_file'].includes(tool.call.function.name));
    return toolIcon((edit || tools[tools.length - 1]).call.function.name);
  }

  @Builder
  header() {
    Row({ space: 6 }) {
      ThinkingLine({ label: this.label(), working: this.active(), compact: true,
        icon: this.failures() > 0 ? $r('sys.symbol.exclamationmark_circle') : this.icon(), danger: this.failures() > 0 })
      if (this.active()) {
        Text(this.detail()).fontFamily(this.appearance.fontFamily).fontSize(12).maxLines(1).layoutWeight(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_tertiary'))
      } else {
        if (this.failures() > 0) {
          Text(t('{0} 次失败', [this.failures()])).fontFamily(this.appearance.fontFamily).fontSize(12).flexShrink(0).fontColor($r('app.color.danger'))
        }
        Blank()
      }
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(11).fontColor([$r('app.color.text_tertiary')])
      }.width(16).height(16).rotate({ angle: this.disclosure.open ? 180 : 0 })
        .animation({ duration: Motion.medium, curve: Motion.standard })
    }.id(this.groupKey + '-' + this.message.id).width('100%').height(44)
    .accessibilityText((this.disclosure.open ? t('收起') : t('展开')) + ' ' + this.label())
    .onClick(() => {
      this.onInspect();
      this.getUIContext().animateTo({ duration: Motion.medium, curve: Motion.standard }, () => {
        this.disclosure.open = !this.disclosure.open;
        // Completion must not hide a process the user explicitly chose to read.
        if (this.disclosure.open) { this.message.processOpen = true; }
      });
    })
  }

  build() {
    Column({ space: Space.sm }) {
      if (!this.richOnly && this.items().length > 0) {
        Column() {
          if (this.items().length > 1 || this.thought()) { this.header() }
          if (this.disclosure.open || (this.items().length === 1 && !this.thought())) {
            Column() {
              ForEach(this.items(), (item: ProcessItem) => {
                if (item.tool < 0) {
                  Column() {
                    ThinkingDisclosure({ content: this.message.stepViews[item.step]?.reasoningContent || '',
                      disclosure: this.message.disclosures.get('thinking-' + item.step),
                      streaming: this.thinkingNow() && item.step === this.message.stepViews.length - 1,
                      identity: this.message.id + '-' + item.step, onInspect: this.onInspect })
                  }.width('100%').padding({ top: 6, bottom: 6 })
                } else if (this.toolAt(item)) {
                  ToolRow({ execution: this.toolAt(item) as ToolExecutionViewModel, webEnabled: this.webEnabled,
                    disclosure: this.message.disclosures.get('tool-' + (this.toolAt(item) as ToolExecutionViewModel).call.id),
                    onInspect: () => { this.disclosure.open = true; this.message.processOpen = true; this.onInspect(); } })
                }
              }, (item: ProcessItem) => item.step + '-' + item.tool)
            }.width('100%').alignItems(HorizontalAlign.Start)
            .padding({ left: this.items().length === 1 && !this.thought() ? 0 : 12 }).margin({ bottom: 4 })
            .border({ width: { left: this.items().length === 1 && !this.thought() ? 0 : 1 }, color: $r('app.color.divider') })
            .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: -3 }))
              .animation({ duration: Motion.medium, curve: Motion.standard }))
          }
        }.width('100%').alignItems(HorizontalAlign.Start)
      }
      ForEach(this.richTools(), (tool: ToolExecutionViewModel) => {
        RichToolResult({ execution: tool, onResume: this.onResume })
      }, (tool: ToolExecutionViewModel) => tool.call.id)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}

// Full-screen image viewer: pinch or double-tap to zoom, drag when zoomed, tap or back to close.
@Component
export struct ImageViewer {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  path: string = '';
  onClose: () => void = () => {};
  @State private zoom: number = 1;
  @State private insetTop: number = 0;
  @State private offsetX: number = 0;
  @State private offsetY: number = 0;
  private pinchBase: number = 1;
  private panBaseX: number = 0;
  private panBaseY: number = 0;

  aboutToAppear(): void {
    systemInsets(this.getUIContext()).then((insets: number[]) => { this.insetTop = insets[0]; });
  }

  private reset(): void {
    this.getUIContext().animateTo({ duration: 200, curve: Curve.FastOutSlowIn }, () => {
      this.zoom = 1; this.offsetX = 0; this.offsetY = 0;
    });
  }

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Image('file://' + this.path).width('100%').height('100%').objectFit(ImageFit.Contain)
        .scale({ x: this.zoom, y: this.zoom }).translate({ x: this.offsetX, y: this.offsetY })
        .gesture(GestureGroup(GestureMode.Exclusive,
          TapGesture({ count: 2 }).onAction(() => {
            if (this.zoom > 1) { this.reset(); return; }
            this.getUIContext().animateTo({ duration: 200, curve: Curve.FastOutSlowIn }, () => { this.zoom = 2.5; });
          }),
          TapGesture({ count: 1 }).onAction(() => this.onClose()),
          PinchGesture()
            .onActionStart(() => { this.pinchBase = this.zoom; })
            .onActionUpdate((event: GestureEvent) => { this.zoom = Math.min(5, Math.max(1, this.pinchBase * event.scale)); })
            .onActionEnd(() => { if (this.zoom <= 1.05) { this.reset(); } }),
          PanGesture()
            .onActionStart(() => { this.panBaseX = this.offsetX; this.panBaseY = this.offsetY; })
            .onActionUpdate((event: GestureEvent) => {
              if (this.zoom > 1) { this.offsetX = this.panBaseX + event.offsetX; this.offsetY = this.panBaseY + event.offsetY; }
            })))
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(20).fontColor([Color.White])
      }.fontFamily(this.appearance.fontFamily).width(44).height(44).backgroundColor('#4D000000').margin({ top: this.insetTop + 8, right: 12 })
      .accessibilityText(t("关闭")).onClick(() => this.onClose())
    }.width('100%').height('100%').backgroundColor(Color.Black)
  }
}

@Component
export struct MessageBubble {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop latestPreviewIds: string[] = [];
  @Prop @Watch('syncWorkflow') turnStatus: string = '';
  @State private settled: boolean = false;
  @State private workflowCollapsed: boolean = false;
  @Prop sendOrigin: SendOrigin | undefined = undefined;
  onSendReady: () => void = () => {};
  onSendFinish: () => void = () => {};
  @Prop readingMessageId: string = '';
  onRead: (id: string) => void = () => {};
  @Prop webEnabled: boolean = false;
  onOpenFile: (path: string) => void = () => {};
  @Prop actionsEnabled: boolean = true;
  onRegenerate: (id: string) => void = () => {};
  @Prop uiAvailable: boolean = false;
  onUi: (key: string, values: UiValues, action: string) => Promise<UiValues> = async () => { throw new Error('Interactive UI handler is not connected'); };
  @ObjectLink message: MessageViewModel;
  onFork: (id: string) => void = () => {};
  onRemember: (messageId: string) => void = () => {};
  onReference: (text: string) => void = () => {};
  onResume: (id: string) => void = () => {};
  onInspect: () => void = () => {};
  // Rich content attached to an answer (the chat team card) sits above the answer actions.
  @Prop hasExtra: boolean = false;
  @BuilderParam extra: () => void = noContent;
  @State private documentOpen: boolean = false;
  @State private documentName: string = '';
  @State private documentText: string = '';
  @State private selectingText: boolean = false;
  @State private previewPath: string = '';
  @State private previewing: boolean = false;

  private timeline(): TimelineEntry[] { return buildTimeline(this.message.stepViews); }
  aboutToAppear(): void { this.settled = this.turnStatus === 'complete'; }
  private syncWorkflow(): void {
    this.getUIContext().animateTo({ duration: 280, curve: Motion.standard }, () => {
      this.settled = this.turnStatus === 'complete';
      // Interrupted work remains visible, including errors and pending questions.
      if (this.turnStatus !== 'generating') { this.workflowCollapsed = false; }
    });
  }
  // A finished answer folds its narration and process behind the elapsed time so the reply leads on a phone screen.
  private foldable(): boolean { return this.settled && foldsToAnswer(this.timeline()); }
  private folded(): boolean { return this.workflowCollapsed || (this.foldable() && !this.message.processOpen); }
  private workflowLabel(): string {
    const phase = turnPhase(this.message.status, this.message.stepViews);
    if (phase === 'tools') {
      for (const step of this.message.stepViews) {
        const tool = step.tools.find(activeTool);
        if (tool) { return t('正在{0}', [toolTitle(tool.call.function.name)]); }
      }
    }
    if (phase === 'answer') { return t('正在生成回答'); }
    if (phase === 'thinking') { return t('正在思考'); }
    if (phase === 'retry') { return t('正在重试'); }
    if (phase === 'generating' || phase === 'waiting') { return t('等待模型响应'); }
    if (phase === 'stopped') { return t('已停止'); }
    if (phase === 'failed') { return t('未完成'); }
    return this.processSummary();
  }
  private workflowVisible(): boolean {
    return this.message.status === 'generating' || this.message.stepViews.length > 0;
  }
  private traceEntry(entry: TimelineEntry): boolean {
    const entries = this.timeline();
    return entry.kind !== 'steering' && !(entry.kind === 'text' && entries[entries.length - 1]?.key === entry.key);
  }
  private traceState(entry: TimelineEntry): string {
    const live = this.timeline().find((item: TimelineEntry) => item.key === entry.key) || entry;
    return workflowEntryState(live, this.message.stepViews, this.message.status);
  }
  private entryVisible(entry: TimelineEntry, index: number, count: number): boolean {
    if (!this.folded()) { return true; }
    if (entry.kind === 'text') { return index === count - 1 || stepDisplayContent(this.message.stepViews[entry.step]).includes('```tinybot-ui'); }
    if (entry.kind !== 'process') { return true; }
    // Empty folded groups must not mount: the parent Column adds spacing even to empty children.
    const live = this.timeline().find((item: TimelineEntry) => item.key === entry.key) || entry;
    return live.items.some((item: ProcessItem) => {
      const tool = this.message.stepViews[item.step]?.tools[item.tool];
      return tool !== undefined && persistentTool(tool);
    });
  }
  private processSummary(): string {
    const elapsed = elapsedMs(this.message.steps);
    return elapsed > 0 ? t('用时 {0}', [durationLabel(elapsed)])
      : t('执行记录 · {0} 次操作', [summarizeProcess(this.message.stepViews).operations]);
  }
  private failures(): number { return summarizeProcess(this.message.stepViews).failures; }
  // A new step has started but the model has not produced anything for it yet.
  private awaitingModel(): boolean {
    const steps = this.message.stepViews;
    const last = steps[steps.length - 1];
    return this.message.status === 'generating' && last !== undefined && last.tools.length === 0 &&
      last.content.trim().length === 0 && last.reasoningContent.trim().length === 0;
  }

  private retryStatus(): string {
    const steps = this.message.stepViews;
    const retries = steps[steps.length - 1]?.retries || [];
    const last = retries[retries.length - 1];
    if (!this.awaitingModel() || !last) { return ''; }
    return last.waiting ? t('连接暂时失败，{0} 秒后重试（{1}/2），可随时停止。', [last.delayMs / 1000, last.attempt]) : t('正在重试（{0}/2）', [last.attempt]);
  }

  private async copy(): Promise<void> {
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.message.content));
      this.getUIContext().getPromptAction().showToast({ systemMaterial: this.appearance.surface, message: t("已复制") });
    } catch (_) { this.getUIContext().getPromptAction().showToast({ systemMaterial: this.appearance.surface, message: t("复制失败，请长按文本选择复制。") }); }
  }

  private images(): Attachment[] { return this.message.attachments.filter((item) => item.mime === 'image/jpeg'); }
  private files(): Attachment[] { return this.message.attachments.filter((item) => item.mime !== 'image/jpeg'); }
  private preview(item: Attachment): void { this.previewPath = Attachments.path(item); this.previewing = true; }
  @Builder
  documentViewer() {
    DocumentPreview({ name: this.documentName, content: this.documentText, messageText: this.selectingText,
      onReference: this.onReference, onClose: () => { this.documentOpen = false; } })
  }

  @Builder
  actions() {
    Menu() {
      if (this.message.content.length > 0) {
        MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.rectangle_on_rectangle')), content: t("复制") })
          .onClick(() => this.copy())
        MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.textformat')), content: t('选择文本') }).onClick(() => {
          this.selectingText = true; this.documentName = t('消息文本'); this.documentText = this.message.content; this.documentOpen = true;
        })
      }
      MenuItem({ startIcon: $r('app.media.message_branch'),
        content: this.message.role === 'user' ? t("从这里改写（新分支）") : t("从这里创建分支") })
        .enabled(this.actionsEnabled).onClick(() => this.onFork(this.message.id))
      if (this.message.role === 'assistant' && this.message.status !== 'generating') {
        if (this.message.content.trim().length > 0) {
          MenuItem({ symbolStartIcon: new SymbolGlyphModifier(this.readingMessageId === this.message.id ?
            $r('sys.symbol.stop_circle_fill') : $r('sys.symbol.speaker_wave_2')),
            content: this.readingMessageId === this.message.id ? t('停止朗读') : t('朗读回答') })
            .id('read-answer-' + this.message.id).onClick(() => this.onRead(this.message.id))
        }
        MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.arrow_clockwise')), content: t('重新生成（保留原回答）') })
          .enabled(this.actionsEnabled).onClick(() => this.onRegenerate(this.message.id))
      }
      if (this.message.content.length > 0) {
        MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.lightbulb')), content: t("提炼为记忆…") })
          .enabled(this.actionsEnabled).onClick(() => this.onRemember(this.message.id))
      }
    }
  }

  @Builder
  viewer() {
    ImageViewer({ path: this.previewPath, onClose: () => { this.previewing = false; } })
  }

  @Builder
  actionButton(icon: Resource, label: string, compId: string, action: () => void,
    enabled: () => boolean = () => true, imageIcon: boolean = false) {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      if (imageIcon) {
        Image(icon).width(18).height(18).objectFit(ImageFit.Contain).fillColor($r('app.color.text_secondary'))
      } else {
        SymbolGlyph(icon).fontSize(18).fontColor([$r('app.color.text_secondary')])
      }
    }.fontFamily(this.appearance.fontFamily).id(compId).width(44).height(44).padding(0).borderRadius(8).enabled(enabled())
      .backgroundColor(Color.Transparent).clickEffect(Motion.pressSmall).accessibilityText(label).onClick(action)
  }

  @Builder
  moreActions() {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      Image($r('app.media.message_more')).width(18).height(18).objectFit(ImageFit.Contain).fillColor($r('app.color.text_secondary'))
    }.fontFamily(this.appearance.fontFamily).id('message-more-' + this.message.id).width(44).height(44).padding(0).borderRadius(8)
      .backgroundColor(Color.Transparent).clickEffect(Motion.pressSmall)
      .accessibilityText(t('消息操作')).bindMenu(this.actions, {
        systemMaterial: this.appearance.surface, mask: false })
  }

  @Builder
  userMessage() {
    Column({ space: 6 }) {
      SendBubbleMotion({ origin: this.sendOrigin, bubbleId: 'sent-bubble-' + this.message.id,
        onReady: this.onSendReady, onFinish: this.onSendFinish }) {
      ForEach(this.message.references, (item: ThreadReference) => {
        ThreadReferenceCard({ reference: item })
      }, (item: ThreadReference) => item.threadId)
      if (this.images().length === 1) {
        Image('file://' + Attachments.path(this.images()[0])).width(200).constraintSize({ maxHeight: 260 })
          .objectFit(ImageFit.Contain).borderRadius(Radius.lg).backgroundColor($r('app.color.surface_variant'))
          .accessibilityText(this.images()[0].name).onClick(() => this.preview(this.images()[0]))
      } else if (this.images().length > 1) {
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.End }) {
          ForEach(this.images(), (item: Attachment) => {
            Image('file://' + Attachments.path(item)).width(108).height(108).objectFit(ImageFit.Contain)
              .borderRadius(Radius.md).margin(2).backgroundColor($r('app.color.surface_variant'))
              .accessibilityText(item.name).onClick(() => this.preview(item))
          }, (item: Attachment) => item.id)
        }.width(224)
      }
      ForEach(this.files(), (item: Attachment) => {
        Row({ space: Space.sm }) {
          SymbolGlyph($r('sys.symbol.doc_text')).fontSize(20).fontColor([this.appearance.accent])
          Column({ space: 1 }) {
            Text(item.name).fontFamily(this.appearance.fontFamily).fontSize(13).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontColor($r('app.color.text_primary'))
            Text(fileSize(item.size)).fontFamily(this.appearance.fontFamily).fontSize(11).fontColor($r('app.color.text_tertiary'))
          }.alignItems(HorizontalAlign.Start).flexShrink(1)
        }.padding({ left: 10, right: 12, top: 8, bottom: 8 }).borderRadius(Radius.md)
        .backgroundColor($r('app.color.surface')).border({ width: 0.5, color: $r('app.color.divider') })
        .constraintSize({ maxWidth: 240 })
        .onClick(() => { this.selectingText = false; this.documentName = item.name; this.documentText = item.text || ''; this.documentOpen = true; })
      }, (item: Attachment) => item.id)
      if (this.message.content.length > 0) {
        Text(this.message.content).fontFamily(this.appearance.fontFamily).fontSize(Font.body).lineHeight(24)
          .fontColor($r('app.color.text_primary')).copyOption(CopyOptions.None)
          .padding({ left: 14, right: 14, top: 10, bottom: 10 })
          .borderRadius({ topLeft: 20, topRight: 20, bottomLeft: 20, bottomRight: 6 })
          .backgroundColor(this.appearance.userBubble)
      }
      if (this.message.error.length > 0) {
        Text(this.message.error).fontFamily(this.appearance.fontFamily).fontSize(Font.caption).fontColor($r('app.color.danger'))
      }
      }
      Row({ space: 4 }) {
        this.actionButton($r('sys.symbol.square_and_pencil'), t('改写'), 'edit-' + this.message.id,
          () => this.onFork(this.message.id), () => this.actionsEnabled)
        this.moreActions()
      }.justifyContent(FlexAlign.End).opacity(this.sendOrigin ? 0 : 1)
        .animation({ duration: Motion.fast, curve: Motion.standard })
    }.width('100%').alignItems(HorizontalAlign.End).padding({ left: 48 })
  }

  @Builder
  steering(index: number) {
    Column({ space: 4 }) {
      Text(t("追加指令")).fontFamily(this.appearance.fontFamily).fontSize(11).fontColor($r('app.color.text_secondary'))
      Text(this.message.stepViews[index]?.steering?.text || '').fontFamily(this.appearance.fontFamily).fontSize(15).lineHeight(22)
        .copyOption(CopyOptions.LocalDevice).fontColor($r('app.color.text_primary'))
    }
    .alignItems(HorizontalAlign.Start).padding({ left: 14, right: 14, top: 8, bottom: 10 })
    .constraintSize({ maxWidth: '85%' }).borderRadius(Radius.md).backgroundColor(this.appearance.userBubble)
    .alignSelf(ItemAlign.End)
  }

  @Builder
  workflowRail(entry: TimelineEntry) {
    if (this.traceEntry(entry) && !this.folded()) {
      Column() {
        Column().width(1).height('100%').backgroundColor($r('app.color.divider'))
      }.width(16).height('100%').padding({ top: entry.kind === 'process' ? 34 : 24, bottom: 2 })
    }
  }

  @Builder
  assistantMessage() {
    Column({ space: 10 }) {
      ForEach(this.images(), (item: Attachment) => {
        Image('file://' + Attachments.path(item)).width('100%').constraintSize({ maxHeight: 320 }).objectFit(ImageFit.Contain)
          .borderRadius(Radius.md).onClick(() => this.preview(item))
      }, (item: Attachment) => item.id)
      Row({ space: Space.sm }) {
        Image($r('app.media.tinybot')).width(22).height(22)
        Text('Tinybot').fontFamily(this.appearance.fontFamily).fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        if (this.message.modelRef) {
          Text(this.message.modelRef.modelId).fontFamily(this.appearance.fontFamily).fontSize(11).maxLines(1).layoutWeight(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_tertiary'))
        } else {
          Blank()
        }
      }.width('100%')
      if (this.workflowVisible()) {
        Row({ space: 6 }) {
          ThinkingLine({ label: this.workflowLabel(), working: this.message.status === 'generating', compact: true,
            icon: this.message.status === 'failed' ? $r('sys.symbol.exclamationmark_circle') :
              this.message.status === 'stopped' ? $r('sys.symbol.stop_circle') :
              this.message.status === 'generating' ? $r('sys.symbol.lightbulb') : $r('sys.symbol.checkmark'),
            danger: this.message.status === 'failed' })
          Blank()
          if (this.failures() > 0) {
            Text(t('{0} 次失败', [this.failures()])).fontFamily(this.appearance.fontFamily).id('process-failures-' + this.message.id)
              .fontSize(12).fontColor($r('app.color.danger'))
          }
          if (this.message.status === 'generating') {
            Text(t("第 {0} 步", [Math.max(1, this.message.stepViews.length)])).fontFamily(this.appearance.fontFamily).fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
          }
          if (this.timeline().length > 0 && (this.message.status === 'generating' || this.foldable())) {
            Stack({ alignContent: Alignment.Center }) {
              SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(11).fontColor([$r('app.color.text_tertiary')])
            }.width(16).height(16).rotate({ angle: this.folded() ? 0 : 180 })
              .animation({ duration: 280, curve: Motion.standard })
          }
        }.id('process-' + this.message.id).height(44).width('100%')
        .accessibilityText((this.folded() ? t("查看执行过程，") : t("收起执行过程")) + this.workflowLabel())
        .onClick(() => {
          if (!this.timeline().length || (this.message.status !== 'generating' && !this.foldable())) { return; }
          this.onInspect();
          this.getUIContext().animateTo({ duration: 280, curve: Motion.standard }, () => {
            if (this.message.status === 'generating') {
              this.workflowCollapsed = !this.workflowCollapsed;
              this.message.processOpen = !this.workflowCollapsed;
            } else { this.message.processOpen = !this.message.processOpen; }
          });
        })
      }
      if (this.message.stepViews.length > 0) {
        ForEach(this.timeline(), (entry: TimelineEntry, index: number) => {
          if (this.entryVisible(entry, index, this.timeline().length)) {
            Row({ space: 10 }) {
              if (this.traceEntry(entry) && !this.folded()) {
                Column({ space: 5 }) {
                  if (this.traceState(entry) === 'active') {
                    LoadingProgress().width(14).height(14).color(this.appearance.accent)
                  } else {
                    SymbolGlyph(this.traceState(entry) === 'failed' ? $r('sys.symbol.exclamationmark_circle') :
                      this.traceState(entry) === 'stopped' ? $r('sys.symbol.stop_circle') : $r('sys.symbol.checkmark'))
                      .fontSize(12).fontColor([this.traceState(entry) === 'failed' ? $r('app.color.danger') : $r('app.color.text_tertiary')])
                  }
                }.width(16).padding({ top: entry.kind === 'process' ? 15 : 5 })
              }
              Column() {
              if (entry.kind === 'steering') {
                this.steering(entry.step)
              } else if (entry.kind === 'text') {
                InteractiveAnswer({ content: this.message.stepViews[entry.step].content, step: entry.step, selectable: false,
                  validation: this.message.stepViews[entry.step]?.uiValidation || '',
                  saved: this.message.uiStates, presentation: this.message.uiPresentation, available: this.uiAvailable, onInteract: this.onUi,
                  streaming: this.message.status === 'generating' && entry.step === this.message.stepViews.length - 1 })
                ForEach(stepPreviews(this.message.id, this.message.stepViews[entry.step], entry.step, this.latestPreviewIds),
                  (preview: PublishedPreview) => {
                    PublishedPreviewCard({ preview: stepPreviews(this.message.id, this.message.stepViews[entry.step], entry.step, this.latestPreviewIds).find((item) => item.id === preview.id) as PublishedPreview,
                      saved: this.message.uiStates, presentation: this.message.uiPresentation, available: this.uiAvailable, onInteract: this.onUi })
                  }, (preview: PublishedPreview) => preview.id)
              } else {
                ProcessGroup({ message: this.message, webEnabled: this.webEnabled, disclosure: this.message.disclosures.get(entry.key), groupKey: entry.key, richOnly: this.folded(),
                  onResume: this.onResume, onInspect: this.onInspect })
              }
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            }.width('100%').alignItems(VerticalAlign.Top)
            .background(this.workflowRail(entry), { align: Alignment.TopStart })
            .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: -4 }))
              .animation({ duration: 280, curve: Motion.standard }))
          }
        }, (entry: TimelineEntry) => entry.key)
        if (this.retryStatus()) {
          Text(this.retryStatus()).fontFamily(this.appearance.fontFamily).fontSize(13).fontColor($r('app.color.text_secondary')).id('request-retry-' + this.message.id)
        }
      } else if (this.message.content.length > 0) {
        InteractiveAnswer({ content: this.message.content, saved: this.message.uiStates, presentation: this.message.uiPresentation, available: this.uiAvailable, onInteract: this.onUi, streaming: this.message.status === 'generating', selectable: false })
      }
      if (this.hasExtra) {
        this.extra()
      }
      ForEach(deliveredFiles(this.message.stepViews), (file: PresentedFile) => {
        Button() {
          Row({ space: 12 }) {
            SymbolGlyph($r('sys.symbol.doc')).fontSize(24).fontColor([this.appearance.accent])
            Column({ space: 4 }) {
              Text(file.path).fontFamily(this.appearance.fontFamily).fontSize(14).fontColor($r('app.color.text_primary')).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
              if (file.description) { Text(file.description).fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_secondary')).maxLines(3) }
              Text(t('打开文件 · 分享与导出')).fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_tertiary'))
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(12).fontColor([$r('app.color.text_secondary')])
          }.width('100%').padding(14)
        }.fontFamily(this.appearance.fontFamily).width('100%').type(ButtonType.Normal).borderRadius(Radius.md).backgroundColor($r('app.color.surface_variant'))
        .id('deliverable-' + this.message.id + '-' + file.path).onClick(() => this.onOpenFile(file.path))
      }, (file: PresentedFile) => file.path)
      if (this.message.error.length > 0) {
        Text(this.message.error).fontFamily(this.appearance.fontFamily).fontSize(13).lineHeight(20).width('100%')
          .padding({ left: Space.md, right: Space.md, top: 8, bottom: 8 }).borderRadius(Radius.sm)
          .fontColor(this.message.status === 'failed' ? $r('app.color.danger') : $r('app.color.text_secondary'))
          .backgroundColor(this.message.status === 'failed' ? $r('app.color.danger_container') : $r('app.color.surface_variant'))
      }
      // Visible shortcuts for finished answers; the long-press menu offers the same actions.
      if (this.message.status !== 'generating' && turnFileChanges(this.message.steps).length > 0) {
        TurnChangesCard({ changes: turnFileChanges(this.message.steps) })
      }
      if (this.message.status !== 'generating') {
        Flex({ wrap: FlexWrap.Wrap }) {
          if (this.message.content.length > 0) {
            this.actionButton($r('sys.symbol.rectangle_on_rectangle'), t('复制'), 'copy-' + this.message.id, () => { this.copy(); })
          }
          this.actionButton($r('sys.symbol.arrow_clockwise'), t('重新生成'), 'regenerate-' + this.message.id,
            () => this.onRegenerate(this.message.id), () => this.actionsEnabled)
          this.actionButton($r('app.media.message_branch'), t('分支'), 'fork-' + this.message.id,
            () => { this.onFork(this.message.id); }, () => this.actionsEnabled, true)
          this.moreActions()
        }.width('100%').margin({ left: -6, top: -6 })
        .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 4 }))
          .animation({ duration: Motion.medium, curve: Motion.standard }))
      }
      MessageUsage({ message: this.message })
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      Column() {
        if (this.message.role === 'user') {
          this.userMessage()
        } else {
          this.assistantMessage()
        }
      }.width('100%').bindContextMenu(this.actions, ResponseType.LongPress, {
        systemMaterial: this.appearance.surface, mask: false })
      .bindSheet($$this.documentOpen, this.documentViewer(), { height: '90%', showClose: false, dragBar: true,
        backgroundColor: $r('app.color.page_background') })
    }.width('100%')
    // A closed sheet on the cover's node can dismiss the image preview on API 26.
    .bindContentCover($$this.previewing, this.viewer(), { modalTransition: ModalTransition.ALPHA })
  }
}
