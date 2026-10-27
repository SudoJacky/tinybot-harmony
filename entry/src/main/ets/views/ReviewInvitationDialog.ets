import { AppearanceStyle } from '../common/AppearanceStyle';
import { Btn, Font, Space } from '../common/Theme';
import { Banner } from '../common/Widgets';
import { t } from '../model/I18n';

export type ReviewChoice = 'review' | 'later' | 'never';

@CustomDialog
export struct ReviewInvitationDialog {
  controller?: CustomDialogController;
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  onChoose: (choice: ReviewChoice) => void = () => {};
  @State private error: string = '';
  @State private closing: boolean = false;

  private choose(choice: ReviewChoice): void {
    if (this.closing) { return; }
    this.error = ''; this.closing = true;
    try { this.onChoose(choice); }
    catch (error) { this.closing = false; this.error = t('无法保存评分邀请记录：{0}', [(error as Error).message]); }
  }

  build() {
    Column({ space: Space.md }) {
      Text(t('愿意评价 Tinybot 吗？')).id('review-invitation-title').fontFamily(this.appearance.fontFamily)
        .fontSize(Font.title).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).width('100%')
      Text(t('你的评分和评论能帮助我们改进 Tinybot，也能帮助更多人了解它。'))
        .fontFamily(this.appearance.fontFamily).fontSize(Font.body).fontColor($r('app.color.text_secondary')).width('100%')
      if (this.error) { Banner({ text: this.error, compId: 'review-invitation-error' }) }
      Button(t('去评分')).id('review-invitation-accept').fontFamily(this.appearance.fontFamily)
        .attributeModifier(Btn.primary).width('100%').enabled(!this.closing).onClick(() => this.choose('review'))
      Button(t('暂不')).id('review-invitation-later').fontFamily(this.appearance.fontFamily)
        .attributeModifier(Btn.tonal).width('100%').enabled(!this.closing).onClick(() => this.choose('later'))
      Button(t('不再提醒')).id('review-invitation-never').fontFamily(this.appearance.fontFamily)
        .attributeModifier(Btn.textSmall).width('100%').enabled(!this.closing).onClick(() => this.choose('never'))
    }.id('review-invitation-dialog').width('100%').padding(Space.xl)
  }
}
