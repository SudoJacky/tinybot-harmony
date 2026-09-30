import { ChatViewModel, MessageViewModel, ThreadViewModel } from '../viewmodel/ChatViewModel';
import { MessageBubble } from './MessageBubble';

@Component
export struct ChatPanel {
  @ObjectLink app: ChatViewModel;
  @ObjectLink thread: ThreadViewModel;
  onSettings: () => void = () => {};
  onModels: () => void = () => {};
  @State private followOutput: boolean = true;
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

  @Builder
  suggestion(title: string, prompt: string) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        Text(title).fontSize(14).fontColor($r('app.color.text_primary')).layoutWeight(1)
        Text('↗').fontSize(18).fontColor($r('app.color.accent'))
      }.width('100%')
    }
    .width('100%').padding(16).borderRadius(16).backgroundColor($r('app.color.surface'))
    .onClick(() => { this.app.setDraft(prompt); })
  }

  @Builder
  welcome() {
    Scroll() {
      Column({ space: 14 }) {
        Image($r('app.media.tinybot')).width(64).height(64).margin({ bottom: 10 })
        Text('小小助手，\n随时在身边。').fontSize(32).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary')).lineHeight(43).textAlign(TextAlign.Center)
        Text('整理想法，解答疑问，一起把事情做好。')
          .fontSize(14).fontColor($r('app.color.text_secondary')).textAlign(TextAlign.Center)
          .margin({ bottom: 16 })
        this.suggestion('把想法整理成行动', '帮我把下面的想法整理成可执行的步骤：')
        this.suggestion('用简单的话解释', '请用一个贴近日常生活的例子，解释一个复杂概念：')
        if (!this.app.configured) {
          Button('连接你的模型').id('setup-model').fontSize(15)
            .backgroundColor($r('app.color.accent')).fontColor($r('app.color.on_accent'))
            .height(46).width('100%').margin({ top: 8 }).onClick(this.onSettings)
        }
      }.width('100%').padding({ left: 24, right: 24, top: 28, bottom: 24 })
    }.layoutWeight(1).width('100%').scrollBar(BarState.Off)
  }

  build() {
    Column({ space: 0 }) {
      if (this.thread.archived) {
        Row({ space: 10 }) {
          Text('这段对话已归档').fontSize(13).layoutWeight(1).fontColor($r('app.color.text_secondary'))
          Button('恢复对话').fontSize(13).enabled(!this.app.busy && this.app.saveError.length === 0)
            .onClick(() => this.app.archiveThread(this.thread.id))
        }.padding(12).width('100%')
      }
      if (this.thread.messages.length === 0) {
        this.welcome()
      } else {
        List({ space: 14, scroller: this.scroller }) {
          if (this.app.visibleMessageCount < this.thread.messages.length) {
            ListItem() {
              Button('加载更早的消息').id('load-earlier-messages').fontSize(13).width('100%')
                .onClick(() => { this.app.visibleMessageCount += 60; })
            }
          }
          ForEach(this.app.visibleMessages, (message: MessageViewModel) => {
            ListItem() { MessageBubble({ message: message }) }
          }, (message: MessageViewModel) => message.id)
        }
        .id('message-list').layoutWeight(1).width('100%').padding({ left: 16, right: 16, top: 16, bottom: 16 })
        .scrollBar(BarState.Auto)
        .onTouch((event: TouchEvent) => { if (event.type === TouchType.Down) { this.followOutput = false; } })
        .onReachEnd(() => { this.followOutput = true; })
        if (!this.app.busy && this.thread.messages[this.thread.messages.length - 1].status !== 'complete') {
          Button('重新编辑并发送').id('retry-message').fontSize(13).height(36)
            .backgroundColor($r('app.color.surface')).fontColor($r('app.color.accent'))
            .onClick(() => this.app.retryPrompt()).margin({ bottom: 8 })
        }
        if (!this.followOutput && this.app.generating) {
          Button('查看最新回答 ↓').fontSize(12).height(32)
            .backgroundColor($r('app.color.surface')).fontColor($r('app.color.accent'))
            .onClick(() => { this.followOutput = true; this.follow(); })
        }
      }
      if (this.app.error.length > 0) {
        Text(this.app.error).id('chat-error').fontSize(13).fontColor($r('app.color.danger'))
          .padding({ left: 20, right: 20, top: 8, bottom: 8 }).width('100%')
      }
      if (this.app.saveError.length > 0) {
        Column({ space: 8 }) {
          Text(this.app.saveError).fontSize(13).fontColor($r('app.color.danger'))
          Button('重试保存').id('retry-save').fontSize(13).enabled(!this.app.busy)
            .onClick(() => this.app.retrySave())
        }.padding(12).width('100%')
      }
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          Text(this.app.contextLabel).id('context-usage').fontSize(11).layoutWeight(1)
            .fontColor($r('app.color.text_secondary'))
          Button('压缩历史').id('compact-history').fontSize(12).height(30)
            .backgroundColor(Color.Transparent).fontColor($r('app.color.accent'))
            .enabled(this.app.configured && !this.app.busy && !this.thread.archived && this.app.saveError.length === 0)
            .onClick(() => {
              this.getUIContext().showAlertDialog({
                title: '压缩较早对话？',
                message: '将调用当前模型生成摘要，消耗 Token。完整记录保留，之后请求使用摘要和最近消息。',
                primaryButton: { value: '取消', action: () => {} },
                secondaryButton: { value: '压缩', action: () => { this.app.compactHistory(); } }
              });
            })
        }.width('100%')
        if (this.app.contextStatus.length > 0) {
          Text(this.app.contextStatus).id('context-status').fontSize(12).width('100%')
            .fontColor($r('app.color.text_secondary'))
        } else if (this.thread.compaction) {
          Text('较早对话使用摘要 · 完整记录保留').fontSize(11).width('100%')
            .fontColor($r('app.color.text_secondary'))
        }
        if (this.thread.compaction) {
          Button(this.showSummary ? '收起上下文摘要' : '查看上下文摘要').fontSize(11).height(28)
            .backgroundColor(Color.Transparent).fontColor($r('app.color.accent'))
            .onClick(() => { this.showSummary = !this.showSummary; })
          if (this.showSummary) {
            Scroll() {
              Text(this.thread.compaction.summary).fontSize(12).lineHeight(19).width('100%')
                .copyOption(CopyOptions.LocalDevice).fontColor($r('app.color.text_primary'))
            }.height(160).width('100%')
          }
        }
        TextArea({ text: this.app.draft, placeholder: '有什么想一起做的？' })
          .id('composer').fontSize(16).fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_secondary')).backgroundColor(Color.Transparent)
          .height(76).maxLength(24000).padding({ left: 4, right: 4, top: 8, bottom: 4 })
          .enabled(!this.thread.archived).onChange((value: string) => { this.app.setDraft(value); })
        Row({ space: 12 }) {
          Button(this.app.currentModelLabel + ' ▾').id('open-model-picker').fontSize(12)
            .backgroundColor(Color.Transparent).fontColor($r('app.color.text_secondary'))
            .layoutWeight(1).height(40).enabled(!this.app.busy && !this.thread.archived).onClick(this.onModels)
          if (this.app.generating) {
            Button('停止').id('stop-generation').height(40).fontSize(14)
              .fontColor($r('app.color.on_accent')).backgroundColor($r('app.color.accent'))
              .onClick(() => this.app.stop())
          } else {
            Button('发送 ↑').id('send-message').height(40).fontSize(14)
              .fontColor($r('app.color.on_accent')).backgroundColor($r('app.color.accent'))
              .enabled(this.app.ready && !this.app.busy && !this.thread.archived && this.app.draft.trim().length > 0 && this.app.saveError.length === 0)
              .onClick(() => this.send())
          }
        }.width('100%')
      }
      .padding(14).margin({ left: 16, right: 16, bottom: 8 }).borderRadius(24)
      .backgroundColor($r('app.color.surface'))
      Text('会话与文件保存在本机 · 消息和工具结果会发送给模型')
        .fontSize(10).fontColor($r('app.color.text_secondary')).textAlign(TextAlign.Center)
        .padding({ left: 16, right: 16, bottom: 12 })
    }.height('100%').width('100%')
  }
}
