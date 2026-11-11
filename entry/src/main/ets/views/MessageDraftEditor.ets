import { AppearanceStyle } from '../common/AppearanceStyle';
import { handleDraftEnter } from '../common/KeyboardShortcuts';
import { PageStyles } from '../common/PageStyles';
import { Btn, Space, systemInsets } from '../common/Theme';
import { t } from '../model/I18n';
import { ChatViewModel, ThreadViewModel } from '../viewmodel/ChatViewModel';

// A full-page writing surface keeps its actions above tablet floating keyboards.
// It edits the same persisted conversation draft as the inline composer.
@Component
export struct MessageDraftEditor {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink app: ChatViewModel;
  @ObjectLink thread: ThreadViewModel;
  @Prop sendEnabled: boolean = false;
  @Prop localOptions: boolean = true;
  @State private insetTop: number = 0;
  @State private insetBottom: number = 0;
  private editor: TextAreaController = new TextAreaController();
  private hasPreview: boolean = false;
  aboutToAppear(): void {
    systemInsets(this.getUIContext()).then((insets: number[]) => { this.insetTop = insets[0]; this.insetBottom = insets[1]; });
  }
  onClose: () => void = () => {};
  onSend: () => void = () => {};

  build() {
    Column() {
    Column({ space: Space.md }) {
      Row({ space: Space.md }) {
        Button(t('返回对话')).attributeModifier(Btn.text).id('expanded-draft-close').onClick(this.onClose)
        Text(t('编辑消息')).fontSize(17).fontWeight(FontWeight.Medium).layoutWeight(1)
          .fontColor($r('app.color.text_primary'))
        Button(t('发送')).attributeModifier(Btn.primary).id('expanded-draft-send')
          .enabled(this.sendEnabled && this.app.active.id === this.thread.id).onClick(this.onSend)
      }.width('100%').padding({ left: Space.md, right: Space.md, top: Space.sm, bottom: Space.sm })
        .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })
      if (this.localOptions) {
        Text(t('草稿会自动保留，返回后可继续添加附件或切换模型。')).fontSize(12)
          .fontColor($r('app.color.text_secondary')).width('100%').padding({ left: Space.page, right: Space.page })
      }
      TextArea({ text: this.app.draft, placeholder: t('输入消息…'), controller: this.editor }).id('expanded-draft-input')
        .fontFamily(this.appearance.fontFamily).fontSize(16).fontColor($r('app.color.text_primary'))
        .backgroundColor($r('app.color.surface')).borderRadius(12).width('100%').layoutWeight(1)
        .maxLength(24000).defaultFocus(true).padding(Space.page)
        .enabled(!this.thread.archived && this.app.active.id === this.thread.id)
        .onKeyPreIme((event: KeyEvent) => {
          if (this.app.active.id !== this.thread.id) { return false; }
          return handleDraftEnter(event, this.editor, this.hasPreview, () => {
            if (this.sendEnabled && !this.app.generating) { this.onSend(); }
          });
        })
        .onChange((value: string, preview?: PreviewText) => {
          this.hasPreview = !!preview?.value;
          if (this.app.active.id === this.thread.id) { this.app.setDraft(value); }
        })
        .onBlur(() => { this.hasPreview = false; })
    }.width('100%').height('100%').attributeModifier(PageStyles.reading)
    }.width('100%').height('100%').padding({ top: this.insetTop, bottom: this.insetBottom, left: Space.page, right: Space.page })
      .backgroundColor($r('app.color.page_background'))
  }
}
