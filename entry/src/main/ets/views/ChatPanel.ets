import { ChatViewModel, MessageViewModel, ThreadViewModel } from '../viewmodel/ChatViewModel';
import { MessageBubble } from './MessageBubble';
import { InputQueuePanel } from './InputQueuePanel';
import { Btn, Font, Radius, Space } from '../common/Theme';
import { Banner, IconButton } from '../common/Widgets';

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

const SUGGESTIONS: Suggestion[] = [
  new Suggestion($r('sys.symbol.checkmark'), '整理成行动', '把零散想法变成步骤', '帮我把下面的想法整理成可执行的步骤：'),
  new Suggestion($r('sys.symbol.ellipsis_message'), '通俗解释', '用生活例子讲清概念', '请用一个贴近日常生活的例子，解释一个复杂概念：'),
  new Suggestion($r('sys.symbol.square_and_pencil'), '润色文字', '更清晰、更得体', '请帮我润色下面这段文字，保持原意，让表达更清晰：'),
  new Suggestion($r('sys.symbol.magnifyingglass'), '读网页', '总结链接中的要点', '请阅读这个网页并总结要点：')
];

@Component
export struct ChatPanel {
  @ObjectLink app: ChatViewModel;
  @ObjectLink thread: ThreadViewModel;
  onSettings: () => void = () => {};
  @State private followOutput: boolean = true;
  @State private atBottom: boolean = true;
  @State private showContext: boolean = false;
  @State private showQueue: boolean = false;
  @State private showSummary: boolean = false;
  private scroller: Scroller = new Scroller();
  private scrollTimer: number = -1;

  aboutToDisappear(): void {
    clearTimeout(this.scrollTimer);
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

  private send(): void {
    this.followOutput = true;
    this.app.send(() => this.follow());
  }

  private get hasDraft(): boolean {
    return this.app.draft.trim().length > 0;
  }

  private get canSend(): boolean {
    return this.app.ready && !this.app.busy && !this.thread.archived && this.hasDraft && this.app.saveError.length === 0;
  }

  private get contextRatio(): number {
    return this.app.contextWindow > 0 ? Math.min(1, this.app.contextUsed / this.app.contextWindow) : 0;
  }

  private contextColor(): ResourceColor {
    return this.contextRatio >= 0.85 ? $r('app.color.danger') : $r('app.color.accent');
  }

  private confirmCompact(): void {
    this.getUIContext().showAlertDialog({
      title: '压缩较早对话？',
      message: '将调用当前模型生成摘要，消耗 Token。完整记录保留，之后请求使用摘要和最近消息。',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '压缩', action: () => { this.showContext = false; this.app.compactHistory(); } }
    });
  }

  @Builder
  suggestionCard(item: Suggestion) {
    Column({ space: 6 }) {
      SymbolGlyph(item.icon).fontSize(20).fontColor([$r('app.color.accent')])
      Text(item.title).fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
      Text(item.detail).fontSize(Font.caption).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontColor($r('app.color.text_secondary'))
    }
    .layoutWeight(1).alignItems(HorizontalAlign.Start).padding(14).borderRadius(Radius.lg)
    .backgroundColor($r('app.color.surface'))
    .stateStyles({ pressed: { .opacity(0.7) }, normal: { .opacity(1) } })
    .onClick(() => { this.app.setDraft(item.prompt); })
  }

