import { t } from '../model/I18n';
import { supportsReasoningEffort, reasoningEfforts, reasoningEffortName, isHighestReasoningEffort } from '../model/ReasoningEffort';
import { ComposerGlow } from '../common/ComposerGlow';
import { ReasoningEffortPicker } from './ReasoningEffortPicker';
import { SpeechInput } from '../services/SpeechInput';
import { DictationDraft } from '../model/DictationDraft';
import { VoicePill } from '../common/VoicePill';
import { pasteboard } from '@kit.BasicServicesKit';
import { ThreadReference, referenceQuery } from '../model/ThreadReferences';
import { ThreadReferenceCard } from './ThreadReferenceCard';
import { curves } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { Attachment, PromptTemplate } from '../model/Productivity';
import { Attachments } from '../services/Attachments';
import { selectAttachments } from '../services/NativeActions';
import { ToolApproval } from '../services/ToolApproval';
import { InputFormCard } from './InputFormCard';
import { ChatTeamCard } from './ChatTeamCard';
import { MemoryDraftPanel } from './MemoryDraftPanel';
import { ChatViewModel, MessageViewModel, ThreadViewModel } from '../viewmodel/ChatViewModel';
import { UiValues } from '../model/InteractiveUi';
import { ImageViewer, MessageBubble } from './MessageBubble';
import { InputQueuePanel } from './InputQueuePanel';
import { Btn, Font, Motion, Radius, Space, fileSize } from '../common/Theme';
import { Banner, IconBadge, IconButton } from '../common/Widgets';

class Suggestion {
  icon: Resource;
  title: string;
  detail: string;
  prompt: string;

  constructor(icon: Resource, title: string, detail: string, prompt: string) {
    this.icon = icon;
    this.title = title;
    this.detail = detail;
    this.prompt = prompt;
  }
}

function SUGGESTIONS(): Suggestion[] { return [
  new Suggestion($r('sys.symbol.checkmark'), t("整理成行动"), t("把零散想法变成步骤"), t("帮我把下面的想法整理成可执行的步骤：")),
  new Suggestion($r('sys.symbol.ellipsis_message'), t("通俗解释"), t("用生活例子讲清概念"), t("请用一个贴近日常生活的例子，解释一个复杂概念：")),
  new Suggestion($r('sys.symbol.square_and_pencil'), t("润色文字"), t("更清晰、更得体"), t("请帮我润色下面这段文字，保持原意，让表达更清晰：")),
  new Suggestion($r('sys.symbol.magnifyingglass'), t("读网页"), t("总结链接中的要点"), t("请阅读这个网页并总结要点："))
]; }

