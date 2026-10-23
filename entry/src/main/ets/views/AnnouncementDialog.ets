import { AppearanceStyle } from '../common/AppearanceStyle';
import { Btn, Font, Space } from '../common/Theme';
import { Banner } from '../common/Widgets';
import { Announcement } from '../model/Announcement';
import { t } from '../model/I18n';
import { MarkdownView } from './MarkdownView';

@CustomDialog
export struct AnnouncementDialog {
  controller?: CustomDialogController;
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  announcement: Announcement = { id: '', title: '', body: '' };
  onConfirm: () => void = () => {};
  @State private error: string = '';

  private confirm(): void {
    this.error = '';
    try { this.onConfirm(); }
    catch (error) { this.error = (error as Error).message; }
  }

  build() {
    Flex({ direction: FlexDirection.Column }) {
      Text(this.announcement.title).id('announcement-title').fontFamily(this.appearance.fontFamily)
        .fontSize(Font.title).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%').flexShrink(0)
        .margin({ bottom: Space.lg })
      Scroll() {
        MarkdownView({ content: this.announcement.body, fontSize: Font.body })
      }.id('announcement-body').width('100%').flexShrink(1).align(Alignment.TopStart)
        .scrollBar(BarState.Auto).edgeEffect(EdgeEffect.None)
      Column({ space: Space.sm }) {
        if (this.error) { Banner({ text: this.error, compId: 'announcement-save-error' }) }
        Button(t('知道了')).id('announcement-confirm').fontFamily(this.appearance.fontFamily)
          .attributeModifier(Btn.primary).width('100%').onClick(() => this.confirm())
      }.width('100%').flexShrink(0).margin({ top: Space.lg })
    }.id('announcement-dialog').width('100%').constraintSize({ maxHeight: '80%' }).padding(Space.xl)
  }
}
