import { AppearanceStyle } from '../common/AppearanceStyle';
import { t } from '../model/I18n';
import { PublishedPreview, stepPreviews } from '../model/PublishedPreview';
import { ChatViewModel, MessageViewModel } from '../viewmodel/ChatViewModel';
import { InteractiveAnswer } from './InteractiveAnswer';
import { IconButton } from '../common/Widgets';

@Component
export struct PreviewPanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink app: ChatViewModel;
  @Prop threadId: string = '';
  @Prop messageId: string = '';
  @Prop previewId: string = '';
  onClose: () => void = () => {};
  private message(): MessageViewModel | undefined { return this.app.active.messages.find((message) => message.id === this.messageId); }
  private previews(): PublishedPreview[] {
    const message = this.message();
    return message ? message.stepViews.flatMap((step, index) => stepPreviews(message.id, step, index, this.app.active.latestPreviewIds, true))
      .filter((preview) => preview.id === this.previewId) : [];
  }
  build() {
    Column() {
      Row() {
        Text(this.previews()[0]?.title || t('预览')).fontFamily(this.appearance.fontFamily).fontSize(16).fontWeight(FontWeight.Medium)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1).fontColor($r('app.color.text_primary'))
        IconButton({ icon: $r('sys.symbol.xmark'), label: t('关闭预览'), compId: 'close-workbench-preview', onTap: this.onClose })
      }.height(56).width('100%').padding({ left: 16, right: 6 })
        .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })
      Scroll() {
        Column() {
          ForEach(this.previews(), (preview: PublishedPreview) => {
            InteractiveAnswer({ content: preview.content, step: preview.step, surfaceOffset: preview.surfaceOffset,
              allowSurface: !/\.jsonl$/i.test(preview.path), saved: this.message()?.uiStates || [],
              presentation: this.message()?.uiPresentation, available: !this.app.busy && !this.app.active.archived,
              selectable: false, onInteract: (key, values, action) => this.app.interactUi(this.threadId, this.messageId, key, values, action) })
          }, (preview: PublishedPreview) => preview.id)
        }.width('100%').padding(16).alignItems(HorizontalAlign.Start)
      }.layoutWeight(1).width('100%').align(Alignment.Top).scrollBar(BarState.Auto)
    }.id('workbench-preview').width('100%').height('100%').backgroundColor($r('app.color.surface'))
  }
}