@Component
export struct ChatPanel {
  @ObjectLink app: ChatViewModel;
  @ObjectLink thread: ThreadViewModel;
  @Prop @Watch('speechAvailabilityChanged') speechEnabled: boolean = true;
  @Prop @Watch('speechThreadChanged') activeThreadId: string = '';
  onSettings: () => void = () => {};
  onHistoryDragStart: (event: GestureEvent) => void = () => {};
  onHistoryDragUpdate: (event: GestureEvent) => void = () => {};
  onHistoryDragEnd: (event: GestureEvent) => void = () => {};
  onHistoryDragCancel: () => void = () => {};
  onFiles: () => void = () => {};
  onTools: (tab: string) => void = () => {};
  @ObjectLink approval: ToolApproval;
  @State private importing: boolean = false;
  @State private showPlus: boolean = false;
  @State private speech: SpeechInput = new SpeechInput();
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
  @State private showQueue: boolean = false;
  @State private showSummary: boolean = false;
  @State private showMemoryDraft: boolean = false;
  @State private memoryMessageId: string = '';
  @State private memoryThreadId: string = '';
  @State private composerFocused: boolean = false;
  @State private showReasoning: boolean = false;
  @State private reasoningPreview: string = '';
  @State private reasoningPreviewKey: string = '';
  private reasoningSaving: boolean = false;
  private scroller: Scroller = new Scroller();
  private scrollTimer: number = -1;
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
    if (!this.isLive(message.id)) { return TransitionEffect.IDENTITY; }
    return message.role === 'user' ? Motion.rise(0, 16) : Motion.rise(2, 10);
  }
  private locate(): void {
    const index = this.app.visibleMessages.findIndex((item) => item.id === this.app.searchMessageId);
    if (index >= 0) { this.followOutput = false; this.scroller.scrollToIndex(index + (this.thread.messages.length > this.app.visibleMessageCount ? 1 : 0), false, ScrollAlign.CENTER); }
  }

  aboutToAppear(): void {
    this.speech.onResult = (text: string): void => {
      if (!this.dictationDraft || this.speechThreadId !== this.app.active.id || !this.speechEnabled) {
        this.endSpeech(false); return;
      }
      try { this.app.setDraft(this.dictationDraft.update(this.app.draft, text)); }
      catch (error) {
        this.endSpeech(false); this.unwrittenSpeech = text; this.speech.error = (error as Error).message;
      }
    };
    this.speech.onComplete = (): void => { this.dictationDraft = undefined; this.app.flushDraft(); };
    this.speech.onError = (): void => { this.dictationDraft = undefined; this.app.flushDraft(); };
    this.speech.onBackground = (): void => { this.dictationDraft = undefined; this.app.flushDraft(); };
  }

  aboutToDisappear(): void {
    this.endSpeech(false);
    clearTimeout(this.scrollTimer);
  }

  private speechActive(): boolean {
    return this.speech.phase === 'preparing' || this.speech.phase === 'listening' || this.speech.phase === 'finishing';
  }
  private speechAvailabilityChanged(): void { if (!this.speechEnabled) { this.endSpeech(false); } }
  private speechThreadChanged(): void { if (this.speechThreadId !== this.activeThreadId) { this.endSpeech(false); } }
  private startSpeech(settings: boolean = false): void {
    if (this.speechActive() || !this.speechEnabled || !this.app.ready || this.thread.archived || this.app.saveError) { return; }
    this.getUIContext().getFocusController().clearFocus();
    this.speechThreadId = this.app.active.id;
    this.dictationDraft = new DictationDraft(this.app.draft);
    this.unwrittenSpeech = '';
    this.speech.start(this.getUIContext().getHostContext() as common.UIAbilityContext, settings);
  }
  private finishSpeech(): void {
    if (this.speech.phase === 'preparing') { this.endSpeech(false); }
    else { this.speech.finish(); }
  }
  private endSpeech(rollback: boolean): void {
    const hadDraft = this.dictationDraft !== undefined;
    if (rollback && this.dictationDraft && this.speechThreadId === this.app.active.id) {
      this.app.setDraft(this.dictationDraft.cancel(this.app.draft));
    }
    this.dictationDraft = undefined;
    this.speech.cancel();
    if (hadDraft) { this.app.flushDraft(); }
  }
  private async speechErrorAction(): Promise<void> {
    if (this.unwrittenSpeech) {
      try {
        await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.unwrittenSpeech));
        this.getUIContext().getPromptAction().showToast({ message: t('已复制') });
        this.unwrittenSpeech = ''; this.speech.error = '';
      } catch (error) { this.speech.error = t('复制失败：') + (error as Error).message; }
    } else if (this.speech.permissionDenied) { this.startSpeech(true); }
    else { this.speech.error = ''; }
  }

  private follow(): void {
    if (!this.followOutput || this.scrollTimer !== -1) {
      return;
    }
    this.scrollTimer = setTimeout(() => {
      this.scrollTimer = -1;
      if (this.followOutput && this.thread.messages.length > 0) {
        this.scroller.scrollEdge(Edge.Bottom);
      }
    }, 80);
  }

  private uiHandler(threadId: string, messageId: string): (key: string, values: UiValues, action: string) => Promise<UiValues> {
    return (key: string, values: UiValues, action: string) => this.app.interactUi(threadId, messageId, key, values, action);
  }
  private send(): void {
    if (this.speechActive()) { return; }
    this.inspectingOutput = false; this.followOutput = true;
    this.app.send(() => this.follow());
  }

  // Use methods: ordinary accessors in a V1 @Component are omitted by the ArkUI compiler.
  private hasDraft(): boolean {
    return this.app.draft.trim().length > 0 || this.thread.attachments.length > 0 || this.thread.references.length > 0;
  }

  private canSend(): boolean {
    return !this.speechActive() && this.app.ready && !this.app.busy && !this.importing && !this.thread.archived && this.hasDraft() && this.app.saveError.length === 0;
  }

  private async attach(photo: boolean): Promise<void> {
    if (this.importing || this.app.busy) { return; }
    this.importing = true; const id = this.thread.id;
    try {
      const items = await selectAttachments(this.getUIContext().getHostContext() as common.UIAbilityContext, photo, 4 - this.thread.attachments.length);
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
  @Builder
  memoryDraftSheet() {
    MemoryDraftPanel({ app: this.app, threadId: this.memoryThreadId, messageId: this.memoryMessageId, onClose: () => { this.showMemoryDraft = false; } })
  }
  private async fork(id: string): Promise<void> {
    if (await this.app.forkThread(id)) {
      this.getUIContext().getPromptAction().showToast({ message: t("已切换到新分支，原对话保留在列表中") });
    }
  }
  private canAttach(): boolean {
    return !this.speechActive() && !this.app.busy && !this.importing && !this.thread.archived && this.app.saveError.length === 0;
  }
  // Close the sheet first so the system picker does not open on top of a dismissing sheet.
  private fromSheet(action: () => void): void {
    this.showPlus = false;
    setTimeout(action, 250);
  }
  private removeAttachment(id: string): void {
    this.app.setAttachments(this.thread.attachments.filter((file: Attachment) => file.id !== id));
  }

  private contextRatio(): number {
    return this.app.contextWindow > 0 ? Math.min(1, this.app.contextUsed / this.app.contextWindow) : 0;
  }

  private contextColor(): ResourceColor {
    return this.contextRatio() >= 0.85 ? $r('app.color.danger') : $r('app.color.accent');
  }

  private confirmCompact(): void {
    this.getUIContext().showAlertDialog({
      title: t("压缩较早对话？"),
      message: t("将调用当前模型生成摘要，消耗 Token。完整记录保留，之后请求使用摘要和最近消息。"),
      primaryButton: { value: t("取消"), action: () => {} },
      secondaryButton: { value: t("压缩"), action: () => { this.showContext = false; this.app.compactHistory(); } }
    });
  }

  @Builder
  suggestionCard(item: Suggestion, index: number) {
    Column({ space: 6 }) {
      SymbolGlyph(item.icon).fontSize(20).fontColor([$r('app.color.accent')])
      Text(item.title).fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
      Text(item.detail).fontSize(Font.caption).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontColor($r('app.color.text_secondary'))
    }
    .layoutWeight(1).alignItems(HorizontalAlign.Start).padding(14).borderRadius(Radius.lg)
    .backgroundColor($r('app.color.surface'))
    .clickEffect(Motion.press)
    .transition(Motion.rise(4 + index))
    .onClick(() => { this.app.setDraft(item.prompt); })
  }

  @Builder
  welcome() {
    Scroll() {
      Column({ space: Space.md }) {
        Blank().layoutWeight(1)
        Image($r('app.media.tinybot')).width(56).height(56)
          .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.6, y: 0.6 }))
            .animation({ curve: curves.springMotion(0.5, 0.7) }))
        Text(t("今天想一起做点什么？")).fontSize(Font.headline).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary')).textAlign(TextAlign.Center)
          .margin({ bottom: Space.md }).transition(Motion.rise(1))
        if (!this.app.configured) {
          Column({ space: 10 }) {
            Text(t("先连接一个模型服务")).fontSize(15).fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.on_accent_container'))
            Text(t("支持 OpenAI、Anthropic 等协议，密钥保存在系统安全存储中。")).fontSize(13).lineHeight(19)
              .textAlign(TextAlign.Center).fontColor($r('app.color.on_accent_container'))
            Button(t("连接你的模型")).id('setup-model').attributeModifier(Btn.primary).width('100%')
              .onClick(() => this.onSettings())
          }.width('100%').padding(Space.lg).borderRadius(Radius.lg).backgroundColor($r('app.color.accent_container'))
          .transition(Motion.rise(3))
        }
        Row({ space: 10 }) {
          this.suggestionCard(SUGGESTIONS()[0], 0)
          this.suggestionCard(SUGGESTIONS()[1], 1)
        }.width('100%')
        Row({ space: 10 }) {
          this.suggestionCard(SUGGESTIONS()[2], 2)
          this.suggestionCard(SUGGESTIONS()[3], 3)
        }.width('100%')
        if (!this.thread.teamEnabled) {
          Row({ space: Space.md }) {
            IconBadge({ icon: $r('sys.symbol.person_2'), diameter: 40 })
            Column({ space: 2 }) {
              Text(t("交给 Agent 团队")).fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
              Text(t("复杂任务由主 Agent 招募员工并行完成")).fontSize(Font.caption).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_secondary'))
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([$r('app.color.text_tertiary')])
          }
          .id('welcome-team').width('100%').padding(14).borderRadius(Radius.lg).backgroundColor($r('app.color.surface'))
          .clickEffect(Motion.press).transition(Motion.rise(8))
          .enabled(!this.thread.archived && this.app.saveError.length === 0)
          .onClick(() => this.toggleTeam(true))
        }
      }.width('100%').constraintSize({ minHeight: '100%' }).padding({ left: 20, right: 20, top: Space.lg, bottom: Space.md })
    }.layoutWeight(1).width('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  messageList() {
    Stack({ alignContent: Alignment.Bottom }) {
      List({ space: 22, scroller: this.scroller }) {
        if (this.app.visibleMessageCount < this.thread.messages.length) {
          ListItem() {
            Button(t("加载更早的消息")).id('load-earlier-messages').attributeModifier(Btn.textSmall)
              .onClick(() => { this.app.visibleMessageCount += 60; })
          }.width('100%')
        }
        ForEach(this.app.visibleMessages, (message: MessageViewModel) => {
          ListItem() {
            MessageBubble({ message: message, uiAvailable: !this.app.busy && !this.thread.archived,
              onUi: this.uiHandler(this.thread.id, message.id), onFork: (id: string) => { this.fork(id); }, onRemember: (id: string) => { this.remember(id); },
              onInspect: () => { this.inspectingOutput = true; this.followOutput = false; clearTimeout(this.scrollTimer); this.scrollTimer = -1; },
              onReference: (text: string) => this.app.setDraft(this.app.draft + text), onResume: (id: string) => this.app.resumeForm(message.id, id),
              hasExtra: message.role === 'assistant' && this.app.teams.some((run) => run.ownerMessageId === message.id) }) {
              ChatTeamCard({ app: this.app, messageId: message.id, onFiles: this.onFiles })
            }
          }
            .backgroundColor(this.app.searchMessageId === message.id ? $r('app.color.accent_container') : Color.Transparent)
            .animation({ duration: Motion.medium, curve: Motion.standard })
            .transition(this.messageEnter(message))
        }, (message: MessageViewModel) => this.thread.id + ":" + message.id)
        if (this.app.teams.some((run) => !run.ownerMessageId)) {
          ListItem() { ChatTeamCard({ app: this.app, onFiles: this.onFiles }) }.width('100%')
        }
      }
      .id('message-list').width('100%').height('100%')
      .padding({ left: Space.page, right: Space.page, top: Space.sm, bottom: Space.lg })
      .scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
      .onTouch((event: TouchEvent) => { if (event.type === TouchType.Down) { this.followOutput = false; } })
      .onReachEnd(() => { if (!this.inspectingOutput) { this.followOutput = true; } })
      .onDidScroll(() => { this.atBottom = this.scroller.isAtEnd(); })
      if (!this.atBottom) {
        Column() {
          IconButton({ icon: $r('sys.symbol.arrow_down'), label: t("查看最新消息"), compId: 'scroll-to-latest',
            diameter: 38, iconSize: 18, fill: $r('app.color.surface'), tint: $r('app.color.text_primary'),
            onTap: () => { this.inspectingOutput = false; this.followOutput = true; this.scroller.scrollEdge(Edge.Bottom); } })
        }.width(38).height(38).borderRadius(19).backgroundColor($r('app.color.surface'))
        .border({ width: 0.5, color: $r('app.color.divider') })
        .shadow({ radius: 12, color: '#22000000', offsetY: 2 }).margin({ bottom: Space.md })
        .transition(Motion.pop())
      }
    }.layoutWeight(1).width('100%')
  }

  @Builder
  contextSheet() {
    Scroll() {
      Column({ space: Space.lg }) {
        Column({ space: 10 }) {
          Row() {
            Text(`${Math.round(this.contextRatio() * 100)}%`).fontSize(28).fontWeight(FontWeight.Bold)
              .fontColor(this.contextColor())
            Blank()
            Text(t("约 {0} / {1} tokens", [this.app.contextUsed, this.app.contextWindow])).id('context-label')
              .fontSize(13).fontColor($r('app.color.text_secondary'))
          }.width('100%').alignItems(VerticalAlign.Bottom)
          Progress({ value: this.app.contextUsed, total: Math.max(1, this.app.contextWindow), type: ProgressType.Linear })
            .width('100%').color(this.contextColor()).backgroundColor($r('app.color.surface_variant'))
            .style({ strokeWidth: 8, strokeRadius: 4 })
          if (this.app.contextStatus.length > 0) {
            Text(this.app.contextStatus).id('context-status').fontSize(13).lineHeight(19).width('100%')
              .fontColor($r('app.color.text_secondary'))
          }
        }.padding(Space.lg).borderRadius(Radius.lg).backgroundColor($r('app.color.surface'))
        if (this.thread.compaction) {
          Column({ space: 10 }) {
            Row({ space: Space.sm }) {
              Text(t("较早对话使用摘要")).fontSize(15).fontWeight(FontWeight.Medium).layoutWeight(1)
                .fontColor($r('app.color.text_primary'))
              Button(this.showSummary ? t("收起") : t("查看摘要")).attributeModifier(Btn.textSmall)
                .onClick(() => { this.showSummary = !this.showSummary; })
            }.width('100%')
            Text(t("完整记录仍保留在本机，只有发送给模型时使用摘要。")).fontSize(Font.caption)
              .fontColor($r('app.color.text_secondary')).width('100%')
            if (this.showSummary) {
              Scroll() {
                Text(this.thread.compaction.summary).fontSize(13).lineHeight(20).width('100%')
                  .copyOption(CopyOptions.LocalDevice).fontColor($r('app.color.text_primary'))
              }.constraintSize({ maxHeight: 240 }).width('100%').align(Alignment.TopStart)
              .padding(Space.md).borderRadius(Radius.sm).backgroundColor($r('app.color.surface_variant'))
            }
          }.padding(Space.lg).borderRadius(Radius.lg).backgroundColor($r('app.color.surface'))
        }
        Column({ space: Space.sm }) {
          Button(t("压缩较早对话")).id('compact-history').attributeModifier(Btn.tonal).width('100%')
            .enabled(this.app.configured && !this.app.busy && !this.thread.archived && this.app.saveError.length === 0)
            .onClick(() => this.confirmCompact())
          Text(t("使用当前模型为较早消息生成摘要，会消耗 Token。")).fontSize(Font.caption)
            .fontColor($r('app.color.text_tertiary'))
        }.width('100%')
      }.width('100%').padding({ left: Space.page, right: Space.page, bottom: Space.xl })
    }.width('100%').scrollBar(BarState.Off)
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
      MenuItem({ content: t("加入队列") }).enabled(this.app.canQueueInput && this.hasDraft())
        .onClick(() => this.app.enqueueInput('followUp'))
    }
  }

  @Builder
  plusTile(icon: Resource, label: string, compId: string, enabled: boolean, action: () => void) {
    Column({ space: 8 }) {
      Column() {
        SymbolGlyph(icon).fontSize(24).fontColor([$r('app.color.accent')])
      }.width(56).height(56).borderRadius(Radius.lg).justifyContent(FlexAlign.Center)
      .backgroundColor($r('app.color.surface'))
      Text(label).fontSize(Font.caption).fontColor($r('app.color.text_secondary'))
    }
    .id(compId).layoutWeight(1).opacity(enabled ? 1 : 0.4).enabled(enabled)
    .clickEffect(enabled ? Motion.press : null)
    .onClick(action)
  }

  @Builder
  plusSheet() {
    Scroll() {
      Column({ space: Space.lg }) {
        Row() {
          this.plusTile($r('sys.symbol.picture'), t("图片"), 'attach-photo',
            this.canAttach() && this.thread.attachments.length < 4, () => this.fromSheet(() => this.attach(true)))
          this.plusTile($r('sys.symbol.doc_text'), t("文本文件"), 'attach-text',
            this.canAttach() && this.thread.attachments.length < 4, () => this.fromSheet(() => this.attach(false)))
          this.plusTile($r('sys.symbol.folder'), t("工作区"), 'open-workspace', !this.app.busy,
            () => { this.showPlus = false; this.onFiles(); })
          this.plusTile($r('sys.symbol.lightbulb'), t("记忆"), 'open-memory', !this.app.busy,
            () => { this.showPlus = false; this.onTools('memory'); })
          this.plusTile($r('sys.symbol.person_2'), this.thread.teamEnabled ? t("关闭团队") : t("Agent 团队"), 'toggle-team',
            !this.app.busy && !this.thread.archived && this.app.saveError.length === 0,
            () => { this.showPlus = false; this.toggleTeam(!this.thread.teamEnabled); })
        }.width('100%').alignItems(VerticalAlign.Top)
        Text(this.thread.attachments.length >= 4 ? t("已达到每条消息 4 个附件的上限") : t("图片需模型支持视觉输入 · 文本文件最多 64 KB"))
          .fontSize(Font.caption).fontColor($r('app.color.text_tertiary')).width('100%').textAlign(TextAlign.Center)
        Button(t('引用其他会话')).id('add-thread-reference').attributeModifier(Btn.tonal).width('100%')
          .enabled(this.canAttach() && this.thread.references.length < 4)
          .onClick(() => this.fromSheet(() => {
            if (referenceQuery(this.app.draft) === undefined) { this.app.setDraft(this.app.draft + (this.app.draft ? ' @' : '@')); }
            this.getUIContext().getFocusController().requestFocus('composer');
          }))
        Column() {
          Row() {
            Text(t("提示词模板")).fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_secondary'))
              .layoutWeight(1)
            Button(t("管理")).id('manage-templates').attributeModifier(Btn.textSmall).enabled(!this.app.busy)
              .onClick(() => { this.showPlus = false; this.onTools('templates'); })
          }.width('100%').padding({ left: 4 })
          if (this.app.productivity.templates.length === 0) {
            Text(t("还没有模板")).fontSize(13).fontColor($r('app.color.text_tertiary'))
              .padding(Space.lg).width('100%').textAlign(TextAlign.Center)
          }
          Column() {
            ForEach(this.app.productivity.templates, (item: PromptTemplate, index: number) => {
              if (index > 0) { Divider().strokeWidth(0.5).color($r('app.color.divider')).margin({ left: 52 }) }
              Row({ space: Space.md }) {
                SymbolGlyph($r('sys.symbol.doc_plaintext')).fontSize(20).fontColor([$r('app.color.accent')])
                Column({ space: 2 }) {
                  Text(item.name).fontSize(15).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    .fontColor($r('app.color.text_primary'))
                  Text(item.content.replace(/\s+/g, ' ')).fontSize(Font.caption).maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_tertiary'))
                }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              }
              .id('use-template-' + item.id).width('100%').constraintSize({ minHeight: 56 })
              .padding({ left: Space.lg, right: Space.lg, top: 8, bottom: 8 })
              .stateStyles({ pressed: { .backgroundColor($r('app.color.surface_variant')) }, normal: { .backgroundColor(Color.Transparent) } })
              .enabled(!this.thread.archived)
              .onClick(() => {
                this.showPlus = false; this.app.useTemplate(item.id);
                this.getUIContext().getPromptAction().showToast({ message: t("已套用模板，可继续编辑后发送") });
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
              Image('file://' + Attachments.path(item)).width(64).height(64).objectFit(ImageFit.Cover)
                .borderRadius(Radius.md).backgroundColor($r('app.color.surface_variant'))
                .accessibilityText(item.name)
                .onClick(() => { this.previewPath = Attachments.path(item); this.previewing = true; })
            } else {
              Column({ space: 2 }) {
                SymbolGlyph($r('sys.symbol.doc_text')).fontSize(18).fontColor([$r('app.color.accent')])
                Text(item.name).fontSize(11).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .fontColor($r('app.color.text_primary'))
                Text(fileSize(item.size)).fontSize(10).fontColor($r('app.color.text_tertiary'))
              }.width(112).height(64).padding({ left: 10, right: 14, top: 8, bottom: 8 })
              .alignItems(HorizontalAlign.Start).borderRadius(Radius.md)
              .backgroundColor($r('app.color.surface_variant'))
            }
            Button({ type: ButtonType.Circle }) {
              SymbolGlyph($r('sys.symbol.xmark')).fontSize(10).fontColor([Color.White])
            }.id('remove-attachment-' + item.id).width(20).height(20).backgroundColor('#99000000')
            .margin({ top: 4, right: 4 }).accessibilityText(t("移除 ") + item.name)
            .hitTestBehavior(HitTestMode.Block).responseRegion({ x: -10, y: -10, width: 40, height: 40 })
            .onClick(() => this.removeAttachment(item.id))
          }
          .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.85, y: 0.85 }))
            .animation({ duration: Motion.medium, curve: Motion.standard }))
        }, (item: Attachment) => item.id)
        if (this.importing) {
          Column() { LoadingProgress().width(24).height(24).color($r('app.color.accent')) }
            .width(64).height(64).justifyContent(FlexAlign.Center).borderRadius(Radius.md)
            .backgroundColor($r('app.color.surface_variant'))
        }
      }.padding({ left: 4, right: 4, top: 4 })
    }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%').align(Alignment.Start)
    .enabled(!this.app.busy)
  }

  @Builder
  imageViewer() {
    ImageViewer({ path: this.previewPath, onClose: () => { this.previewing = false; } })
  }

  private async toggleTeam(enabled: boolean): Promise<void> {
    if (await this.app.setTeamEnabled(enabled)) {
      this.getUIContext().getPromptAction().showToast({ message: enabled ? t("已开启团队模式，描述目标即可开始") : t("已关闭团队模式") });
    }
  }

  private teamSuggested(): boolean {
    return this.commandSuggested('/team') && !this.thread.teamEnabled;
  }
  private commandSuggested(command: string): boolean {
    const draft = this.app.draft.trim().toLowerCase();
    return !this.speechActive() && !this.app.busy && !this.thread.archived && this.app.saveError.length === 0 && draft.startsWith('/') && command.startsWith(draft);
  }
  private referenceSuggested(): boolean {
    return this.canAttach() && this.thread.references.length < 4 && referenceQuery(this.app.draft) !== undefined;
  }
  private referenceMatches(): ThreadViewModel[] {
    const query = (referenceQuery(this.app.draft) || '').trim().toLowerCase();
    return this.app.threads.filter((item) => item.id !== this.thread.id && item.messages.some((message) => message.role === 'assistant' && message.status === 'complete') &&
      !this.thread.references.some((ref) => ref.threadId === item.id) && item.title.toLowerCase().includes(query))
      .sort((a, b) => b.updatedAt - a.updatedAt).slice(0, 6);
  }

  @Builder
  referenceSuggestions() {
    Column({ space: 2 }) {
      Text(t('引用会话 · 输入 @ 后搜索标题')).fontSize(12).fontColor($r('app.color.text_secondary')).padding(8)
      if (this.referenceMatches().length === 0) {
        Text(t('没有可引用的匹配会话')).fontSize(13).fontColor($r('app.color.text_tertiary')).padding(12)
      }
      Scroll() {
        Column() {
          ForEach(this.referenceMatches(), (item: ThreadViewModel) => {
            Row({ space: 8 }) {
              SymbolGlyph($r('sys.symbol.ellipsis_message')).fontSize(16).fontColor([$r('app.color.accent')])
              Text(item.displayTitle).fontSize(14).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                .fontColor($r('app.color.text_primary')).layoutWeight(1)
              if (item.archived) { Text(t('已归档')).fontSize(11).fontColor($r('app.color.text_tertiary')) }
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
        Text(t('压缩较早对话，保留完整记录')).fontSize(12).fontColor($r('app.color.text_secondary'))
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    }.id('slash-compact').width('100%').padding(12).borderRadius(Radius.lg).backgroundColor($r('app.color.surface'))
    .border({ width: 0.5, color: $r('app.color.divider') })
    .onClick(() => { this.app.setDraft('/compact'); this.send(); })
  }

  @Builder
  teamChip() {
    Row({ space: 6 }) {
      SymbolGlyph($r('sys.symbol.person_2')).fontSize(14).fontColor([$r('app.color.on_accent_container')])
      Text(t("团队模式")).fontSize(12).fontWeight(FontWeight.Medium).fontColor($r('app.color.on_accent_container'))
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(11).fontColor([$r('app.color.on_accent_container')])
      }.id('disable-team').width(22).height(22).backgroundColor(Color.Transparent).accessibilityText(t("关闭团队模式"))
      .responseRegion({ x: -10, y: -8, width: 42, height: 38 })
      .enabled(!this.app.busy).opacity(this.app.busy ? 0.4 : 1).onClick(() => this.toggleTeam(false))
    }.height(28).padding({ left: 10, right: 3 }).borderRadius(14).backgroundColor($r('app.color.accent_container'))
    .alignSelf(ItemAlign.Start).margin({ left: 2, top: 4 })
    .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.9, y: 0.9 }))
      .animation({ duration: Motion.medium, curve: Motion.standard }))
  }

  // Slash-command suggestion shown while the draft is a prefix of /team.
  @Builder
  commandSuggestion() {
    Row({ space: Space.md }) {
      IconBadge({ icon: $r('sys.symbol.person_2'), diameter: 36 })
      Column({ space: 2 }) {
        Row({ space: 6 }) {
          Text('/team').fontSize(14).fontWeight(FontWeight.Medium).fontFamily('monospace').fontColor($r('app.color.text_primary'))
          Text(t("Agent 团队")).fontSize(13).fontColor($r('app.color.text_secondary'))
        }
        Text(t("主 Agent 自主招募员工、并行分工并汇总结果")).fontSize(Font.caption).maxLines(1)
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
          if (!saved && this.app.error) this.getUIContext().getPromptAction().showToast({ message: this.app.error });
          return saved;
        } finally {
          // SessionService publishes the committed snapshot before resolving.
          this.reasoningSaving = false;
          this.reasoningPreview = '';
        }
      } })
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
  composer() {
    Stack({ alignContent: Alignment.Bottom }) {
      if (this.highestEffort()) {
        ComposerGlow({ active: true })
      }
    Column({ space: 4 }) {
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
      if (this.thread.teamEnabled) {
        this.teamChip()
      }
      if (this.thread.attachments.length > 0 || this.importing) {
        this.attachmentStrip()
      }
      TextArea({ text: this.app.draft,
        placeholder: this.speechActive() ? t('请说出要输入的内容') : this.thread.archived ? t("已归档的对话无法继续") : this.app.generating ? t("补充要求，或排队下一项任务…")
          : this.thread.teamEnabled ? t("描述目标，主 Agent 会按需组建团队…") : t('输入消息，/ 命令，@ 引用会话') })
        .id('composer').fontSize(Font.body).fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_tertiary')).backgroundColor(Color.Transparent)
        .constraintSize({ minHeight: 44, maxHeight: 160 }).maxLength(24000)
        .padding({ left: 6, right: 6, top: 10, bottom: 4 }).borderRadius(0)
        .enabled(!this.thread.archived).focusable(!this.speechActive()).enableKeyboardOnFocus(!this.speechActive())
        .onWillChange((value: EditableTextChangeValue) => !this.speechActive() || value.content === this.app.draft)
        .onChange((value: string) => {
          if (!this.speechActive()) { this.app.setDraft(value); }
        })
        .onFocus(() => { this.composerFocused = true; }).onBlur(() => { this.composerFocused = false; })
      Row({ space: 4 }) {
        if (this.speechActive()) {
          Button(t('取消')).id('cancel-speech').attributeModifier(Btn.textSmall)
            .onClick(() => this.endSpeech(true))
          Blank()
        } else {
        Scroll() {
        Row({ space: 4 }) {
        IconButton({ icon: $r('sys.symbol.plus'), label: t("添加图片、文件或模板"), compId: 'add-attachment', diameter: 36,
          iconSize: 20, fill: $r('app.color.surface_variant'), disabled: this.thread.archived || this.app.saveError.length > 0,
          onTap: () => { this.getUIContext().getFocusController().clearFocus(); this.showPlus = true; } })
          .bindSheet($$this.showPlus, this.plusSheet(), {
            detents: [SheetSize.MEDIUM, SheetSize.LARGE], dragBar: true, showClose: false,
            backgroundColor: $r('app.color.page_background')
          })
        // A bare ring reads as a spinner at low usage; the percentage makes it a gauge.
        Row({ space: 4 }) {
          Progress({ value: this.app.contextUsed, total: Math.max(1, this.app.contextWindow), type: ProgressType.Ring })
            .width(16).height(16).color(this.contextColor()).backgroundColor($r('app.color.divider'))
            .style({ strokeWidth: 2.5 })
          Text(Math.round(this.contextRatio() * 100) + '%').fontSize(11)
            .fontColor(this.contextRatio() >= 0.85 ? $r('app.color.danger') : $r('app.color.text_tertiary'))
        }.id('context-usage').height(36).padding({ left: 8, right: 8 }).borderRadius(18)
        .stateStyles({ pressed: { .backgroundColor($r('app.color.surface_variant')) }, normal: { .backgroundColor(Color.Transparent) } })
        .accessibilityText(this.app.contextLabel)
        .onClick(() => { this.showContext = true; })
        .bindSheet($$this.showContext, this.contextSheet(), {
          title: { title: t("上下文") }, detents: [SheetSize.MEDIUM, SheetSize.LARGE], dragBar: true,
          backgroundColor: $r('app.color.page_background'), onDisappear: () => { this.showSummary = false; }
        })
        if (!this.app.generating && this.app.configured && supportsReasoningEffort(
          this.app.providerProfiles.find((item) => item.id === this.thread.modelRef?.providerId)?.protocol || '', this.thread.modelRef?.modelId || '')) {
          Button({ type: ButtonType.Capsule }) {
            Text(reasoningEffortName(this.displayedEffort())).fontSize(12)
              .fontWeight(this.highestEffort() ? FontWeight.Medium : FontWeight.Regular)
              .fontColor(this.highestEffort() ? $r('app.color.on_accent_container') : $r('app.color.text_secondary'))
          }.id('open-reasoning-effort').height(32).padding({ left: 8, right: 8 })
          .backgroundColor(this.highestEffort() ? $r('app.color.user_bubble') : Color.Transparent)
          .enabled(!this.app.busy && !this.thread.archived && this.app.saveError.length === 0)
          .accessibilityText(t('推理强度') + '：' + reasoningEffortName(this.displayedEffort()))
          .onClick(() => { this.getUIContext().getFocusController().clearFocus(); this.showReasoning = !this.showReasoning; })
          .bindPopup(this.showReasoning, { builder: this.reasoningPicker, placement: Placement.Top,
            popupColor: $r('app.color.surface'), radius: 20, enableArrow: false, autoCancel: true,
            onStateChange: (event) => {
              this.showReasoning = event.isVisible;
              if (!event.isVisible && !this.reasoningSaving) this.reasoningPreview = '';
            } })
        }
        if (this.thread.pendingInputs.length > 0) {
          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.clock')).fontSize(14).fontColor([$r('app.color.on_accent_container')])
            Text(`${this.thread.queuePaused ? t("已暂停") : t("待发送")} ${this.thread.pendingInputs.length}`)
              .fontSize(Font.caption).fontWeight(FontWeight.Medium).fontColor($r('app.color.on_accent_container'))
          }
          .id('toggle-input-queue').height(30).padding({ left: 10, right: 12 }).borderRadius(15)
          .backgroundColor($r('app.color.accent_container'))
          .onClick(() => { this.showQueue = true; })
          .bindSheet($$this.showQueue, this.queueSheet(), {
            title: { title: t("待发送队列") }, detents: [SheetSize.MEDIUM, SheetSize.LARGE], dragBar: true,
            backgroundColor: $r('app.color.page_background')
          })
        }
        }
        }.layoutWeight(1).align(Alignment.Start).scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
        }
        VoicePill({ phase: this.speech.phase, speaking: this.speech.speaking, startedAt: this.speech.startedAt,
          disabled: !this.app.ready || !this.speechEnabled || this.thread.archived || this.app.saveError.length > 0,
          onStart: () => this.startSpeech(), onFinish: () => this.finishSpeech(), onCancel: () => this.endSpeech(true) })
        if (this.app.generating) {
          if (!this.speechActive() && this.hasDraft() && this.app.canQueueInput) {
            Button(t("追加")).id('steer-message').attributeModifier(Btn.tonalSmall)
              .enabled(this.app.acceptingSteering).onClick(() => this.app.enqueueInput('steer'))
            Button(t("排队")).id('queue-message').attributeModifier(Btn.plainSmall)
              .onClick(() => this.app.enqueueInput('followUp'))
          }
          IconButton({ icon: $r('sys.symbol.square_fill'), label: t("停止"), compId: 'stop-generation', diameter: 36,
            iconSize: 14, fill: $r('app.color.text_primary'), tint: $r('app.color.page_background'),
            onTap: () => { this.app.stop(); } })
            .transition(Motion.pop())
        } else {
          if (!this.speechActive() && this.thread.pendingInputs.length > 0 && this.hasDraft()) {
            Button(t("排队")).id('queue-message').attributeModifier(Btn.plainSmall)
              .enabled(this.app.canQueueInput).onClick(() => this.app.enqueueInput('followUp'))
          }
          IconButton({ icon: $r('sys.symbol.arrow_up'), label: t("发送"), compId: 'send-message', diameter: 36, iconSize: 18,
            fill: this.canSend() ? $r('app.color.accent') : $r('app.color.surface_variant'),
            tint: this.canSend() ? $r('app.color.on_accent') : $r('app.color.text_tertiary'),
            disabled: !this.canSend(), onTap: () => this.send() })
            .bindContextMenu(this.sendMenu, ResponseType.LongPress)
            .transition(Motion.pop())
        }
      }.width('100%')
    }
    .padding({ left: 8, right: 8, top: 4, bottom: 8 })
    }.width('100%').borderRadius(Radius.xl).clip(true)
    .backgroundColor($r('app.color.surface'))
    .border({ width: this.composerFocused ? 1 : 0.5,
      color: this.composerFocused ? $r('app.color.accent_outline') : $r('app.color.divider') })
    .shadow(this.composerFocused ? { radius: 28, color: $r('app.color.accent_glow'), offsetY: 4 }
      : { radius: 12, color: '#0A000000', offsetY: 2 })
    .animation({ duration: Motion.medium, curve: Motion.standard })
    .bindContentCover($$this.previewing, this.imageViewer(), { modalTransition: ModalTransition.ALPHA })
  }

  // Remote MCP calls pause the agent until the user decides; keep the card compact but impossible to miss.
  @Builder
  approvalCard() {
    Column({ space: 10 }) {
      Row({ space: Space.sm }) {
        SymbolGlyph($r('sys.symbol.connection')).fontSize(20).fontColor([$r('app.color.accent')])
        Column({ space: 2 }) {
          Text(t("允许调用远程工具？")).fontSize(Font.caption).fontColor($r('app.color.text_secondary'))
          Text(this.approval.title).id('approval-title').fontSize(15).fontWeight(FontWeight.Medium).maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_primary'))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Button(this.showApprovalDetails ? t("收起") : t("详情")).attributeModifier(Btn.textSmall)
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
        Button(t("拒绝")).id('deny-tool').attributeModifier(Btn.plainSmall).height(40).layoutWeight(1)
          .onClick(() => { this.showApprovalDetails = false; this.approval.respond(false); })
        Button(t("允许本次")).id('approve-tool').attributeModifier(Btn.primarySmall).height(40).layoutWeight(1)
          .onClick(() => { this.showApprovalDetails = false; this.approval.respond(true); })
      }.width('100%')
    }.width('100%').padding(Space.md).backgroundColor($r('app.color.surface')).borderRadius(Radius.lg)
    .border({ width: 1, color: $r('app.color.accent_container') })
    .shadow({ radius: 16, color: '#1A000000', offsetY: 2 })
    .transition(Motion.rise(0, 24))
  }

  build() {
    Column() {
      Column() {
        if (this.thread.messages.length === 0 && this.app.teams.length === 0) {
          this.welcome()
        } else {
          this.messageList()
        }
      }.id('chat-swipe-area').layoutWeight(1).width('100%')
      // Normal priority lets nested horizontal scrollers keep their gestures. The composer
      // stays outside this region so selecting or moving through draft text does not open history.
      .gesture(PanGesture({ fingers: 1, isFingerCountLimited: true, direction: PanDirection.Right, distance: 8 })
        .onActionStart((event: GestureEvent) => this.onHistoryDragStart(event))
        .onActionUpdate((event: GestureEvent) => this.onHistoryDragUpdate(event))
        .onActionEnd((event: GestureEvent) => this.onHistoryDragEnd(event))
        .onActionCancel(() => this.onHistoryDragCancel()))
      Column({ space: Space.sm }) {
        if (this.app.searchMessageId) { Banner({ text: this.app.searchQuery ? t("匹配：") + this.app.searchQuery : t("历史节点"), danger: false, actionLabel: t("定位"), onAction: () => this.locate() }).onAppear(() => { setTimeout(() => this.locate(), 100); }) }
        if (this.approval.form) { InputFormCard({ approval: this.approval }) }
        if (this.approval.title) {
          this.approvalCard()
        }
        if (this.thread.archived) {
          Banner({ text: t("这段对话已归档"), danger: false, actionLabel: t("恢复对话"), actionId: 'restore-thread',
            actionEnabled: !this.app.busy && this.app.saveError.length === 0,
            onAction: () => { this.app.archiveThread(this.thread.id); } })
        }
        if (this.app.error.length > 0) {
          Banner({ text: this.app.error, compId: 'chat-error', actionLabel: t("关闭"), actionId: 'dismiss-error',
            onAction: () => { this.app.error = ''; } })
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
              SymbolGlyph($r('sys.symbol.arrow_clockwise')).fontSize(15).fontColor([$r('app.color.on_accent_container')])
              Text(t("重新编辑并发送")).fontSize(13).fontColor($r('app.color.on_accent_container'))
            }
          }.id('retry-message').attributeModifier(Btn.tonalSmall).clickEffect(Motion.press)
          .transition(Motion.rise()).onClick(() => this.app.retryPrompt())
        }
        if (this.teamSuggested()) {
          this.commandSuggestion()
        }
        if (this.commandSuggested('/compact')) { this.compactSuggestion() }
        if (this.referenceSuggested()) { this.referenceSuggestions() }
        this.composer()
        Text(t('AI可能会犯错，请仔细鉴别。')).id('ai-disclaimer')
          .fontSize(Font.caption).fontColor($r('app.color.text_secondary'))
          .textAlign(TextAlign.Center).width('100%').padding({ left: Space.sm, right: Space.sm })
      }.width('100%').padding({ left: 10, right: 10, bottom: Space.sm })
    }.height('100%').width('100%')
      .bindSheet($$this.showMemoryDraft, this.memoryDraftSheet(), { title: { title: t("提炼并确认记忆") }, detents: [SheetSize.LARGE], dragBar: true, keyboardAvoidMode: SheetKeyboardAvoidMode.RESIZE_ONLY,
        backgroundColor: $r('app.color.page_background') })
  }
}
