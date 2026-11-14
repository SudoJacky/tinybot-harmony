import { AppearanceStyle } from '../common/AppearanceStyle';
import { Btn, Radius, Space } from '../common/Theme';
import { IconButton } from '../common/Widgets';
import { t } from '../model/I18n';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { MessageViewModel, ThreadViewModel } from '../viewmodel/SessionViewModels';
import { MarkdownView } from './MarkdownView';

@Component
struct SideChatMessage {
  @ObjectLink message: MessageViewModel;

  build() {
    Column({ space: Space.xs }) {
      if (this.message.role === 'user') {
        Text(this.message.content).fontSize(15).fontColor($r('app.color.text_primary'))
          .width('100%').padding(Space.md).borderRadius(Radius.md).backgroundColor($r('app.color.surface_variant'))
      } else if (this.message.content) {
        MarkdownView({ content: this.message.content, streaming: this.message.status === 'generating', fontSize: 15 })
      } else if (this.message.status === 'generating') {
        LoadingProgress().width(20).height(20).accessibilityText(t('正在执行'))
      }
      if (this.message.error) {
        Text(this.message.error).fontSize(13).fontColor($r('app.color.text_secondary'))
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ bottom: Space.md })
  }
}

@Component
export struct SideChatPanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink app: ChatViewModel;
  @ObjectLink thread: ThreadViewModel;
  onDelete: () => void = () => {};
  private scroller: Scroller = new Scroller();

  private running(): boolean { return this.app.runningThreadIds.includes(this.thread.id); }

  build() {
    Column({ space: Space.sm }) {
      Row({ space: Space.sm }) {
        Text(t('工作区只读')).fontSize(12).fontColor($r('app.color.text_secondary')).layoutWeight(1)
        Button(this.app.active.references.some((item) => item.threadId === this.thread.id) ?
          t('已带回主会话') : t('带回主会话')).attributeModifier(Btn.textSmall)
          .id('side-chat-bring-back')
          .enabled(!this.app.busy && !this.running() && !this.app.active.archived &&
            !this.app.active.references.some((item) => item.threadId === this.thread.id) && this.thread.messages.some((message) =>
            message.role === 'assistant' && message.status === 'complete'))
          .onClick(() => this.app.bringBackSideChat(this.thread.id))
        IconButton({ icon: $r('sys.symbol.trash'), label: t('删除旁聊'), compId: 'side-chat-delete',
          diameter: 40, disabled: !this.app.canNavigate || this.running(), onTap: this.onDelete })
      }.width('100%')
      if (!this.thread.messages.length) {
        Text(t('可以在这里追问主会话，旁聊消息会单独保存。'))
          .width('100%').layoutWeight(1).fontSize(14).fontColor($r('app.color.text_secondary'))
      } else {
        List({ scroller: this.scroller }) {
          ForEach(this.thread.messages, (message: MessageViewModel) => {
            ListItem() { SideChatMessage({ message: message }) }
          }, (message: MessageViewModel) => message.id)
        }.width('100%').layoutWeight(1).scrollBar(BarState.Auto)
      }
      if (this.app.saveError || this.app.sideChatError(this.thread.id) || this.app.error) {
        Text(this.app.saveError || this.app.sideChatError(this.thread.id) || this.app.error)
          .width('100%').fontSize(13).fontColor($r('app.color.text_secondary'))
      }
      TextArea({ text: this.thread.draft, placeholder: t('向旁聊提问…') }).id('side-chat-draft').width('100%')
        .height(84).maxLength(24000).fontFamily(this.appearance.fontFamily).fontSize(15)
        .enabled(!this.app.active.archived)
        .onChange((text: string) => this.app.setDraft(text, this.thread.id))
      Row() {
        Blank()
        if (this.running()) {
          Button(t('停止生成')).id('side-chat-stop').attributeModifier(Btn.tonal)
            .onClick(() => this.app.stopSideChat(this.thread.id))
        } else {
          Button(t('发送')).id('side-chat-send').attributeModifier(Btn.primary)
            .enabled(this.app.canNavigate && !this.app.active.archived && this.thread.draft.trim().length > 0)
            .onClick(async () => {
              const sending = this.app.sendSideChat(this.thread.id);
              await sending;
              this.scroller.scrollEdge(Edge.Bottom);
            })
        }
      }.width('100%')
    }.width('100%').height('100%').padding(Space.md)
  }
}