  @Builder
  welcome() {
    Scroll() {
      Column({ space: Space.md }) {
        Blank().layoutWeight(1)
        Image($r('app.media.tinybot')).width(56).height(56)
        Text('今天想一起做点什么？').fontSize(Font.headline).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary')).textAlign(TextAlign.Center)
        Text('整理想法，解答疑问，一起把事情做好。')
          .fontSize(Font.small).fontColor($r('app.color.text_secondary')).textAlign(TextAlign.Center)
          .margin({ bottom: Space.md })
        if (!this.app.configured) {
          Column({ space: 10 }) {
            Text('先连接一个模型服务').fontSize(15).fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.on_accent_container'))
            Text('支持 OpenAI、Anthropic 等协议，密钥保存在系统安全存储中。').fontSize(13).lineHeight(19)
              .textAlign(TextAlign.Center).fontColor($r('app.color.on_accent_container'))
            Button('连接你的模型').id('setup-model').attributeModifier(Btn.primary).width('100%')
              .onClick(() => this.onSettings())
          }.width('100%').padding(Space.lg).borderRadius(Radius.lg).backgroundColor($r('app.color.accent_container'))
        }
        Row({ space: 10 }) {
          this.suggestionCard(SUGGESTIONS[0])
          this.suggestionCard(SUGGESTIONS[1])
        }.width('100%')
        Row({ space: 10 }) {
          this.suggestionCard(SUGGESTIONS[2])
          this.suggestionCard(SUGGESTIONS[3])
        }.width('100%')
        Text('会话与文件保存在本机 · 消息和工具结果会发送给模型')
          .fontSize(11).fontColor($r('app.color.text_tertiary')).textAlign(TextAlign.Center).margin({ top: Space.sm })
      }.width('100%').constraintSize({ minHeight: '100%' }).padding({ left: 20, right: 20, top: Space.lg, bottom: Space.md })
    }.layoutWeight(1).width('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  messageList() {
    Stack({ alignContent: Alignment.Bottom }) {
      List({ space: 22, scroller: this.scroller }) {
        if (this.app.visibleMessageCount < this.thread.messages.length) {
          ListItem() {
            Button('加载更早的消息').id('load-earlier-messages').attributeModifier(Btn.textSmall)
              .onClick(() => { this.app.visibleMessageCount += 60; })
          }.width('100%')
        }
        ForEach(this.app.visibleMessages, (message: MessageViewModel) => {
          ListItem() { MessageBubble({ message: message }) }
        }, (message: MessageViewModel) => message.id)
      }
      .id('message-list').width('100%').height('100%')
      .padding({ left: Space.page, right: Space.page, top: Space.sm, bottom: Space.lg })
      .scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
      .onTouch((event: TouchEvent) => { if (event.type === TouchType.Down) { this.followOutput = false; } })
      .onReachEnd(() => { this.followOutput = true; })
      .onDidScroll(() => { this.atBottom = this.scroller.isAtEnd(); })
      if (!this.atBottom) {
        IconButton({ icon: $r('sys.symbol.arrow_down'), label: '查看最新消息', compId: 'scroll-to-latest',
          diameter: 38, iconSize: 18, fill: $r('app.color.surface'), tint: $r('app.color.text_primary'),
          onTap: () => { this.followOutput = true; this.scroller.scrollEdge(Edge.Bottom); } })
          .shadow({ radius: 12, color: '#26000000', offsetY: 2 }).margin({ bottom: Space.md })
          .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.8, y: 0.8 }))
            .animation({ duration: 180 }))
      }
    }.layoutWeight(1).width('100%')
  }

  @Builder
  contextSheet() {
    Scroll() {
      Column({ space: Space.lg }) {
        Column({ space: 10 }) {
          Row() {
            Text(`${Math.round(this.contextRatio * 100)}%`).fontSize(28).fontWeight(FontWeight.Bold)
              .fontColor(this.contextColor())
            Blank()
            Text(`约 ${this.app.contextUsed} / ${this.app.contextWindow} tokens`).id('context-label')
              .fontSize(13).fontColor($r('app.color.text_secondary'))
          }.width('100%').alignItems(VerticalAlign.Bottom)
          Progress({ value: this.app.contextUsed, total: Math.max(1, this.app.contextWindow), type: ProgressType.Linear })
            .width('100%').color(this.contextColor()).backgroundColor($r('app.color.surface_variant'))
            .style({ strokeWidth: 8, strokeRadius: 4 })
          if (this.app.contextStatus.length > 0) {
            Text(this.app.contextStatus).id('context-status').fontSize(13).lineHeight(19).width('100%')
              .fontColor($r('app.color.text_secondary'))
          } else {
            Text('包含系统提示、Skills 简介、历史消息与当前草稿的估算用量。').fontSize(13).lineHeight(19).width('100%')
              .fontColor($r('app.color.text_secondary'))
          }
        }.padding(Space.lg).borderRadius(Radius.lg).backgroundColor($r('app.color.surface'))
        if (this.thread.compaction) {
          Column({ space: 10 }) {
            Row({ space: Space.sm }) {
              Text('较早对话使用摘要').fontSize(15).fontWeight(FontWeight.Medium).layoutWeight(1)
                .fontColor($r('app.color.text_primary'))
              Button(this.showSummary ? '收起' : '查看摘要').attributeModifier(Btn.textSmall)
                .onClick(() => { this.showSummary = !this.showSummary; })
            }.width('100%')
            Text('完整记录仍保留在本机，只有发送给模型时使用摘要。').fontSize(Font.caption)
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
          Button('压缩较早对话').id('compact-history').attributeModifier(Btn.tonal).width('100%')
            .enabled(this.app.configured && !this.app.busy && !this.thread.archived && this.app.saveError.length === 0)
            .onClick(() => this.confirmCompact())
          Text('使用当前模型为较早消息生成摘要，会消耗 Token。').fontSize(Font.caption)
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
      MenuItem({ content: '加入队列' }).enabled(this.app.canQueueInput && this.hasDraft)
        .onClick(() => this.app.enqueueInput('followUp'))
    }
  }

  @Builder
  composer() {
    Column({ space: 6 }) {
      TextArea({ text: this.app.draft,
        placeholder: this.thread.archived ? '已归档的对话无法继续' : this.app.generating ? '补充要求，或排队下一项任务…' : '问点什么…' })
        .id('composer').fontSize(Font.body).fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_tertiary')).backgroundColor(Color.Transparent)
        .constraintSize({ minHeight: 44, maxHeight: 160 }).maxLength(24000)
        .padding({ left: 6, right: 6, top: 10, bottom: 4 }).borderRadius(0)
        .enabled(!this.thread.archived).onChange((value: string) => { this.app.setDraft(value); })
      Row({ space: 6 }) {
        Button({ type: ButtonType.Circle }) {
          Progress({ value: this.app.contextUsed, total: Math.max(1, this.app.contextWindow), type: ProgressType.Ring })
            .width(20).height(20).color(this.contextColor()).backgroundColor($r('app.color.surface_variant'))
            .style({ strokeWidth: 3 })
        }.id('context-usage').width(36).height(36).backgroundColor(Color.Transparent)
        .accessibilityText(this.app.contextLabel)
        .onClick(() => { this.showContext = true; })
        .bindSheet($$this.showContext, this.contextSheet(), {
          title: { title: '上下文' }, detents: [SheetSize.MEDIUM, SheetSize.LARGE], dragBar: true,
          backgroundColor: $r('app.color.page_background'), onDisappear: () => { this.showSummary = false; }
        })
        if (this.thread.pendingInputs.length > 0) {
          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.clock')).fontSize(14).fontColor([$r('app.color.on_accent_container')])
            Text(`${this.thread.queuePaused ? '已暂停' : '待发送'} ${this.thread.pendingInputs.length}`)
              .fontSize(Font.caption).fontWeight(FontWeight.Medium).fontColor($r('app.color.on_accent_container'))
          }
          .id('toggle-input-queue').height(30).padding({ left: 10, right: 12 }).borderRadius(15)
          .backgroundColor($r('app.color.accent_container'))
          .onClick(() => { this.showQueue = true; })
          .bindSheet($$this.showQueue, this.queueSheet(), {
            title: { title: '待发送队列' }, detents: [SheetSize.MEDIUM, SheetSize.LARGE], dragBar: true,
            backgroundColor: $r('app.color.page_background')
          })
        }
        Blank()
        if (this.app.generating) {
          if (this.hasDraft && this.app.canQueueInput) {
            Button('追加').id('steer-message').attributeModifier(Btn.tonalSmall)
              .enabled(this.app.acceptingSteering).onClick(() => this.app.enqueueInput('steer'))
            Button('排队').id('queue-message').attributeModifier(Btn.plainSmall)
              .onClick(() => this.app.enqueueInput('followUp'))
          }
          IconButton({ icon: $r('sys.symbol.square_fill'), label: '停止', compId: 'stop-generation', diameter: 36,
            iconSize: 14, fill: $r('app.color.text_primary'), tint: $r('app.color.page_background'),
            onTap: () => { this.app.stop(); } })
        } else {
          if (this.thread.pendingInputs.length > 0 && this.hasDraft) {
            Button('排队').id('queue-message').attributeModifier(Btn.plainSmall)
              .enabled(this.app.canQueueInput).onClick(() => this.app.enqueueInput('followUp'))
          }
          IconButton({ icon: $r('sys.symbol.arrow_up'), label: '发送', compId: 'send-message', diameter: 36, iconSize: 18,
            fill: this.canSend ? $r('app.color.accent') : $r('app.color.surface_variant'),
            tint: this.canSend ? $r('app.color.on_accent') : $r('app.color.text_tertiary'),
            disabled: !this.canSend, onTap: () => this.send() })
            .bindContextMenu(this.sendMenu, ResponseType.LongPress)
        }
      }.width('100%')
    }
    .padding({ left: 10, right: 8, top: 4, bottom: 8 }).borderRadius(Radius.xl)
    .backgroundColor($r('app.color.surface'))
    .border({ width: 0.5, color: $r('app.color.divider') })
  }

  build() {
    Column() {
      if (this.thread.messages.length === 0) {
        this.welcome()
      } else {
        this.messageList()
      }
      Column({ space: Space.sm }) {
        if (this.thread.archived) {
          Banner({ text: '这段对话已归档', danger: false, actionLabel: '恢复对话', actionId: 'restore-thread',
            actionEnabled: !this.app.busy && this.app.saveError.length === 0,
            onAction: () => { this.app.archiveThread(this.thread.id); } })
        }
        if (this.app.error.length > 0) {
          Banner({ text: this.app.error, compId: 'chat-error' })
        }
        if (this.app.saveError.length > 0) {
          Banner({ text: this.app.saveError, actionLabel: '重试保存', actionId: 'retry-save',
            actionEnabled: !this.app.busy, onAction: () => { this.app.retrySave(); } })
        }
        if (!this.app.busy && this.thread.messages.length > 0
          && this.thread.messages[this.thread.messages.length - 1].status !== 'complete') {
          Button() {
            Row({ space: 6 }) {
              SymbolGlyph($r('sys.symbol.arrow_clockwise')).fontSize(15).fontColor([$r('app.color.on_accent_container')])
              Text('重新编辑并发送').fontSize(13).fontColor($r('app.color.on_accent_container'))
            }
          }.id('retry-message').attributeModifier(Btn.tonalSmall).onClick(() => this.app.retryPrompt())
        }
        this.composer()
      }.width('100%').padding({ left: 10, right: 10, bottom: Space.sm })
    }.height('100%').width('100%')
  }
}
