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
  @State private titleHeight: number = 0;
  @State private bodyHeight: number = 0;
  @State private footerHeight: number = 0;

  private confirm(): void {
    this.error = '';
    try { this.onConfirm(); }
    catch (error) { this.error = (error as Error).message; }
  }

  build() {
    Column() {
      Row({ space: Space.sm }) {
        Row({ space: 4 }) {
          Image($r('app.media.announcement')).width(20).height(20).fillColor(this.appearance.accent)
            .id('announcement-icon').accessibilityLevel('no')
          Text(t('公告')).fontFamily(this.appearance.fontFamily).fontSize(12).fontColor(this.appearance.accent)
            .id('announcement-label').layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.width(64)
        Text(this.announcement.title).id('announcement-title').fontFamily(this.appearance.fontFamily)
          .fontSize(Font.title).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1).textAlign(TextAlign.Center)
        Row() {}.width(64).accessibilityLevel('no')
      }.id('announcement-header').width('100%').alignItems(VerticalAlign.Center).margin({ bottom: Space.lg })
        .onAreaChange((_old: Area, area: Area) => { this.titleHeight = Number(area.height); })
      Scroll() {
        Column() {
          MarkdownView({ content: this.announcement.body, fontSize: Font.body })
        }.id('announcement-content').width('100%')
          .onAreaChange((_old: Area, area: Area) => { this.bodyHeight = Number(area.height); })
      }.id('announcement-body').width('100%').layoutWeight(1).align(Alignment.TopStart)
        .scrollBar(BarState.Auto).edgeEffect(EdgeEffect.None)
      Column({ space: Space.sm }) {
        if (this.error) { Banner({ text: this.error, compId: 'announcement-save-error' }) }
        Button(t('知道了')).id('announcement-confirm').fontFamily(this.appearance.fontFamily)
          .attributeModifier(Btn.primary).width('100%').onClick(() => this.confirm())
      }.id('announcement-footer').width('100%').margin({ top: Space.lg })
        .onAreaChange((_old: Area, area: Area) => { this.footerHeight = Number(area.height); })
    }.id('announcement-dialog').width('100%')
      // Measure intrinsic content inside Scroll, then clamp the dialog. Only the body
      // receives the remaining height, so the action stays against the bottom padding.
      .height(Math.max(240, this.titleHeight + this.bodyHeight + this.footerHeight + Space.lg * 2 + Space.xl * 2))
      .constraintSize({ maxHeight: '80%' }).padding(Space.xl)
  }
}
